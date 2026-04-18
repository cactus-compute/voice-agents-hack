//! In-process Cactus backend.
//!
//! Loads `libcactus.{dylib,so}` at runtime via `libloading` (so the workspace
//! compiles even when Cactus isn't built) and holds a persistent model handle.
//! That eliminates the per-call subprocess cold-start the Python version pays.
//!
//! Required env vars:
//!   CACTUS_MODEL_PATH  — path to the `.gguf` (or Cactus packaged) weights
//!   CACTUS_LIB_DIR     — directory containing `libcactus.dylib`/`.so` (optional
//!                        if the OS loader can already find it)

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::Mutex;

use libloading::{Library, Symbol};
use serde_json::json;

use super::{BackendError, GemmaBackend};

type CactusInitFn = unsafe extern "C" fn(*const c_char, *const c_char, bool) -> *mut c_void;
type CactusDestroyFn = unsafe extern "C" fn(*mut c_void);
type CactusCompleteFn = unsafe extern "C" fn(
    *mut c_void,
    *const c_char,
    *mut c_char,
    usize,
    *const c_char,
    *const c_char,
    *const c_void,
    *mut c_void,
    *const u8,
    usize,
) -> c_int;

pub struct LocalCactusBackend {
    _lib: Library,
    model: *mut c_void,
    complete: CactusCompleteFn,
    destroy: CactusDestroyFn,
    lock: Mutex<()>,
    system_prompt: Option<String>,
    buffer_size: usize,
}

unsafe impl Send for LocalCactusBackend {}
unsafe impl Sync for LocalCactusBackend {}

impl LocalCactusBackend {
    pub fn from_env() -> Result<Self, BackendError> {
        let model_path = std::env::var("CACTUS_MODEL_PATH")
            .map_err(|_| BackendError::NotConfigured("CACTUS_MODEL_PATH missing".into()))?;
        let lib_dir = std::env::var("CACTUS_LIB_DIR").ok();
        Self::new(model_path, lib_dir, None)
    }

    pub fn new(
        model_path: impl Into<String>,
        lib_dir: Option<String>,
        system_prompt: Option<String>,
    ) -> Result<Self, BackendError> {
        let lib_name = if cfg!(target_os = "macos") {
            "libcactus.dylib"
        } else if cfg!(target_os = "windows") {
            "cactus.dll"
        } else {
            "libcactus.so"
        };

        let lib_path: PathBuf = match lib_dir {
            Some(dir) => PathBuf::from(dir).join(lib_name),
            None => PathBuf::from(lib_name),
        };

        let lib = unsafe {
            Library::new(&lib_path)
                .map_err(|e| BackendError::NotConfigured(format!("load {lib_path:?}: {e}")))?
        };

        let init: Symbol<CactusInitFn> = unsafe {
            lib.get(b"cactus_init")
                .map_err(|e| BackendError::NotConfigured(format!("cactus_init: {e}")))?
        };
        let complete: Symbol<CactusCompleteFn> = unsafe {
            lib.get(b"cactus_complete")
                .map_err(|e| BackendError::NotConfigured(format!("cactus_complete: {e}")))?
        };
        let destroy: Symbol<CactusDestroyFn> = unsafe {
            lib.get(b"cactus_destroy")
                .map_err(|e| BackendError::NotConfigured(format!("cactus_destroy: {e}")))?
        };

        let path_c =
            CString::new(model_path.into()).map_err(|e| BackendError::Transport(e.to_string()))?;

        let model = unsafe { init(path_c.as_ptr(), std::ptr::null(), false) };
        if model.is_null() {
            return Err(BackendError::NotConfigured(
                "cactus_init returned null — bad model path?".into(),
            ));
        }

        // Capture concrete function pointers; the Symbol borrows from `lib`,
        // so by storing the raw fn we can keep just the Library handle.
        let complete_fn: CactusCompleteFn = *complete;
        let destroy_fn: CactusDestroyFn = *destroy;
        let _ = init;
        let _ = complete;
        let _ = destroy;

        Ok(Self {
            _lib: lib,
            model,
            complete: complete_fn,
            destroy: destroy_fn,
            lock: Mutex::new(()),
            system_prompt,
            buffer_size: 16 * 1024,
        })
    }
}

impl Drop for LocalCactusBackend {
    fn drop(&mut self) {
        if !self.model.is_null() {
            unsafe { (self.destroy)(self.model) };
            self.model = std::ptr::null_mut();
        }
    }
}

impl GemmaBackend for LocalCactusBackend {
    fn name(&self) -> &'static str {
        "cactus-local"
    }

    fn generate(&self, prompt: &str, max_tokens: usize) -> Result<String, BackendError> {
        let _guard = self.lock.lock().map_err(|_| {
            BackendError::Transport("cactus backend mutex poisoned".into())
        })?;

        let mut messages: Vec<serde_json::Value> = Vec::new();
        if let Some(sys) = &self.system_prompt {
            messages.push(json!({"role": "system", "content": sys}));
        }
        messages.push(json!({"role": "user", "content": prompt}));

        let messages_json = serde_json::to_string(&messages)
            .map_err(|e| BackendError::Transport(format!("encode: {e}")))?;
        let options_json = json!({"max_tokens": max_tokens, "temperature": 0.2}).to_string();

        let messages_c =
            CString::new(messages_json).map_err(|e| BackendError::Transport(e.to_string()))?;
        let options_c =
            CString::new(options_json).map_err(|e| BackendError::Transport(e.to_string()))?;

        let mut buffer = vec![0u8; self.buffer_size];

        let rc = unsafe {
            (self.complete)(
                self.model,
                messages_c.as_ptr(),
                buffer.as_mut_ptr() as *mut c_char,
                buffer.len(),
                options_c.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null(),
                0,
            )
        };

        if rc < 0 {
            return Err(BackendError::Transport(format!(
                "cactus_complete returned {rc}"
            )));
        }

        let cstr = unsafe { CStr::from_ptr(buffer.as_ptr() as *const c_char) };
        let text = cstr
            .to_str()
            .map_err(|e| BackendError::Transport(format!("utf8: {e}")))?
            .to_string();

        if text.is_empty() {
            return Err(BackendError::EmptyResponse);
        }
        Ok(text)
    }
}
