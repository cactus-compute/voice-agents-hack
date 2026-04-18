//! Per-turn trace collector. Every stage records what happened so the UI can
//! render an inspectable execution trail. Optionally streams JSON Lines to a
//! sink for live tailing.

use std::io::{stderr, Write};
use std::sync::Mutex;
use std::time::Instant;

use serde_json::{Map, Value};

use crate::contracts::{TraceEvent, TraceStage};

type EventCallback = Box<dyn Fn(&TraceEvent) + Send + Sync>;

pub struct Tracer {
    events: Mutex<Vec<TraceEvent>>,
    emit_jsonl: bool,
    sink: Mutex<Box<dyn Write + Send>>,
    on_event: Option<EventCallback>,
}

impl std::fmt::Debug for Tracer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Tracer")
            .field("events", &self.events.lock().unwrap().len())
            .field("emit_jsonl", &self.emit_jsonl)
            .finish()
    }
}

impl Default for Tracer {
    fn default() -> Self {
        Self::new()
    }
}

impl Tracer {
    pub fn new() -> Self {
        Self {
            events: Mutex::new(Vec::new()),
            emit_jsonl: false,
            sink: Mutex::new(Box::new(stderr())),
            on_event: None,
        }
    }

    pub fn with_jsonl(mut self) -> Self {
        self.emit_jsonl = true;
        self
    }

    pub fn with_sink(mut self, sink: Box<dyn Write + Send>) -> Self {
        self.sink = Mutex::new(sink);
        self
    }

    pub fn on_event<F>(mut self, callback: F) -> Self
    where
        F: Fn(&TraceEvent) + Send + Sync + 'static,
    {
        self.on_event = Some(Box::new(callback));
        self
    }

    /// Record a one-shot event with zero duration.
    pub fn event(
        &self,
        stage: TraceStage,
        message: impl Into<String>,
        payload: Map<String, Value>,
    ) -> TraceEvent {
        let ev = TraceEvent {
            stage,
            message: message.into(),
            elapsed_ms: 0.0,
            payload,
        };
        self.record(ev.clone());
        ev
    }

    /// Open a timed span. The returned `Span` records its duration on drop.
    pub fn span<'a>(
        &'a self,
        stage: TraceStage,
        message: impl Into<String>,
        payload: Map<String, Value>,
    ) -> Span<'a> {
        Span {
            tracer: self,
            stage,
            message: message.into(),
            payload,
            started: Instant::now(),
            armed: true,
        }
    }

    pub fn events(&self) -> Vec<TraceEvent> {
        self.events.lock().unwrap().clone()
    }

    pub fn total_ms(&self) -> f64 {
        self.events.lock().unwrap().iter().map(|e| e.elapsed_ms).sum()
    }

    fn record(&self, ev: TraceEvent) {
        if self.emit_jsonl {
            if let Ok(line) = serde_json::to_string(&ev) {
                let mut sink = self.sink.lock().unwrap();
                let _ = writeln!(sink, "{}", line);
                let _ = sink.flush();
            }
        }
        if let Some(cb) = &self.on_event {
            cb(&ev);
        }
        self.events.lock().unwrap().push(ev);
    }
}

pub struct Span<'a> {
    tracer: &'a Tracer,
    stage: TraceStage,
    message: String,
    payload: Map<String, Value>,
    started: Instant,
    armed: bool,
}

impl<'a> Span<'a> {
    /// Add or overwrite a payload entry while the span is open.
    pub fn annotate(&mut self, key: impl Into<String>, value: impl Into<Value>) {
        self.payload.insert(key.into(), value.into());
    }

    /// Disarm so dropping does not record (useful when an explicit error event
    /// has already been recorded).
    pub fn disarm(&mut self) {
        self.armed = false;
    }
}

impl<'a> Drop for Span<'a> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let elapsed_ms = self.started.elapsed().as_secs_f64() * 1000.0;
        let ev = TraceEvent {
            stage: self.stage,
            message: std::mem::take(&mut self.message),
            elapsed_ms,
            payload: std::mem::take(&mut self.payload),
        };
        self.tracer.record(ev);
    }
}

/// Convenience to build a payload map inline: `payload!{ "k" => v, ... }`.
#[macro_export]
macro_rules! payload {
    () => {
        ::serde_json::Map::new()
    };
    ($($key:expr => $value:expr),+ $(,)?) => {{
        let mut m = ::serde_json::Map::new();
        $( m.insert($key.to_string(), ::serde_json::json!($value)); )+
        m
    }};
}
