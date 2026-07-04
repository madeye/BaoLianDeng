// C FFI bridge embedding the meow-rs proxy kernel.
//
// Exports the exact `bridge_*` C ABI the previous Go cgo archive exported, so
// the hand-written ObjC wrapper (objc/MihomoCore.m) and every Swift call site
// work unchanged.
//
// Panic policy: the crate builds with panic = "unwind" and EVERY exported
// function wraps its body in `std::panic::catch_unwind`, converting any panic
// into the function's safe default (-1 / 0 / false / null / a "FAIL:" string)
// after recording a last-error. A Rust panic must never unwind across the C
// ABI (that is undefined behavior); abort would defeat catch_unwind, so unwind
// + catch is the correct choice here.
//
// Safety: these are thin C-ABI shims over caller-supplied pointers. Individual
// `# Safety` docs would be pure boilerplate ("pointer must be a valid NUL-
// terminated C string, or null"), so the lint is allowed crate-wide.
#![allow(clippy::missing_safety_doc)]

mod diagnostics;
mod engine;
mod geodata;
mod logging;

use engine::EngineState;
use parking_lot::Mutex;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;
use tokio::runtime::Runtime;

// ---------------------------------------------------------------------------
// Shared runtime (process-global, reused across start/stop — 2 workers to
// stay lean under the NE ~15 MB memory ceiling).
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub(crate) fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("failed to build tokio runtime")
    })
}

// ---------------------------------------------------------------------------
// Global state — all engine mutation serialized under ENGINE.
// ---------------------------------------------------------------------------

static ENGINE: Mutex<Option<EngineState>> = Mutex::new(None);
static HOME_DIR: Mutex<Option<String>> = Mutex::new(None);

// Traffic is cumulative for the whole PROCESS lifetime (Go semantics: not reset
// by stop/start). meow-tunnel's Statistics is per-engine-instance, so on stop
// we fold the final snapshot into these base counters; getters return
// base + live-snapshot (live is 0 when stopped).
static TRAFFIC_UP_BASE: AtomicI64 = AtomicI64::new(0);
static TRAFFIC_DOWN_BASE: AtomicI64 = AtomicI64::new(0);

pub(crate) fn current_socks_port() -> i32 {
    ENGINE.lock().as_ref().map(|s| s.socks_port).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Last error (per-thread; caller does NOT free — reads it immediately after a
// failing call on the same thread, matching the ObjC wrapper's makeError()).
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

pub(crate) fn set_error(msg: impl Into<String>) {
    let c = CString::new(msg.into())
        .unwrap_or_else(|_| CString::new("error contained interior NUL").unwrap());
    LAST_ERROR.with(|e| *e.borrow_mut() = c);
}

#[no_mangle]
pub extern "C" fn bridge_get_last_error() -> *const c_char {
    LAST_ERROR.with(|e| e.borrow().as_ptr())
}

#[no_mangle]
pub unsafe extern "C" fn bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

// ---------------------------------------------------------------------------
// Panic guards + string helpers.
// ---------------------------------------------------------------------------

/// Run `f`, converting a panic into `default` after recording a last-error.
fn guard<T>(default: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_) => {
            set_error("internal panic in bridge call");
            default
        }
    }
}

/// Diagnostics variant: a panic yields a heap `FAIL:` C string.
fn guard_cstr(f: impl FnOnce() -> String) -> *mut c_char {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(s) => into_c(s),
        Err(_) => into_c("FAIL: internal panic".to_string()),
    }
}

unsafe fn cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        None
    } else {
        CStr::from_ptr(ptr).to_str().ok()
    }
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

// ---------------------------------------------------------------------------
// Home dir / config path.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bridge_set_home_dir(dir: *const c_char) {
    guard((), || {
        let Some(d) = cstr(dir) else { return };
        if d.is_empty() {
            return;
        }
        *HOME_DIR.lock() = Some(d.to_string());
        // meow's home dir is a first-write-wins OnceLock used by geodata path
        // helpers. Config loading uses HOME_DIR (last-wins) so restarting with
        // a different dir still finds the right config.yaml; only geodata
        // default paths stay pinned to the first value.
        meow_common::set_home_dir(PathBuf::from(d));
    });
}

