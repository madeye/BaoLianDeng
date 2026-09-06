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
use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::OnceLock;
use tokio::runtime::Runtime;

// ---------------------------------------------------------------------------
// Utility runtime (process-global; 2 workers to stay lean under the NE ~15 MB
// memory ceiling). Used ONLY for config validation and the `bridge_test_*`
// diagnostics. The engine itself never runs here: each engine generation owns
// a private runtime inside `EngineState` (see engine.rs) so that stopping the
// engine can cancel and await every task the kernel spawned, not just the
// top-level ones — a shared, never-shut-down runtime would keep accepted
// connections and health-check loops alive across stop/start.
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub(crate) fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("meow-ffi-util")
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
/// Controller REST secret for the currently-running engine, so in-process
/// diagnostics that hit the controller (see `diagnostics::test_selected_proxy`)
/// can send the same `Authorization: Bearer` the Swift REST clients do.
/// `None`/empty means the controller was started without auth (legacy).
static CONTROLLER_SECRET: Mutex<Option<String>> = Mutex::new(None);

// Traffic is cumulative for the whole PROCESS lifetime (Go semantics: not reset
// by stop/start). meow-tunnel's Statistics is per-engine-instance, so on stop
// we fold the final snapshot into these base counters; getters return
// base + live-snapshot (live is 0 when stopped).
static TRAFFIC_UP_BASE: AtomicI64 = AtomicI64::new(0);
static TRAFFIC_DOWN_BASE: AtomicI64 = AtomicI64::new(0);

pub(crate) fn current_socks_port() -> i32 {
    ENGINE.lock().as_ref().map(|s| s.socks_port).unwrap_or(0)
}

/// The running controller's REST secret, if one was set at start. Used by
/// in-process diagnostics to authenticate against the controller.
pub(crate) fn current_controller_secret() -> Option<String> {
    CONTROLLER_SECRET.lock().clone().filter(|s| !s.is_empty())
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
    match catch_unwind(AssertUnwindSafe(|| {
        LAST_ERROR.with(|e| e.borrow().as_ptr())
    })) {
        Ok(ptr) => ptr,
        Err(_) => std::ptr::null(),
    }
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

/// Reads a caller-supplied C string into an owned `String`. Returns an owned
/// copy (rather than a borrowed `&str`) so we never hand back a reference
/// into caller-owned memory whose lifetime the Rust borrow checker can't
/// actually track across the C ABI boundary — every call site needs the
/// bytes only transiently, so copying up front is both simpler and sound.
unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        CStr::from_ptr(ptr).to_str().ok().map(str::to_string)
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
        *HOME_DIR.lock() = Some(d.clone());
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
        match logging::set_log_file(&p) {
            Ok(()) => 0,
            Err(e) => {
                set_error(e);
                -1
            }
        }
    })
}

/// Keep only the last `max_lines` lines of the active log file, rotating it
/// under the sink's own lock and reopening the handle (see
/// `logging::trim_log_file`). Returns 0 on success (including the no-op cases:
/// no log file set, file already within the cap), -1 with a last-error
/// otherwise. Callers must use this instead of rewriting the file themselves:
/// an external atomic replace leaves the sink writing to the unlinked inode.
#[no_mangle]
pub extern "C" fn bridge_trim_log_file(max_lines: i32) -> i32 {
    guard(-1, || match logging::trim_log_file(max_lines as i64) {
        Ok(()) => 0,
        Err(e) => {
            set_error(e);
            -1
        }
    })
}

#[no_mangle]
pub unsafe extern "C" fn bridge_update_log_level(level: *const c_char) {
    guard((), || {
        if let Some(l) = cstr(level) {
            logging::set_level(&l);
        }
    });
}

// ---------------------------------------------------------------------------
// Config validation.
// ---------------------------------------------------------------------------

