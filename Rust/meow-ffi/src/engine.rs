//! Engine assembly + lifecycle state, modeled on `meow_app::run()`.
//!
//! meow-rs exposes no stop/lifecycle API (its `run()` spawns bare
//! `tokio::spawn` tasks and blocks on a signal), so this module hand-rolls the
//! wiring and keeps every `JoinHandle` for abort-on-stop. The caller-supplied
//! SOCKS/DNS/controller endpoints are forced onto the parsed config before any
//! listener starts, ignoring whatever ports the YAML declared — except
//! Clash-compatible `allow-lan` / `bind-address` / `mixed-port`, which control
//! whether a LAN-facing mixed listener is also exposed.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use dashmap::DashMap;
use meow_api::log_stream::LogMessage;
use meow_api::ApiServer;
use meow_config::proxy_provider::ProxyProvider;
use meow_config::rule_provider::RuleProvider;
use meow_config::{load_config, ListenerSpec, NamedListener};
use meow_dns::DnsServer;
use meow_listener::{MixedListener, SnifferRuntime};
use meow_tunnel::Tunnel;
use parking_lot::RwLock;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{error, info, warn};

/// Live engine instance. Dropping it (via [`crate` stop]) releases the tunnel
/// and its statistics; the tokio runtime itself is process-global and reused.
pub struct EngineState {
    pub tunnel: Tunnel,
    pub handles: Vec<JoinHandle<()>>,
    pub socks_port: i32,
    pub dns_port: i32,
    pub controller_addr: String,
}