// ---------------------------------------------------------------------------
// Logging.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bridge_set_log_file(path: *const c_char) -> i32 {
    guard(-1, || {
        let Some(p) = cstr(path) else {
            set_error("log file path is null");
            return -1;
        };
        match logging::set_log_file(p) {
            Ok(()) => 0,
            Err(e) => {
                set_error(e);
                -1
            }
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn bridge_update_log_level(level: *const c_char) {
    guard((), || {
        if let Some(l) = cstr(level) {
            logging::set_level(l);
        }
    });
}

// ---------------------------------------------------------------------------
// Config validation.
// ---------------------------------------------------------------------------

/// meow-config only *warns* on rules that reference an undefined proxy/group.
/// The Swift tests require validation to reject them with the offending name in
/// the message, so cross-check every rule's target against the built proxy map
/// (which contains DIRECT/REJECT plus all proxies and groups).
fn undefined_rule_target(config: &meow_config::Config) -> Option<String> {
    const BUILTIN: &[&str] = &[
        "DIRECT",
        "REJECT",
        "REJECT-DROP",
        "PASS",
        "COMPATIBLE",
        "GLOBAL",
    ];
    for rule in &config.rules {
        let target = rule.adapter();
        if BUILTIN.contains(&target) {
            continue;
        }
        if !config.proxies.keys().any(|k| k.as_str() == target) {
            return Some(target.to_string());
        }
    }
    None
}

#[no_mangle]
pub unsafe extern "C" fn bridge_validate_config(yaml: *const c_char) -> i32 {
    guard(-1, || {
        let Some(y) = cstr(yaml) else {
            set_error("config is null");
            return -1;
        };
        // Pin geodata paths to the bridge home dir (if one is set) so GEOIP/
        // GEOSITE rules validate against <home>/Country.mmdb + geosite.dat
        // rather than meow's OnceLock-discovered default. Owned String so the
        // borrow doesn't tie into the parsed future.
        let pinned = match HOME_DIR.lock().as_deref() {
            Some(home) => geodata::pin_geodata_paths(y, home),
            None => y.to_string(),
        };
        match runtime().block_on(meow_config::load_config_from_str(&pinned)) {
            Ok(config) => {
                if let Some(bad) = undefined_rule_target(&config) {
                    set_error(format!(
                        "rules: reference to undefined proxy or group '{bad}'"
                    ));
                    return -1;
                }
                0
            }
            Err(e) => {
                set_error(e.to_string());
                -1
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Lifecycle.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bridge_start_with_ports(
    socks_port: i32,
    dns_port: i32,
    controller_addr: *const c_char,
    secret: *const c_char,
) -> i32 {
    guard(-1, || {
        let mut engine = ENGINE.lock();
        if engine.is_some() {
            set_error("proxy is already running");
            return -1;
        }
        if socks_port <= 0 || dns_port <= 0 {
            set_error("socks_port and dns_port must be > 0");
            return -1;
        }
        let Some(addr) = cstr(controller_addr) else {
            set_error("controller_addr is null");
            return -1;
        };
        let secret_s = cstr(secret).unwrap_or("").to_string();

        let Some(home) = HOME_DIR.lock().clone() else {
            set_error("home dir not set");
            return -1;
        };
        let config_path = format!("{home}/config.yaml");
        if !std::path::Path::new(&config_path).exists() {
            set_error(format!("config.yaml not found at {config_path}"));
            return -1;
        }

        logging::ensure_subscriber();
        match runtime().block_on(engine::assemble(
            config_path,
            home,
            socks_port,
            dns_port,
            addr.to_string(),
            secret_s,
        )) {
            Ok(state) => {
                *engine = Some(state);
                0
            }
            Err(e) => {
                set_error(format!("start proxy: {e}"));
                -1
            }
        }
    })
}

#[no_mangle]
pub extern "C" fn bridge_stop_proxy() {
    guard((), || {
        let mut engine = ENGINE.lock();
        if let Some(state) = engine.take() {
            // Fold the final traffic snapshot into the process-lifetime base
            // before dropping the engine (and its per-instance Statistics).
            let (up, down) = state.tunnel.statistics().snapshot();
            TRAFFIC_UP_BASE.fetch_add(up, Ordering::Relaxed);
            TRAFFIC_DOWN_BASE.fetch_add(down, Ordering::Relaxed);
            for handle in &state.handles {
                handle.abort();
            }
            // `state` drops here: tunnel, handles, listeners all released.
        }
    });
}

#[no_mangle]
pub extern "C" fn bridge_is_running() -> bool {
    guard(false, || ENGINE.lock().is_some())
}

#[no_mangle]
pub extern "C" fn bridge_get_socks_port() -> i32 {
    guard(0, || {
        ENGINE.lock().as_ref().map(|s| s.socks_port).unwrap_or(0)
    })
}

#[no_mangle]
pub extern "C" fn bridge_get_dns_port() -> i32 {
    guard(0, || {
        ENGINE.lock().as_ref().map(|s| s.dns_port).unwrap_or(0)
    })
}

#[no_mangle]
pub extern "C" fn bridge_get_external_controller_addr() -> *mut c_char {
    guard(std::ptr::null_mut(), || match ENGINE.lock().as_ref() {
        Some(s) => into_c(s.controller_addr.clone()),
        None => std::ptr::null_mut(),
    })
}

// ---------------------------------------------------------------------------
// Traffic (cumulative for process lifetime).
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn bridge_get_upload_traffic() -> i64 {
    guard(0, || {
        let base = TRAFFIC_UP_BASE.load(Ordering::Relaxed);
        match ENGINE.lock().as_ref() {
            Some(s) => base + s.tunnel.statistics().snapshot().0,
            None => base,
        }
    })
}

#[no_mangle]
pub extern "C" fn bridge_get_download_traffic() -> i64 {
    guard(0, || {
        let base = TRAFFIC_DOWN_BASE.load(Ordering::Relaxed);
        match ENGINE.lock().as_ref() {
            Some(s) => base + s.tunnel.statistics().snapshot().1,
            None => base,
        }
    })
}

// ---------------------------------------------------------------------------
// Version / GC.
// ---------------------------------------------------------------------------

static VERSION: OnceLock<CString> = OnceLock::new();

#[no_mangle]
pub extern "C" fn bridge_version() -> *const c_char {
    // meow crate version at the pinned rev; cosmetic (Swift never parses it).
    VERSION
        .get_or_init(|| CString::new("meow-rs 0.16.0").unwrap())
        .as_ptr()
}

/// No-op — Rust manages its own memory. The symbol MUST exist (Swift calls it
/// on a 10s timer).
#[no_mangle]
pub extern "C" fn bridge_force_gc() {}

// ---------------------------------------------------------------------------
// Diagnostics.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "C" fn bridge_test_direct_tcp(host: *const c_char, port: i32) -> *mut c_char {
    let host = cstr(host).unwrap_or("").to_string();
    guard_cstr(move || diagnostics::test_direct_tcp(&host, port))
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_proxy_http(target: *const c_char) -> *mut c_char {
    let target = cstr(target).unwrap_or("").to_string();
    guard_cstr(move || diagnostics::test_proxy_http(&target))
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_dns_resolver(dns_addr: *const c_char) -> *mut c_char {
    let dns_addr = cstr(dns_addr).unwrap_or("").to_string();
    guard_cstr(move || diagnostics::test_dns_resolver(&dns_addr))
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_selected_proxy(api_addr: *const c_char) -> *mut c_char {
    let api_addr = cstr(api_addr).unwrap_or("").to_string();
    guard_cstr(move || diagnostics::test_selected_proxy(&api_addr))
}

// ---------------------------------------------------------------------------
// Tests (loopback-only; no external network).
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    // Engine start/stop mutate process-global state; serialize the tests that
    // touch it.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    fn free_port() -> i32 {
        std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port() as i32
    }

    const MINIMAL_CONFIG: &str = "\
mixed-port: 7890
mode: rule
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: redir-host
  nameserver:
    - 127.0.0.1:5353
proxies: []
proxy-groups: []
rules:
  - MATCH,DIRECT
";

    fn validate(yaml: &str) -> i32 {
        let c = CString::new(yaml).unwrap();
        unsafe { bridge_validate_config(c.as_ptr()) }
    }

    #[test]
    fn validates_minimal_config() {
        let yaml = "mode: rule\nproxies: []\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - DIRECT\nrules:\n  - MATCH,DIRECT\n";
        assert_eq!(validate(yaml), 0);
    }

    #[test]
    fn rejects_undefined_group_by_name() {
        let yaml = "proxies: []\nproxy-groups: []\nrules:\n  - MATCH,NONEXISTENT\n";
        assert_eq!(validate(yaml), -1);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert!(err.contains("NONEXISTENT"), "error was: {err}");
    }

    #[test]
    fn rejects_invalid_yaml() {
        assert_eq!(validate("proxies: [[[invalid yaml\n"), -1);
    }

    #[test]
    fn version_is_non_empty() {
        let v = unsafe { CStr::from_ptr(bridge_version()) }
            .to_str()
            .unwrap();
        assert!(!v.is_empty());
        assert!(v.contains("meow-rs"), "version was: {v}");
    }

    // Real GeoLite2-Country fixture committed in the repo (8 MB); referenced by
    // relative path from the crate, never duplicated.
    const GEOIP_MMDB: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../TransparentProxyMac/Country.mmdb"
    );
    // Mirrors the Swift `uriListPassesValidation` merged config: default header
    // (mixed-port/dns/external-controller) + a vless node + default rules that
    // include GEOIP,CN,DIRECT — the exact shape that regressed.
    const GEOIP_CFG: &str = "mixed-port: 0\nmode: rule\nlog-level: info\nallow-lan: false\nexternal-controller: 127.0.0.1:0\n\ngeo-auto-update: false\n\ndns:\n  enable: true\n  listen: 127.0.0.1:0\n  enhanced-mode: redir-host\n  nameserver:\n    - 114.114.114.114\n    - 223.5.5.5\n\nproxies:\n  - name: \"TestNode\"\n    type: vless\n    server: \"1.2.3.4\"\n    port: 443\n    uuid: \"00000000-0000-0000-0000-000000000000\"\n    udp: true\n    tls: true\n    servername: \"example.com\"\n    network: ws\n    ws-opts:\n      path: \"/ws\"\n      headers:\n        Host: \"example.com\"\n\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - \"TestNode\"\n\nrules:\n  - DOMAIN-SUFFIX,google.com,PROXY\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n";

    // Regression for the Swift `uriListPassesValidation` failure: meow's home
    // dir is a first-write-wins OnceLock, so once test A pins it and deletes
    // its dir, a later GEOIP validate must still resolve the mmdb under the
    // CURRENT (last-wins) bridge home dir B — never the stale A.
    #[test]
    fn geoip_validates_under_current_home_despite_stale_oncelock() {
        let _g = TEST_LOCK.lock();
        if !std::path::Path::new(GEOIP_MMDB).exists() {
            return; // fixture unavailable (e.g. sparse checkout) — skip.
        }

        // Home A: set first (locks meow's OnceLock), validate, then delete it.
        let dir_a = std::env::temp_dir().join(format!("meow-ffi-geoa-{}", std::process::id()));
        std::fs::create_dir_all(&dir_a).unwrap();
        std::fs::copy(GEOIP_MMDB, dir_a.join("Country.mmdb")).unwrap();
        let a_c = CString::new(dir_a.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(a_c.as_ptr()) };
        assert_eq!(validate(GEOIP_CFG), 0, "GEOIP validate under home A failed");
        std::fs::remove_dir_all(&dir_a).unwrap();

        // Home B: fresh dir with the mmdb; meow's OnceLock is now stale (points
        // at deleted A). Validation must succeed via B, not error under A.
        let dir_b = std::env::temp_dir().join(format!("meow-ffi-geob-{}", std::process::id()));
        std::fs::create_dir_all(&dir_b).unwrap();
        std::fs::copy(GEOIP_MMDB, dir_b.join("Country.mmdb")).unwrap();
        let b_c = CString::new(dir_b.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(b_c.as_ptr()) };

        let rc = validate(GEOIP_CFG);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        let a_str = dir_a.to_str().unwrap().to_string();
        let _ = std::fs::remove_dir_all(&dir_b);
        assert_eq!(rc, 0, "GEOIP validate under home B failed: {err}");
        assert!(!err.contains(&a_str), "resolved stale home A: {err}");
    }

    #[test]
    fn start_stop_restart_cycle_and_traffic_monotonic() {
        let _g = TEST_LOCK.lock();

        let dir = std::env::temp_dir().join(format!("meow-ffi-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.yaml"), MINIMAL_CONFIG).unwrap();
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };

        let mut last_up = 0i64;
        let mut last_down = 0i64;

        for _ in 0..2 {
            let socks = free_port();
            let dns = free_port();
            let ctrl = free_port();
            let ctrl_c = CString::new(format!("127.0.0.1:{ctrl}")).unwrap();
            let secret_c = CString::new("").unwrap();

            let rc =
                unsafe { bridge_start_with_ports(socks, dns, ctrl_c.as_ptr(), secret_c.as_ptr()) };
            let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
                .to_str()
                .unwrap()
                .to_string();
            assert_eq!(rc, 0, "start failed: {err}");
            assert!(bridge_is_running());
            assert_eq!(bridge_get_socks_port(), socks);
            assert_eq!(bridge_get_dns_port(), dns);

            let addr = bridge_get_external_controller_addr();
            assert!(!addr.is_null());
            let addr_s = unsafe { CStr::from_ptr(addr) }
                .to_str()
                .unwrap()
                .to_string();
            unsafe { bridge_free_string(addr) };
            assert_eq!(addr_s, format!("127.0.0.1:{ctrl}"));

            // Traffic never decreases across the process lifetime.
            let up = bridge_get_upload_traffic();
            let down = bridge_get_download_traffic();
            assert!(up >= last_up, "upload regressed: {up} < {last_up}");
            assert!(
                down >= last_down,
                "download regressed: {down} < {last_down}"
            );
            last_up = up;
            last_down = down;

            bridge_stop_proxy();
            assert!(!bridge_is_running());
            assert_eq!(bridge_get_socks_port(), 0);

            // Still non-decreasing after stop (base retained).
            assert!(bridge_get_upload_traffic() >= last_up);
            assert!(bridge_get_download_traffic() >= last_down);
        }

        let _ = std::fs::remove_dir_all(&dir);
    }
}
