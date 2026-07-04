//! Engine assembly + lifecycle state, modeled on `meow_app::run()`.
//!
//! meow-rs exposes no stop/lifecycle API (its `run()` spawns bare
//! `tokio::spawn` tasks and blocks on a signal), so this module hand-rolls the
//! wiring and keeps every `JoinHandle` for abort-on-stop. The caller-supplied
//! SOCKS/DNS/controller endpoints are forced onto the parsed config before any
//! listener starts, ignoring whatever ports the YAML declared.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use dashmap::DashMap;
use meow_api::log_stream::LogMessage;
use meow_api::ApiServer;
use meow_config::proxy_provider::ProxyProvider;
use meow_config::rule_provider::RuleProvider;
use meow_config::{load_config, ListenerType, NamedListener};
use meow_dns::DnsServer;
use meow_listener::{MixedListener, SnifferRuntime};
use meow_tunnel::Tunnel;
use parking_lot::RwLock;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tracing::{error, info};

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
pub async fn assemble(
    config_path: String,
    home: String,
    socks_port: i32,
    dns_port: i32,
    controller_addr: String,
    secret: String,
) -> anyhow::Result<EngineState> {
    let mut config = load_config_pinned(&config_path, &home).await?;

    // Force inbound / DNS / controller endpoints regardless of the YAML.
    let socks_addr: SocketAddr = format!("127.0.0.1:{socks_port}").parse()?;
    let dns_addr: SocketAddr = format!("127.0.0.1:{dns_port}").parse()?;
    let api_addr: SocketAddr = controller_addr
        .parse()
        .map_err(|e| anyhow::anyhow!("controller_addr '{controller_addr}': {e}"))?;

    config.listeners.named = vec![NamedListener {
        name: "mixed".to_string(),
        listener_type: ListenerType::Mixed,
        port: socks_addr.port(),
        listen: "127.0.0.1".to_string(),
        tproxy_sni: false,
        max_connections: 0,
    }];
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

    // DNS UDP server (redir-host reverse cache lives inside the resolver).
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

    // Mixed (SOCKS5 + HTTP) listener(s) — exactly one, forced above.
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

    info!("meow engine started: socks={socks_port} dns={dns_port} controller={controller_addr}");

    Ok(EngineState {
        tunnel,
        handles,
        socks_port,
        dns_port,
        controller_addr,
    })
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