/// Load `<config_path>`, force the runtime endpoints, and start the tunnel,
/// DNS server, REST API, and mixed (SOCKS5+HTTP) listener on the shared
/// runtime. Returns the assembled [`EngineState`] with all task handles.
///
/// SOCKS / DNS / controller ports always bind loopback at the caller-supplied
/// addresses (transparent-proxy and REST clients need stable, private
/// endpoints). LAN exposure is Clash-compatible and driven entirely by the
/// YAML:
///
/// - `allow-lan: true` → additionally expose a mixed listener on
///   `bind-address`:`mixed-port` (defaults: `0.0.0.0` and `socks_port`).
/// - When that LAN port equals `socks_port`, the two merge into a single
///   `0.0.0.0` listener (local-proxy mode: one port serves loopback + LAN).
/// - DNS and the external controller stay loopback regardless of `allow-lan`.
///
/// The LAN port is bind-checked up-front so an occupied port fails engine
/// start with a clear error instead of a warning buried in the log.
pub async fn assemble(
    config_path: String,
    home: String,
    socks_port: i32,
    dns_port: i32,
    controller_addr: String,
    secret: String,
) -> anyhow::Result<EngineState> {
    clear_saved_global_selection(&home).await?;
    let mut config = load_config_pinned(&config_path, &home).await?;

    // Force inbound / DNS / controller endpoints regardless of the YAML.
    let socks_addr: SocketAddr = format!("127.0.0.1:{socks_port}").parse()?;
    let dns_addr: SocketAddr = format!("127.0.0.1:{dns_port}").parse()?;
    let parsed_api_addr: SocketAddr = controller_addr
        .parse()
        .map_err(|e| anyhow::anyhow!("controller_addr '{controller_addr}': {e}"))?;
    // Defense-in-depth: a compromised/buggy caller must never be able to bind
    // the (possibly unauthenticated) controller API to a non-loopback address
    // and expose it to the LAN. Force the IP to loopback while preserving the
    // caller-supplied port.
    let api_addr = if parsed_api_addr.ip().is_loopback() {
        parsed_api_addr
    } else {
        warn!("controller_addr '{parsed_api_addr}' is not loopback; overriding IP to 127.0.0.1");
        SocketAddr::new(
            IpAddr::V4(std::net::Ipv4Addr::LOCALHOST),
            parsed_api_addr.port(),
        )
    };

    // Clash-compatible allow-lan: read before we overwrite listeners.
    // meow defaults bind-address to 127.0.0.1 even when allow-lan is true;
    // treat that (and Clash's `*`) as "all interfaces".
    let allow_lan = config.general.allow_lan;
    let lan_bind = lan_bind_address(allow_lan, &config.general.bind_address);
    let yaml_mixed = config.listeners.mixed_port.filter(|&p| p > 0);
    let lan_proxy_port: u16 = if allow_lan {
        yaml_mixed.unwrap_or(socks_addr.port())
    } else {
        0
    };
    let lan_merged = allow_lan && lan_proxy_port == socks_addr.port();

    config.listeners.named = vec![NamedListener {
        name: "mixed".to_string(),
        spec: ListenerSpec::Mixed,
        port: socks_addr.port(),
        listen: if lan_merged {
            lan_bind.clone()
        } else {
            "127.0.0.1".to_string()
        },
        max_connections: 0,
    }];
    if allow_lan {
        validate_lan_bind(&lan_bind, lan_proxy_port)?;
        if !lan_merged {
            config.listeners.named.push(NamedListener {
                name: "mixed-lan".to_string(),
                spec: ListenerSpec::Mixed,
                port: lan_proxy_port,
                listen: lan_bind.clone(),
                max_connections: 0,
            });
        }
    }
    config.listeners.mixed_port = Some(socks_addr.port());
    config.listeners.socks_port = None;
    config.listeners.http_port = None;
    config.listeners.tproxy_port = None;
    config.dns.listen_addr = Some(dns_addr);
    config.api.external_controller = Some(api_addr);
    config.api.secret = if secret.is_empty() {
        None
    } else {
        Some(secret)
    };

    // Shared state, mirroring meow_app::run().
    let raw_config = Arc::new(RwLock::new(config.raw.clone()));
    let health_specs =
        meow_app::health_check::extract_specs(config.raw.proxy_groups.as_deref().unwrap_or(&[]));

    let proxy_providers: Arc<DashMap<String, Arc<ProxyProvider>>> = {
        let map = DashMap::new();
        for (name, provider) in config.proxy_providers {
            map.insert(name, provider);
        }
        Arc::new(map)
    };
    let rule_providers: Arc<RwLock<HashMap<String, Arc<RuleProvider>>>> =
        Arc::new(RwLock::new(config.rule_providers));

    let named_for_api = config.listeners.named.clone();
    let secret_for_api = config.api.secret.clone();
    let external_ui = config.api.external_ui.clone();
    let resolver = Arc::clone(&config.dns.resolver);

    // Install the configured resolver as the global host-resolver hook that
    // `meow_common::connect_tcp_host` consults, so a proxy node's own
    // `server:` hostname resolves through the `dns:` section rather than
    // libc `getaddrinfo`. `meow_app::run()` does this for the `meow` binary;
    // this crate assembles the engine itself, so it has to install the hook
    // itself too. `dns.proxy-server-nameserver`, when set, takes over
    // exclusively for these lookups (mihomo `ProxyServerHostResolver`).
    //
    // Gated on `dns.enable` exactly as `meow_app::run()` gates it: with DNS
    // off, `config.dns.resolver` is a stub pointing at a hard-coded upstream
    // and forcing every proxy dial through it would be worse than the OS
    // resolver. The app's `sanitizeConfig()` forces `enable: true`, so the
    // hook is installed in practice; the else-branch keeps a start with DNS
    // somehow disabled from inheriting a previous run's hook.
    if config.dns.enabled {
        meow_common::set_host_resolver(Arc::new(
            meow_dns::ResolverHostHook::new_with_proxy_resolver(
                Arc::clone(&config.dns.resolver),
                config.dns.proxy_resolver.clone(),
            ),
        ));
    } else {
        meow_common::clear_host_resolver();
    }

    // Core routing engine.
    let tunnel = Tunnel::new(Arc::clone(&config.dns.resolver));
    tunnel.set_mode(config.general.mode);
    tunnel.update_rules(config.rules);
    tunnel.update_proxies(config.proxies);
    tunnel.spawn_background_tasks();
    if !health_specs.is_empty() {
        info!("Starting health checks for {} group(s)", health_specs.len());
        meow_app::health_check::spawn_health_checks(&tunnel, health_specs);
    }

    let sniffer = Arc::new(SnifferRuntime::new(config.sniffer));
    let auth = config.auth;

    let mut handles: Vec<JoinHandle<()>> = Vec::new();

    // DNS UDP server (fake-ip pool and reverse mapping live inside the resolver).
    {
        let dns_server = DnsServer::new(resolver, dns_addr);
        handles.push(tokio::spawn(async move {
            if let Err(e) = dns_server.run().await {
                error!("DNS server error: {e}");
            }
        }));
    }

    // REST API server. The /logs broadcast channel is created but not fed by a
    // tracing layer (Swift reads logs from the file sink, not the WS).
    {
        let (log_tx, _log_rx) = broadcast::channel::<LogMessage>(16);
        let api_server = ApiServer::new(
            tunnel.clone(),
            api_addr,
            secret_for_api,
            config_path.clone(),
            Arc::clone(&raw_config),
            log_tx,
            Arc::clone(&proxy_providers),
            Arc::clone(&rule_providers),
            named_for_api,
            external_ui,
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = api_server.run().await {
                error!("API server error: {e}");
            }
        }));
    }

    // Mixed (SOCKS5 + HTTP) listener(s) — primary (+ optional LAN) forced above.
    for nl in &config.listeners.named {
        let ip: IpAddr = nl
            .listen
            .parse()
            .map_err(|e| anyhow::anyhow!("listener '{}' bind '{}': {e}", nl.name, nl.listen))?;
        let addr = SocketAddr::new(ip, nl.port);
        let listener = MixedListener::new(tunnel.clone(), addr, nl.name.clone())
            .with_sniffer(Arc::clone(&sniffer))
            .with_auth(Arc::clone(&auth))
            .with_max_connections(nl.max_connections);
        handles.push(tokio::spawn(async move {
            if let Err(e) = listener.run().await {
                error!("Listener error: {e}");
            }
        }));
    }

    info!(
        "meow engine started: socks={socks_port} dns={dns_port} controller={controller_addr} \
         allow_lan={allow_lan} lan_proxy={lan_proxy_port}"
    );

    Ok(EngineState {
        tunnel,
        handles,
        socks_port,
        dns_port,
        controller_addr,
    })
}

