//! tracing subscriber wiring for the FFI layer.
//!
//! A single global subscriber is installed lazily (first `set_log_file` or
//! first engine start). It has one fmt layer whose writer routes through a
//! global `Mutex<Option<File>>` (swapped by `set_log_file`) and whose event
//! format is `[Mihomo/<level>] <message>\n` — matching the Go bridge's
//! engine-log sink. Swift concatenates the file as raw text, so the format is
//! cosmetic only. A `reload`-wrapped level filter backs `set_level`.

use parking_lot::Mutex;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::sync::{Once, OnceLock};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::{FmtContext, FormatEvent, FormatFields, MakeWriter};
use tracing_subscriber::registry::LookupSpan;

static LOG_FILE: Mutex<Option<File>> = Mutex::new(None);
static INIT: Once = Once::new();
static SET_LEVEL: OnceLock<Box<dyn Fn(LevelFilter) + Send + Sync>> = OnceLock::new();

/// Writes every log line through the global, swappable file handle. When no
/// file is set the bytes are discarded (reported as written) so the subscriber
/// never errors.
struct FileSink;

impl Write for FileSink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match LOG_FILE.lock().as_mut() {
            Some(f) => f.write(buf),
            None => Ok(buf.len()),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match LOG_FILE.lock().as_mut() {
            Some(f) => f.flush(),
            None => Ok(()),
        }
    }
}

struct FileMakeWriter;

impl<'a> MakeWriter<'a> for FileMakeWriter {
    type Writer = FileSink;
    fn make_writer(&'a self) -> FileSink {
        FileSink
    }
}

/// Emits `[Mihomo/<level>] <fields>\n`. Level names use the mihomo spelling
/// (`warning` rather than `warn`) so log text matches the previous Go bridge.
struct MihomoFormat;

impl<S, N> FormatEvent<S, N> for MihomoFormat
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        mut writer: Writer<'_>,
        event: &Event<'_>,
    ) -> std::fmt::Result {
        let level = match *event.metadata().level() {
            Level::ERROR => "error",
            Level::WARN => "warning",
            Level::INFO => "info",
            Level::DEBUG => "debug",
            Level::TRACE => "trace",
        };
        write!(writer, "[Mihomo/{level}] ")?;
        ctx.field_format().format_fields(writer.by_ref(), event)?;
        writeln!(writer)
    }
}

/// Install the global subscriber exactly once. Safe to call repeatedly.
pub fn ensure_subscriber() {
    INIT.call_once(|| {
        use tracing_subscriber::prelude::*;

        let (filter, handle) = tracing_subscriber::reload::Layer::new(LevelFilter::INFO);
        let fmt_layer = tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .event_format(MihomoFormat)
            .with_writer(FileMakeWriter)
            .with_filter(filter);
        // try_init: tolerate a subscriber already installed by the host process.
        let _ = tracing_subscriber::registry().with(fmt_layer).try_init();
        let _ = SET_LEVEL.set(Box::new(move |lv| {
            let _ = handle.modify(|f| *f = lv);
        }));
    });
}

/// Open (create/append) `path` and make it the active log sink.
pub fn set_log_file(path: &str) -> Result<(), String> {
    ensure_subscriber();
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("open log file: {e}"))?;
    *LOG_FILE.lock() = Some(file);
    Ok(())
}

/// Update the active level filter. Mihomo level names → tracing filters;
/// unknown names are ignored.
pub fn set_level(level: &str) {
    let filter = match level {
        "debug" => LevelFilter::DEBUG,
        "info" => LevelFilter::INFO,
        "warning" => LevelFilter::WARN,
        "error" => LevelFilter::ERROR,
        "silent" => LevelFilter::OFF,
        _ => return,
    };
    if let Some(apply) = SET_LEVEL.get() {
        apply(filter);
    }
}