/// meow-config only *warns* on rules that reference an undefined proxy/group.
/// The Swift tests require validation to reject them with the offending name in
/// the message, so cross-check every rule's target against the built proxy map
/// (which contains DIRECT/REJECT plus all proxies and groups). `also_allowed`
/// holds group names that could not be built because validation stripped their
/// providers (see `strip_providers_for_validation`) — they exist at runtime, so
/// rules naming them are fine.
fn undefined_rule_target(
    config: &meow_config::Config,
    also_allowed: &HashSet<String>,
) -> Option<String> {
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
        if !config.proxies.keys().any(|k| k.as_str() == target) && !also_allowed.contains(target) {
            return Some(target.to_string());
        }
    }
    None
}

/// Strip `proxy-providers` / `rule-providers` from a config before validation.
///
/// `load_config_from_str` fetches every HTTP provider at load time: proxy-
/// providers via reqwest (30 s timeout each, sequential) and rule-providers
/// dialed through the config's FIRST PROXY with no connect timeout. The app
/// validates right after deliberately disconnecting the VPN, so those fetches
/// can stall for minutes and wedge the update flow (App Store feedback:
/// "更新配置文件无反应，只能强制退出"). The engine itself treats provider load
/// failures as warn-and-skip, so validating without providers checks the same
/// hard errors while staying fully offline.
///
/// Returns the stripped YAML plus the names of groups that reference a
/// stripped provider (`use:` / `include-all:`). Those groups may fail to
/// build without their providers (zero members), so `undefined_rule_target`
/// must still accept rules that target them. When the config has no provider
/// sections the original text is returned untouched and the set is empty —
/// group/rule validation stays as strict as before.
fn strip_providers_for_validation(yaml: &str) -> Option<(String, HashSet<String>)> {
    let mut doc: serde_yaml::Value = serde_yaml::from_str(yaml).ok()?;
    // Expand `<<: *anchor` merge keys so `name:`/`use:` supplied via anchors
    // (common in airport configs) are visible below. load_config_from_str
    // applies the same expansion, so re-serializing the expanded form is
    // semantically identical.
    doc.apply_merge().ok()?;
    let map = doc.as_mapping_mut()?;

    let mut provider_names: HashSet<String> = HashSet::new();
    for key in ["proxy-providers", "rule-providers"] {
        if let Some(section) = map.remove(key) {
            if let Some(m) = section.as_mapping() {
                provider_names.extend(m.keys().filter_map(|k| k.as_str().map(str::to_string)));
            }
        }
    }
    if provider_names.is_empty() {
        return Some((yaml.to_string(), HashSet::new()));
    }

    let mut provider_backed_groups: HashSet<String> = HashSet::new();
    if let Some(groups) = map.get("proxy-groups").and_then(|v| v.as_sequence()) {
        for g in groups {
            let uses_stripped = g
                .get("use")
                .and_then(|u| u.as_sequence())
                .is_some_and(|uses| {
                    uses.iter()
                        .filter_map(|u| u.as_str())
                        .any(|u| provider_names.contains(u))
                })
                || g.get("include-all")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
            if uses_stripped {
                if let Some(name) = g.get("name").and_then(|n| n.as_str()) {
                    provider_backed_groups.insert(name.to_string());
                }
            }
        }
    }

    let stripped = serde_yaml::to_string(&doc).ok()?;
    Some((stripped, provider_backed_groups))
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
            Some(home) => geodata::pin_geodata_paths(&y, home),
            None => y.clone(),
        };
        // Validate offline: never let provider HTTP fetches block validation.
        // If stripping fails (e.g. the YAML doesn't even parse), validate the
        // original text so load_config_from_str reports the real error.
        let (to_validate, provider_groups) = strip_providers_for_validation(&pinned)
            .unwrap_or_else(|| (pinned.clone(), HashSet::new()));
        match runtime().block_on(meow_config::load_config_from_str(&to_validate)) {
            Ok(config) => {
                if let Some(bad) = undefined_rule_target(&config, &provider_groups) {
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

/// Start the engine. SOCKS/DNS/controller bind loopback at the given ports.
/// LAN exposure is driven by the YAML (`allow-lan` / `bind-address` /
/// `mixed-port`) — see [`engine::assemble`].
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
        let secret_s = cstr(secret).unwrap_or_default();

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
        // Publish the secret so in-process diagnostics can authenticate against
        // the controller; cleared again if start fails or on stop.
        *CONTROLLER_SECRET.lock() = Some(secret_s.clone());
        // A fresh runtime per generation: everything `assemble` (and the
        // kernel underneath it) spawns lands here, so stop can tear it all
        // down by shutting the runtime down.
        let rt = match engine::build_runtime() {
            Ok(rt) => rt,
            Err(e) => {
                *CONTROLLER_SECRET.lock() = None;
                set_error(format!("start proxy: {e}"));
                return -1;
            }
        };
        match rt.block_on(engine::assemble(
            config_path,
            home,
            socks_port,
            dns_port,
            addr,
            secret_s,
        )) {
            Ok(assembled) => {
                *engine = Some(assembled.with_runtime(rt));
                0
            }
            Err(e) => {
                *CONTROLLER_SECRET.lock() = None;
                // `assemble` may have installed the host-resolver hook before
                // failing (a listener bind error comes later); don't leave a
                // hook pointing at a resolver whose engine never started.
                meow_common::clear_host_resolver();
                // Likewise it may have spawned some tasks (DNS server, API)
                // before the failing step; they die with the runtime.
                rt.shutdown_timeout(std::time::Duration::from_secs(2));
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
        *CONTROLLER_SECRET.lock() = None;
        // Drop the global host-resolver hook with the engine that installed
        // it: it holds an `Arc<Resolver>` from the stopped engine's config,
        // and leaving it installed would keep serving lookups (and pin the
        // old DNS cache) after `BridgeStopProxy`.
        meow_common::clear_host_resolver();
        if let Some(state) = engine.take() {
            // Shut the generation's runtime down: this cancels AND awaits
            // every task it ever spawned — listeners, each accepted
            // connection's relay, url-test / fallback health-check loops,
            // the NAT sweeper, DNS/API servers — so no session keeps flowing
            // through a stopped engine, no probe keeps firing, and the
            // listener sockets are released before we return (an immediate
            // restart on the same ports must not race an "address in use").
            // Bounded so a task stuck in a synchronous poll can't hang stop.
            let tunnel = state.shutdown();
            // Fold the final traffic snapshot into the process-lifetime base
            // only now, after every relay has stopped counting, then drop
            // the tunnel (and its per-instance Statistics).
            let (up, down) = tunnel.statistics().snapshot();
            TRAFFIC_UP_BASE.fetch_add(up, Ordering::Relaxed);
            TRAFFIC_DOWN_BASE.fetch_add(down, Ordering::Relaxed);
            drop(tunnel);
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
    match catch_unwind(AssertUnwindSafe(|| {
        VERSION
            .get_or_init(|| CString::new("meow-rs 0.21.2").unwrap())
            .as_ptr()
    })) {
        Ok(ptr) => ptr,
        Err(_) => std::ptr::null(),
    }
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
    // SAFETY: `host` is read (and copied to an owned String) only inside the
    // guarded closure, so a panic while reading a malformed/dangling pointer
    // is caught by catch_unwind rather than unwinding across the C ABI.
    guard_cstr(move || {
        let host = cstr(host).unwrap_or_default();
        diagnostics::test_direct_tcp(&host, port)
    })
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_proxy_http(target: *const c_char) -> *mut c_char {
    guard_cstr(move || {
        let target = cstr(target).unwrap_or_default();
        diagnostics::test_proxy_http(&target)
    })
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_dns_resolver(dns_addr: *const c_char) -> *mut c_char {
    guard_cstr(move || {
        let dns_addr = cstr(dns_addr).unwrap_or_default();
        diagnostics::test_dns_resolver(&dns_addr)
    })
}

#[no_mangle]
pub unsafe extern "C" fn bridge_test_selected_proxy(api_addr: *const c_char) -> *mut c_char {
    guard_cstr(move || {
        let api_addr = cstr(api_addr).unwrap_or_default();
        diagnostics::test_selected_proxy(&api_addr)
    })
}

// ---------------------------------------------------------------------------
// Tests (loopback-only; no external network).
// ---------------------------------------------------------------------------

/// Engine start/stop and the log sink mutate process-global state; every
/// test that touches either (here and in `logging`) serializes on this —
/// including config validation, which logs through the sink while it loads.
#[cfg(test)]
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::io::{Read, Write};
    use std::sync::atomic::AtomicUsize;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

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
  enhanced-mode: fake-ip
  fake-ip-range: 28.0.0.0/8
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
        let _g = TEST_LOCK.lock();
        let yaml = "mode: rule\nproxies: []\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - DIRECT\nrules:\n  - MATCH,DIRECT\n";
        assert_eq!(validate(yaml), 0);
    }

    // Regression: ss + `plugin: ech-tls-tunnel` must resolve to the BUILT-IN
    // transport (feature `ech-tls-tunnel` in meow-config). Without the feature
    // the adapter falls through to the external-SIP003-plugin path and tries
    // to spawn an `ech-tls-tunnel` subprocess — denied by the App Sandbox, so
    // the proxy was silently dropped and selector groups collapsed to DIRECT.
    // The MATCH rule targets the node, so a dropped proxy fails validation
    // instead of passing with a warn-and-skip. The ech_config is a real
    // ECHConfigList as published in Cloudflare's public DNS HTTPS records
    // (public key material only) — TlsLayer::new parses it structurally.
    #[test]
    fn validates_ss_ech_tls_tunnel_plugin() {
        let _g = TEST_LOCK.lock();
        let yaml = "\
mode: rule
proxies:
  - name: ech-node
    type: ss
    server: 127.0.0.1
    port: 443
    cipher: aes-128-gcm
    password: test
    plugin: ech-tls-tunnel
    plugin-opts:
      mode: client
      sni: example.com
      path: /ws-test
      ech_config: \"AEn+DQBF/gAgACCQeNQYP6XhS1bAPcT1x0nWjCNDLiaAg83tJwDi3QhDDwAIAAEAAQABAAMAEnd3dy5jbG91ZGZsYXJlLmNvbQAA\"
rules:
  - MATCH,ech-node
";
        let rc = validate(yaml);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap_or("")
            .to_string();
        assert_eq!(rc, 0, "validation error: {err}");
    }

    #[test]
    fn rejects_undefined_group_by_name() {
        let _g = TEST_LOCK.lock();
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
        let _g = TEST_LOCK.lock();
        assert_eq!(validate("proxies: [[[invalid yaml\n"), -1);
    }

    // Regression: validation must be OFFLINE. Before the strip, this config
    // made load_config_from_str fetch the rule-provider through the config's
    // first proxy (unreachable → no connect timeout → the app's update flow
    // hung until force quit) and the proxy-provider via HTTP (30 s stall).
    // The URLs point at a TEST-NET-1 black hole, so if provider fetching ever
    // sneaks back into validation this test hangs/fails instead of passing.
    const PROVIDER_CFG: &str = "\
mode: rule
proxies:
  - name: \"node1\"
    type: ss
    server: 192.0.2.1
    port: 8388
    cipher: aes-128-gcm
    password: x
proxy-providers:
  airport:
    type: http
    url: \"https://192.0.2.1/sub.yaml\"
    path: ./airport.yaml
    interval: 0
rule-providers:
  ads:
    type: http
    behavior: domain
    url: \"https://192.0.2.1/ads.yaml\"
    path: ./ads.yaml
    interval: 0
proxy-groups:
  - name: PROXY
    type: select
    use:
      - airport
  - name: AUTO
    type: url-test
    include-all: true
rules:
  - RULE-SET,ads,REJECT
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,github.com,AUTO
  - MATCH,node1
";

    #[test]
    fn validates_provider_config_offline() {
        let _g = TEST_LOCK.lock();
        let start = std::time::Instant::now();
        let rc = validate(PROVIDER_CFG);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "provider config failed validation: {err}");
        assert!(
            start.elapsed() < std::time::Duration::from_secs(10),
            "validation took {:?} — provider fetch is back on the validate path",
            start.elapsed()
        );
    }

    #[test]
    fn provider_config_still_rejects_undefined_rule_target() {
        let _g = TEST_LOCK.lock();
        let yaml = PROVIDER_CFG.replace("MATCH,node1", "MATCH,NOSUCH");
        assert_eq!(validate(&yaml), -1);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert!(err.contains("NOSUCH"), "error was: {err}");
    }

    // A `use:` reference to a provider that is not defined anywhere is a
    // genuinely broken config — stripping must not paper over it.
    #[test]
    fn rejects_group_using_undefined_provider() {
        let _g = TEST_LOCK.lock();
        let yaml = "\
mode: rule
proxies: []
proxy-groups:
  - name: PROXY
    type: select
    use:
      - nonexistent
rules:
  - MATCH,PROXY
";
        assert_eq!(validate(yaml), -1);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert!(err.contains("PROXY"), "error was: {err}");
    }

    // Merge keys (`<<: *anchor`) must survive the provider strip — airport
    // configs commonly share group fields through anchors.
    #[test]
    fn validates_provider_config_with_merge_keys() {
        let _g = TEST_LOCK.lock();
        let yaml = "\
mode: rule
group-common: &common
  type: select
  use:
    - airport
proxies: []
proxy-providers:
  airport:
    type: http
    url: \"https://192.0.2.1/sub.yaml\"
    path: ./airport.yaml
    interval: 0
proxy-groups:
  - <<: *common
    name: PROXY
rules:
  - MATCH,PROXY
";
        let rc = validate(yaml);
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "anchor-based provider config failed: {err}");
    }

    #[test]
    fn version_is_non_empty() {
        let v = unsafe { CStr::from_ptr(bridge_version()) }
            .to_str()
            .unwrap();
        assert!(!v.is_empty());
        assert!(v.contains("meow-rs"), "version was: {v}");
        assert!(
            v.contains("0.21.2"),
            "expected pinned meow-rs workspace version 0.21.2, got: {v}"
        );
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
    const GEOIP_CFG: &str = "mixed-port: 0\nmode: rule\nlog-level: info\nallow-lan: false\nexternal-controller: 127.0.0.1:0\n\ngeo-auto-update: false\n\ndns:\n  enable: true\n  listen: 127.0.0.1:0\n  enhanced-mode: fake-ip\n  nameserver:\n    - 114.114.114.114\n    - 223.5.5.5\n\nproxies:\n  - name: \"TestNode\"\n    type: vless\n    server: \"1.2.3.4\"\n    port: 443\n    uuid: \"00000000-0000-0000-0000-000000000000\"\n    udp: true\n    tls: true\n    servername: \"example.com\"\n    network: ws\n    ws-opts:\n      path: \"/ws\"\n      headers:\n        Host: \"example.com\"\n\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n      - \"TestNode\"\n\nrules:\n  - DOMAIN-SUFFIX,google.com,PROXY\n  - GEOIP,CN,DIRECT\n  - MATCH,PROXY\n";

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

    /// Write a config with Clash-style allow-lan + mixed-port for LAN tests.
    fn write_lan_config(dir: &std::path::Path, mixed_port: i32) {
        let yaml = format!(
            "mixed-port: {mixed_port}\n\
             allow-lan: true\n\
             bind-address: 0.0.0.0\n\
             mode: rule\n\
             dns:\n\
               enable: true\n\
               listen: 127.0.0.1:1053\n\
               enhanced-mode: fake-ip\n\
               fake-ip-range: 28.0.0.0/8\n\
               nameserver:\n\
                 - 127.0.0.1:5353\n\
             proxies: []\n\
             proxy-groups: []\n\
             rules:\n\
               - MATCH,DIRECT\n"
        );
        std::fs::write(dir.join("config.yaml"), yaml).unwrap();
    }

    fn wait_accept(addr: &str) -> bool {
        for _ in 0..20 {
            if std::net::TcpStream::connect(addr).is_ok() {
                return true;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        false
    }

    #[test]
    fn lan_listeners_start_and_serve() {
        let _g = TEST_LOCK.lock();

        let dir = std::env::temp_dir().join(format!("meow-ffi-lan-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socks = free_port();
        let dns = free_port();
        let ctrl = free_port();
        let lan_proxy = free_port();
        write_lan_config(&dir, lan_proxy);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };

        let ctrl_c = CString::new(format!("127.0.0.1:{ctrl}")).unwrap();
        let secret_c = CString::new("").unwrap();

        let rc = unsafe { bridge_start_with_ports(socks, dns, ctrl_c.as_ptr(), secret_c.as_ptr()) };
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "LAN start failed: {err}");

        // Internal SOCKS stays loopback; LAN mixed is on the YAML mixed-port.
        assert!(
            wait_accept(&format!("127.0.0.1:{socks}")),
            "loopback mixed not accepting on {socks}"
        );
        assert!(
            wait_accept(&format!("127.0.0.1:{lan_proxy}")),
            "LAN mixed listener not accepting on {lan_proxy}"
        );

        bridge_stop_proxy();
        assert!(!bridge_is_running());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn lan_start_fails_on_occupied_port() {
        let _g = TEST_LOCK.lock();

        let dir = std::env::temp_dir().join(format!("meow-ffi-lanbusy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        // Occupy a port on 0.0.0.0 so the LAN preflight bind must fail.
        let blocker = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
        let busy = blocker.local_addr().unwrap().port() as i32;
        write_lan_config(&dir, busy);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };

        let ctrl_c = CString::new(format!("127.0.0.1:{}", free_port())).unwrap();
        let secret_c = CString::new("").unwrap();
        let rc = unsafe {
            bridge_start_with_ports(free_port(), free_port(), ctrl_c.as_ptr(), secret_c.as_ptr())
        };
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, -1, "start must fail when the LAN port is occupied");
        assert!(err.contains("LAN proxy port"), "error was: {err}");
        assert!(!bridge_is_running());

        drop(blocker);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Local-proxy mode shape: allow-lan + mixed-port == socks_port merges into
    // a single 0.0.0.0 listener serving loopback and LAN clients alike.
    #[test]
    fn lan_same_port_merges_into_single_listener() {
        let _g = TEST_LOCK.lock();

        let dir = std::env::temp_dir().join(format!("meow-ffi-lanmerge-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socks = free_port();
        let dns = free_port();
        let ctrl = free_port();
        write_lan_config(&dir, socks);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };

        let ctrl_c = CString::new(format!("127.0.0.1:{ctrl}")).unwrap();
        let secret_c = CString::new("").unwrap();

        let rc = unsafe { bridge_start_with_ports(socks, dns, ctrl_c.as_ptr(), secret_c.as_ptr()) };
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "merged LAN start failed: {err}");

        assert!(
            wait_accept(&format!("127.0.0.1:{socks}")),
            "merged listener not accepting on {socks}"
        );

        bridge_stop_proxy();
        assert!(!bridge_is_running());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The engine must install the global host-resolver hook while running,
    /// so a proxy node's `server:` hostname is resolved by the config's `dns:`
    /// section instead of libc `getaddrinfo`, and must drop it on stop.
    #[test]
    fn host_resolver_hook_installed_while_running() {
        let _g = TEST_LOCK.lock();

        let dir = std::env::temp_dir().join(format!("meow-ffi-hook-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.yaml"), MINIMAL_CONFIG).unwrap();
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };

        meow_common::clear_host_resolver();
        assert!(
            meow_common::host_resolver().is_none(),
            "hook set before start"
        );

        let ctrl_c = CString::new(format!("127.0.0.1:{}", free_port())).unwrap();
        let secret_c = CString::new("").unwrap();
        let rc = unsafe {
            bridge_start_with_ports(free_port(), free_port(), ctrl_c.as_ptr(), secret_c.as_ptr())
        };
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "start failed: {err}");
        assert!(
            meow_common::host_resolver().is_some(),
            "engine started without installing the host-resolver hook: proxy \
             server hostnames would fall back to libc getaddrinfo"
        );

        bridge_stop_proxy();
        assert!(
            meow_common::host_resolver().is_none(),
            "host-resolver hook outlived the engine that installed it"
        );
        let _ = std::fs::remove_dir_all(&dir);
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

    fn start_engine(dir: &std::path::Path) -> (i32, i32) {
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        unsafe { bridge_set_home_dir(dir_c.as_ptr()) };
        let socks = free_port();
        let dns = free_port();
        let ctrl_c = CString::new(format!("127.0.0.1:{}", free_port())).unwrap();
        let secret_c = CString::new("").unwrap();
        let rc = unsafe { bridge_start_with_ports(socks, dns, ctrl_c.as_ptr(), secret_c.as_ptr()) };
        let err = unsafe { CStr::from_ptr(bridge_get_last_error()) }
            .to_str()
            .unwrap()
            .to_string();
        assert_eq!(rc, 0, "start failed: {err}");
        assert!(
            wait_accept(&format!("127.0.0.1:{socks}")),
            "mixed listener not up"
        );
        (socks, dns)
    }

    /// Loopback TCP echo server on an ephemeral port; runs until the test
    /// process exits (a stuck accept is harmless there).
    fn spawn_echo_server() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                std::thread::spawn(move || {
                    let mut stream = stream;
                    let mut buf = [0u8; 1024];
                    while let Ok(n) = stream.read(&mut buf) {
                        if n == 0 || stream.write_all(&buf[..n]).is_err() {
                            break;
                        }
                    }
                });
            }
        });
        port
    }

    /// Minimal loopback HTTP server answering every request with 204 and
    /// counting them — a stand-in for the url-test probe target.
    fn spawn_http_204_server() -> (u16, Arc<AtomicUsize>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&hits);
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let counter = Arc::clone(&counter);
                std::thread::spawn(move || {
                    let mut stream = stream;
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                    let mut buf = [0u8; 2048];
                    let mut got = Vec::new();
                    // Read until the end of the request head.
                    while let Ok(n) = stream.read(&mut buf) {
                        if n == 0 {
                            return;
                        }
                        got.extend_from_slice(&buf[..n]);
                        if got.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    counter.fetch_add(1, Ordering::SeqCst);
                    let _ = stream.write_all(
                        b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    );
                });
            }
        });
        (port, hits)
    }

    /// SOCKS5 CONNECT to 127.0.0.1:`dst_port` through the engine's mixed
    /// listener; returns the client side of the established session.
    fn socks5_connect(socks_port: i32, dst_port: u16) -> std::net::TcpStream {
        let mut s = std::net::TcpStream::connect(format!("127.0.0.1:{socks_port}")).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(&[0x05, 0x01, 0x00]).unwrap();
        let mut reply = [0u8; 2];
        s.read_exact(&mut reply).unwrap();
        assert_eq!(reply, [0x05, 0x00], "SOCKS5 method negotiation");
        let mut req = vec![0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1];
        req.extend_from_slice(&dst_port.to_be_bytes());
        s.write_all(&req).unwrap();
        let mut head = [0u8; 4];
        s.read_exact(&mut head).unwrap();
        assert_eq!(head[1], 0x00, "SOCKS5 CONNECT rejected: {:?}", head);
        let bnd_len = match head[3] {
            0x01 => 4 + 2,
            0x04 => 16 + 2,
            other => panic!("unexpected BND ATYP {other:#x}"),
        };
        let mut bnd = vec![0u8; bnd_len];
        s.read_exact(&mut bnd).unwrap();
        s
    }

    fn wait_for_hits(hits: &AtomicUsize, at_least: usize, within: Duration) -> bool {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if hits.load(Ordering::SeqCst) >= at_least {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }

    // Regression (issue #113, finding 2): the mixed listener detaches every
    // accepted connection with a bare `tokio::spawn`, so aborting only the
    // listener task left established sessions relaying through the stopped
    // engine (the app reported "disconnected" while traffic kept flowing).
    // Stop must close them.
    #[test]
    fn stop_closes_established_socks5_sessions() {
        let _g = TEST_LOCK.lock();
        let dir = std::env::temp_dir().join(format!("meow-ffi-stopconn-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("config.yaml"), MINIMAL_CONFIG).unwrap();
        let echo_port = spawn_echo_server();
        let (socks, _dns) = start_engine(&dir);

        let mut session = socks5_connect(socks, echo_port);
        session.write_all(b"ping").unwrap();
        let mut buf = [0u8; 4];
        session.read_exact(&mut buf).unwrap();
        assert_eq!(&buf, b"ping", "echo through the engine before stop");

        bridge_stop_proxy();
        assert!(!bridge_is_running());

        // The relay task must be gone: the client's next read sees EOF (or a
        // reset), never a timeout with the session still alive. Write first so
        // a still-running relay would have something to echo back. (The 5 s
        // read timeout from `socks5_connect` is still in force.)
        let _ = session.write_all(b"after-stop");
        let mut out = [0u8; 16];
        match session.read(&mut out) {
            Ok(0) | Err(_) => {}
            Ok(n) => panic!(
                "session still relaying after stop: got {:?}",
                String::from_utf8_lossy(&out[..n])
            ),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// url-test group with a 1 s non-lazy probe against a local target.
    /// Real newlines (no `\` continuation) so the YAML indentation survives.
    const HEALTH_CHECK_CONFIG: &str = "mode: rule
dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 28.0.0.0/8
  nameserver:
    - 127.0.0.1:5353
proxies: []
proxy-groups:
  - name: AUTO
    type: url-test
    url: http://127.0.0.1:PROBE_PORT/generate_204
    interval: 1
    lazy: false
    proxies:
      - DIRECT
rules:
  - MATCH,AUTO
";

    fn write_health_check_config(dir: &std::path::Path, probe_port: u16) {
        let yaml = HEALTH_CHECK_CONFIG.replace("PROBE_PORT", &probe_port.to_string());
        std::fs::write(dir.join("config.yaml"), yaml).unwrap();
    }

    // Regression (issue #113, finding 2): url-test / fallback health-check
    // loops are spawned before the engine's task handles existed and own a
    // cloned tunnel, so they outlived stop and accumulated across restarts
    // (N generations → N probe loops, each pinning its dead tunnel). Every
    // stop must silence the probes; a restart must not bring the old ones back.
    #[test]
    fn stop_halts_health_check_probes_and_restart_does_not_accumulate() {
        let _g = TEST_LOCK.lock();
        let dir = std::env::temp_dir().join(format!("meow-ffi-hc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (probe_port, hits) = spawn_http_204_server();
        write_health_check_config(&dir, probe_port);

        const QUIET: Duration = Duration::from_millis(2500);
        for generation in 0..3 {
            let before = hits.load(Ordering::SeqCst);
            start_engine(&dir);
            // A non-lazy 1 s url-test group probes right away and keeps going.
            assert!(
                wait_for_hits(&hits, before + 2, Duration::from_secs(10)),
                "generation {generation}: health checks never probed the local target"
            );
            bridge_stop_proxy();
            assert!(!bridge_is_running());

            // A live loop would hit the target at least twice more in QUIET.
            let at_stop = hits.load(Ordering::SeqCst);
            std::thread::sleep(QUIET);
            let after = hits.load(Ordering::SeqCst);
            assert_eq!(
                after, at_stop,
                "generation {generation}: {} probe(s) fired after stop — a health-check loop outlived the engine",
                after - at_stop
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