/// Resolve the LAN bind address from Clash-style `allow-lan` / `bind-address`.
///
/// meow defaults `bind-address` to `127.0.0.1` even when `allow-lan` is true;
/// Clash treats missing/`*` as all interfaces. Map those to `0.0.0.0`.
fn lan_bind_address(allow_lan: bool, bind_address: &str) -> String {
    if !allow_lan {
        return "127.0.0.1".to_string();
    }
    match bind_address.trim() {
        "" | "*" | "127.0.0.1" | "::1" => "0.0.0.0".to_string(),
        other => other.to_string(),
    }
}

/// Validate the LAN proxy port and bind-check it up-front.
///
/// The listener itself binds later inside a spawned task where a failure
/// only reaches the log, so an occupied port is caught here with a test
/// bind (bound then immediately dropped — the small TOCTOU window mirrors
/// the app-side `EphemeralPort` picker and is acceptable).
fn validate_lan_bind(bind: &str, lan_proxy_port: u16) -> anyhow::Result<()> {
    if lan_proxy_port == 0 {
        anyhow::bail!("allow-lan requires a non-zero mixed-port");
    }
    let ip: IpAddr = bind
        .parse()
        .map_err(|e| anyhow::anyhow!("allow-lan bind-address '{bind}': {e}"))?;
    std::net::TcpListener::bind(SocketAddr::new(ip, lan_proxy_port))
        .map_err(|e| anyhow::anyhow!("LAN proxy port {lan_proxy_port} unavailable: {e}"))?;
    Ok(())
}

/// Load a config with geodata paths pinned to the bridge home dir.
///
/// meow's geodata discovery goes through a first-write-wins home-dir OnceLock;
/// to guarantee GEOIP/GEOSITE rules find `<home>/Country.mmdb` and
/// `<home>/geosite.dat` (and never `$HOME/.config/meow`), we inject explicit
/// `geodata.*-path` overrides into the config before parsing. When the config
/// already pins those paths the original file is loaded directly. The pinned
/// copy is written into the home dir so `load_config`'s `cache_dir` (used for
/// rule/proxy-provider resolution) still resolves to the home dir.
async fn load_config_pinned(config_path: &str, home: &str) -> anyhow::Result<meow_config::Config> {
    let original = tokio::fs::read_to_string(config_path).await?;
    let pinned = crate::geodata::pin_geodata_paths(&original, home);
    if pinned == original {
        return load_config(config_path).await;
    }
    let tmp = format!("{home}/.meow-ffi-active.yaml");
    tokio::fs::write(&tmp, &pinned).await?;
    let loaded = load_config(&tmp).await;
    let _ = tokio::fs::remove_file(&tmp).await;
    loaded
}

/// Older app builds PUT their guessed GLOBAL target into the engine cache.
/// Clear only that entry before loading; real per-group choices stay intact.
/// GLOBAL now follows the config's explicit definition or the engine default.
async fn clear_saved_global_selection(home: &str) -> anyhow::Result<()> {
    let path = std::path::Path::new(home).join("selector-cache.json");
    let bytes = match tokio::fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    // meow-rs itself treats malformed stores as empty.
    let Ok(mut selections) = serde_json::from_slice::<HashMap<String, String>>(&bytes) else {
        return Ok(());
    };
    if selections.remove("GLOBAL").is_some() {
        let tmp = path.with_extension("json.tmp");
        tokio::fs::write(&tmp, serde_json::to_vec(&selections)?).await?;
        tokio::fs::rename(&tmp, &path).await?;
    }
    Ok(())
}
