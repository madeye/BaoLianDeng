//! tracing subscriber wiring for the FFI layer.
//!
//! A single global subscriber is installed lazily (first `set_log_file` or
//! first engine start). It has one fmt layer whose writer routes through a
//! global `Mutex<Option<LogFile>>` (swapped by `set_log_file`, rotated in
//! place by `trim_log_file`) and whose event format is
//! `[Mihomo/<level>] <message>\n` — matching the Go bridge's engine-log sink.
//! Swift concatenates the file as raw text, so the format is cosmetic only. A
//! `reload`-wrapped level filter backs `set_level`.
//!
//! Trimming lives here, not in Swift, on purpose: the sink keeps an open
//! append-mode handle, so a rewrite done by *another* process — Swift's
//! atomic `String.write(to:)` renames a fresh file over the path — would
//! leave the sink writing to the unlinked old inode: new engine lines vanish
//! from the viewer while the orphan keeps growing. [`trim_log_file`] rewrites
//! and reopens under the sink's own lock, so every line logged after it lands
//! in the file the viewer reads.

use parking_lot::Mutex;
use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Once, OnceLock};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::filter::LevelFilter;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::{FmtContext, FormatEvent, FormatFields, MakeWriter};
use tracing_subscriber::registry::LookupSpan;

/// The active sink: the append handle plus the path it was opened at, so the
/// file can be rotated and the handle reopened without the caller having to
/// know (or repeat) the path.
struct LogFile {
    path: PathBuf,
    file: File,
}

static LOG_FILE: Mutex<Option<LogFile>> = Mutex::new(None);
static INIT: Once = Once::new();
static SET_LEVEL: OnceLock<Box<dyn Fn(LevelFilter) + Send + Sync>> = OnceLock::new();

/// Writes every log line through the global, swappable file handle. When no
/// file is set the bytes are discarded (reported as written) so the subscriber
/// never errors.
struct FileSink;

impl Write for FileSink {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match LOG_FILE.lock().as_mut() {
            Some(lf) => lf.file.write(buf),
            None => Ok(buf.len()),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match LOG_FILE.lock().as_mut() {
            Some(lf) => lf.file.flush(),
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

fn open_append(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("open log file: {e}"))
}

/// Open (create/append) `path` and make it the active log sink.
pub fn set_log_file(path: &str) -> Result<(), String> {
    ensure_subscriber();
    let path = PathBuf::from(path);
    let file = open_append(&path)?;
    *LOG_FILE.lock() = Some(LogFile { path, file });
    Ok(())
}

/// Keep only the last `max_lines` lines of the active log file, atomically
/// (write a sibling temp file, rename over the path), and reopen the sink on
/// the new file — all under the sink's writer lock, so no line is lost or
/// written to an orphaned inode. A no-op when no log file is set or the file
/// is already within the cap. `max_lines <= 0` is rejected.
pub fn trim_log_file(max_lines: i64) -> Result<(), String> {
    if max_lines <= 0 {
        return Err(format!("max_lines must be > 0, got {max_lines}"));
    }
    let max_lines = max_lines as usize;
    let mut slot = LOG_FILE.lock();
    let Some(lf) = slot.as_mut() else {
        return Ok(());
    };
    // Push any buffered bytes out first so the read below sees them.
    lf.file
        .flush()
        .map_err(|e| format!("flush log file: {e}"))?;
    let content = match std::fs::read(&lf.path) {
        Ok(bytes) => bytes,
        // Deleted out from under us (the app cleared it): just reopen so
        // subsequent lines become visible at the path again.
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            lf.file = open_append(&lf.path)?;
            return Ok(());
        }
        Err(e) => return Err(format!("read log file: {e}")),
    };
    let Some(tail) = tail_lines(&content, max_lines) else {
        // Nothing to cut. Still make sure the handle is on the file that is
        // at the path: if something replaced it underneath us, reattach.
        if detached(lf) {
            lf.file = open_append(&lf.path)?;
        }
        return Ok(());
    };
    let tmp = lf.path.with_extension("log.trim");
    let mut new_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&tmp)
        .map_err(|e| format!("create trimmed log file: {e}"))?;
    new_file
        .write_all(tail)
        .and_then(|()| new_file.sync_data())
        .map_err(|e| format!("write trimmed log file: {e}"))?;
    if let Err(e) = std::fs::rename(&tmp, &lf.path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("replace log file: {e}"));
    }
    // Reopen at the path so the sink writes to the file that is now there,
    // never to the unlinked inode the old handle still points at.
    lf.file = open_append(&lf.path)?;
    Ok(())
}

/// True when the file at `lf.path` is no longer the one `lf.file` has open
/// (replaced by rename, or gone) — i.e. the sink is writing into an orphan.
fn detached(lf: &LogFile) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (std::fs::metadata(&lf.path), lf.file.metadata()) {
        (Ok(at_path), Ok(held)) => at_path.dev() != held.dev() || at_path.ino() != held.ino(),
        _ => true,
    }
}

