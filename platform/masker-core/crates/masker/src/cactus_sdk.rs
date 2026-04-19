#![cfg(feature = "cactus")]

use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::Mutex;

use serde::Deserialize;

use crate::backends::BackendError;

const DEFAULT_RESPONSE_BUFFER_SIZE: usize = 64 * 1024;

#[derive(Debug, Clone, Deserialize)]
pub struct CactusResponseEnvelope {
    pub success: bool,
    pub error: Option<String>,
    pub response: String,
    #[serde(default)]
    pub confidence: Option<f32>,
}

pub struct CactusModel {
    handle: cactus_sys::cactus_model_t,
    lock: Mutex<()>,
}

unsafe impl Send for CactusModel {}
unsafe impl Sync for CactusModel {}

impl CactusModel {
    pub fn new(model_path: &str) -> Result<Self, BackendError> {
        let path_c =
            CString::new(model_path).map_err(|e| BackendError::Transport(e.to_string()))?;

        let handle = unsafe { cactus_sys::cactus_init(path_c.as_ptr(), ptr::null(), false) };
        if handle.is_null() {
            return Err(BackendError::NotConfigured(format!(
                "cactus_init returned null for model path {model_path}"
            )));
        }

        Ok(Self {
            handle,
            lock: Mutex::new(()),
        })
    }

    pub fn from_env(env_var: &str) -> Result<Self, BackendError> {
        let model_path = std::env::var(env_var)
            .map_err(|_| BackendError::NotConfigured(format!("{env_var} missing")))?;
        Self::new(&model_path)
    }

    pub fn complete(
        &self,
        messages_json: &str,
        options_json: Option<&str>,
    ) -> Result<CactusResponseEnvelope, BackendError> {
        let _guard = self
            .lock
            .lock()
            .map_err(|_| BackendError::Transport("cactus model mutex poisoned".into()))?;

        let messages_c =
            CString::new(messages_json).map_err(|e| BackendError::Transport(e.to_string()))?;
        let options_c = options_json
            .map(CString::new)
            .transpose()
            .map_err(|e| BackendError::Transport(e.to_string()))?;

        let mut buffer = vec![0u8; DEFAULT_RESPONSE_BUFFER_SIZE];
        let rc = unsafe {
            cactus_sys::cactus_complete(
                self.handle,
                messages_c.as_ptr(),
                buffer.as_mut_ptr() as *mut c_char,
                buffer.len(),
                options_c.as_ref().map_or(ptr::null(), |s| s.as_ptr()),
                ptr::null(),
                None,
                ptr::null_mut(),
                ptr::null(),
                0,
            )
        };

        self.decode_response(rc, &buffer, "cactus_complete")
    }

    pub fn transcribe_pcm(
        &self,
        pcm_buffer: &[u8],
        prompt: Option<&str>,
        options_json: Option<&str>,
    ) -> Result<CactusResponseEnvelope, BackendError> {
        let _guard = self
            .lock
            .lock()
            .map_err(|_| BackendError::Transport("cactus model mutex poisoned".into()))?;

        let prompt_c = prompt
            .map(CString::new)
            .transpose()
            .map_err(|e| BackendError::Transport(e.to_string()))?;
        let options_c = options_json
            .map(CString::new)
            .transpose()
            .map_err(|e| BackendError::Transport(e.to_string()))?;

        let mut buffer = vec![0u8; DEFAULT_RESPONSE_BUFFER_SIZE];
        let rc = unsafe {
            cactus_sys::cactus_transcribe(
                self.handle,
                ptr::null(),
                prompt_c.as_ref().map_or(ptr::null(), |s| s.as_ptr()),
                buffer.as_mut_ptr() as *mut c_char,
                buffer.len(),
                options_c.as_ref().map_or(ptr::null(), |s| s.as_ptr()),
                None,
                ptr::null_mut(),
                pcm_buffer.as_ptr(),
                pcm_buffer.len(),
            )
        };

        self.decode_response(rc, &buffer, "cactus_transcribe")
    }

    fn decode_response(
        &self,
        rc: i32,
        buffer: &[u8],
        op_name: &str,
    ) -> Result<CactusResponseEnvelope, BackendError> {
        if rc < 0 {
            return Err(BackendError::Transport(format!("{op_name} returned {rc}")));
        }

        let cstr = unsafe { CStr::from_ptr(buffer.as_ptr() as *const c_char) };
        let raw = cstr
            .to_str()
            .map_err(|e| BackendError::Transport(format!("{op_name} utf8: {e}")))?;

        let envelope: CactusResponseEnvelope = serde_json::from_str(raw)
            .map_err(|e| BackendError::Transport(format!("{op_name} json: {e}")))?;

        if !envelope.success {
            return Err(BackendError::Transport(
                envelope
                    .error
                    .clone()
                    .unwrap_or_else(|| format!("{op_name} returned success=false")),
            ));
        }

        Ok(envelope)
    }
}

impl Drop for CactusModel {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { cactus_sys::cactus_destroy(self.handle) };
            self.handle = ptr::null_mut();
        }
    }
}
