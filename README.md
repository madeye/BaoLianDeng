# BaoLianDeng

macOS VPN proxy app powered by [meow-rs](https://github.com/madeye/meow-rs), a Clash/mihomo-compatible proxy kernel written in Rust.

**[App Store](https://apps.apple.com/app/baoliandeng/id6779101876)** · **[TestFlight Beta](https://testflight.apple.com/join/VpX3tHnS)** · **[Website](https://madeye.github.io/BaoLianDeng/)**

## Features

- **Transparent Proxy** — Built on `NETransparentProxyProvider` for socket-level flow interception, faster than traditional TUN-based solutions
- **meow-rs Engine** — Clash/mihomo-compatible proxy kernel written in Rust ([madeye/meow-rs](https://github.com/madeye/meow-rs)), compiled as a native xcframework
- **Per-App Proxy** — Choose which apps go through the proxy (allowlist) or bypass it (blocklist)
- **Subscription Management** — Add, refresh, and switch between proxy subscriptions (Clash YAML and base64 formats)
- **Smart Proxy Routing** — Browse nodes with latency indicators, switch proxy groups, rule/global/direct modes
- **Traffic Analytics** — Daily bar charts, session stats, and monthly summaries for proxy traffic

> **Known differences from upstream mihomo:** `meow-rs` is built without `boring-tls`, so there's no Reality/uTLS fingerprinting and no `ech-tls-tunnel` outbound. It also doesn't yet support TUIC, WireGuard, SSH, or ShadowsocksR outbounds. Supported outbounds: ss, trojan, vless (+ vision), vmess, snell, hysteria2.

## Architecture

```
┌─────────────────────────────────────────────┐
│             macOS App (SwiftUI)             │
│  ┌──────────┬────────┬───────┬───────────┐  │
│  │  Home    │ Config │ Data  │ Settings  │  │
│  │ Subs &   │ YAML   │Charts │ Groups /  │  │
│  │  Nodes   │ Editor │& Stats│ Logs      │  │
│  └──────────┴────────┴───────┴───────────┘  │
│  ┌───────────────────────────────────────┐  │
│  │  VPNManager (NETunnelProviderManager) │  │
│  └──────────────────┬────────────────────┘  │
├─────────────────────┼───────────────────────┤
│    System Extension (TransparentProxy)      │
│  ┌──────────────────┴────────────────────┐  │
│  │  NETransparentProxyProvider           │  │
│  │    ┌──────────────────────────────┐   │  │
│  │    │MihomoCore.xcframework (Rust) │   │  │
│  │    │  - Proxy Engine              │   │  │
│  │    │  - DNS (redir-host)          │   │  │
│  │    │  - Rules / Routing           │   │  │
│  │    └──────────────────────────────┘   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**IPC** between the app and tunnel extension uses `NETunnelProviderSession.sendMessage` for mode switching, traffic stats, and version queries. Both targets share preferences via standard `UserDefaults`.

## Install

### From the App Store

1. Download from the [Mac App Store](https://apps.apple.com/app/baoliandeng/id6779101876)
2. Launch **BaoLianDeng** from Applications
3. Enable the network extension: **System Settings → General → Login Items & Extensions → Network Extensions** → toggle on **BaoLianDeng**

### Build from Source

**Prerequisites:** macOS 14.0+ with Xcode 15+, Rust stable via [rustup](https://rustup.rs) with the `aarch64-apple-darwin` and `x86_64-apple-darwin` targets installed

#### 1. Build the Rust framework

```bash
make framework    # macOS universal (arm64 + x86_64)
```

This builds the Rust FFI bridge under `Rust/meow-ffi/` (a staticlib around the [meow-rs](https://github.com/madeye/meow-rs) engine) into `Framework/MihomoCore.xcframework`.

#### 2. Configure signing

Copy the template and set your Apple development team ID:

```bash
cp Local.xcconfig.template Local.xcconfig
# Edit Local.xcconfig and set DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

> **Finding your Team ID:** Apple Developer portal → Membership → Team ID (10-character string, e.g. `AB12CD34EF`).

Both targets require these capabilities (already configured in entitlements):
- **App Sandbox**
- **Network Extensions** — Packet Tunnel Provider

#### 3. Build and run

```bash
open BaoLianDeng.xcodeproj
# Select BaoLianDeng scheme → My Mac → Run (⌘R)
```

## License

MIT — see [LICENSE](LICENSE) for details.