/// The suffix of `content` holding its last `max_lines` lines (a trailing
/// newline does not start a new line), or `None` when it is already within
/// the cap and nothing needs rewriting.
fn tail_lines(content: &[u8], max_lines: usize) -> Option<&[u8]> {
    let body = content.strip_suffix(b"\n").unwrap_or(content);
    if body.is_empty() {
        return None;
    }
    // Walk newlines from the end; the cut lands just after the newline that
    // precedes the `max_lines`-th line from the back.
    let mut newlines_seen = 0usize;
    for (idx, &b) in body.iter().enumerate().rev() {
        if b == b'\n' {
            newlines_seen += 1;
            if newlines_seen == max_lines {
                return Some(&content[idx + 1..]);
            }
        }
    }
    None
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

#[cfg(test)]
mod tests {
    use super::*;

    fn line_count(path: &Path) -> usize {
        std::fs::read_to_string(path)
            .unwrap_or_default()
            .lines()
            .count()
    }

    #[test]
    fn tail_lines_keeps_only_the_last_n() {
        assert_eq!(tail_lines(b"a\nb\nc\n", 2), Some(&b"b\nc\n"[..]));
        assert_eq!(tail_lines(b"a\nb\nc", 2), Some(&b"b\nc"[..]));
        assert_eq!(tail_lines(b"a\nb\nc\n", 3), None, "exactly at cap");
        assert_eq!(tail_lines(b"a\nb\nc\n", 5), None, "under cap");
        assert_eq!(tail_lines(b"", 1), None);
        assert_eq!(tail_lines(b"\n", 1), None, "one empty line is within cap");
        assert_eq!(tail_lines(b"a\nb\n", 1), Some(&b"b\n"[..]));
    }

    // Regression (issue #113, finding 7): the provider used to trim
    // rust_bridge.log with an atomic replace from Swift, which left this
    // sink's open append handle on the unlinked old inode — every engine
    // line logged afterwards disappeared from the file the viewer reads.
    // Trimming through the sink must keep the file bounded AND keep later
    // lines visible at the path.
    #[test]
    fn trim_keeps_file_bounded_and_later_lines_visible() {
        let _g = crate::TEST_LOCK.lock();
        let dir = std::env::temp_dir().join(format!("meow-ffi-logtrim-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rust_bridge.log");
        set_log_file(path.to_str().unwrap()).unwrap();

        const CAP: usize = 50;
        for i in 0..(CAP * 3) {
            tracing::info!("filler line {i}");
        }
        assert!(
            line_count(&path) > CAP,
            "sink did not write through: {} lines",
            line_count(&path)
        );

        trim_log_file(CAP as i64).unwrap();
        let after_trim = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            after_trim.lines().count(),
            CAP,
            "trim must keep exactly the cap"
        );
        assert!(
            after_trim.contains(&format!("filler line {}", CAP * 3 - 1)),
            "trim must keep the newest lines"
        );
        assert!(
            !after_trim.contains("filler line 0\n"),
            "trim must drop the oldest lines"
        );

        // A line logged AFTER the trim must land in the file at the path,
        // not in an orphaned inode.
        let marker = format!("post-trim marker {}", std::process::id());
        tracing::info!("{marker}");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(
            content.contains(&marker),
            "engine log written after trim is not visible at the log path"
        );
        assert_eq!(content.lines().count(), CAP + 1, "file stays bounded");

        // Within the cap: no rewrite, nothing lost.
        trim_log_file((CAP * 4) as i64).unwrap();
        assert!(std::fs::read_to_string(&path).unwrap().contains(&marker));

        assert!(trim_log_file(0).is_err(), "non-positive cap is rejected");

        *LOG_FILE.lock() = None;
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A trim must never be silently defeated by an external replace that
    /// happened before it: reopening puts the sink back on the live path.
    #[test]
    fn trim_reattaches_after_external_replace() {
        let _g = crate::TEST_LOCK.lock();
        let dir = std::env::temp_dir().join(format!("meow-ffi-logreattach-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("rust_bridge.log");
        set_log_file(path.to_str().unwrap()).unwrap();
        tracing::info!("before external replace");

        // Simulate the old Swift-side atomic rewrite (new inode at the path).
        let tmp = dir.join("swap.tmp");
        std::fs::write(&tmp, "kept by external rewrite\n").unwrap();
        std::fs::rename(&tmp, &path).unwrap();

        trim_log_file(1000).unwrap();
        tracing::info!("after trim reattach");
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("kept by external rewrite"));
        assert!(
            content.contains("after trim reattach"),
            "sink still writes to the unlinked inode after trim: {content:?}"
        );

        *LOG_FILE.lock() = None;
        let _ = std::fs::remove_dir_all(&dir);
    }
}
