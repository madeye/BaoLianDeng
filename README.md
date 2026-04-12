# BaoLianDeng

macOS VPN proxy app powered by [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) core.

**[Download DMG](https://github.com/madeye/BaoLianDeng/releases/latest)** · **[Website](https://madeye.github.io/BaoLianDeng/)**

## Features

- **Transparent Proxy** — Built on `NETransparentProxyProvider` for socket-level flow interception, faster than traditional TUN-based solutions
- **Upstream Mihomo Engine** — Original Go [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) compiled as a native xcframework via cgo
- **Per-App Proxy** — Choose which apps go through the proxy (allowlist) or bypass it (blocklist)
- **Subscription Management** — Add, refresh, and switch between proxy subscriptions (Clash YAML and base64 formats)
- **Smart Proxy Routing** — Browse nodes with latency indicators, switch proxy groups, rule/global/direct modes
- **Traffic Analytics** — Daily bar charts, session stats, and monthly summaries for proxy traffic

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
│  │    │ MihomoCore.xcframework (Go)  │   │  │
│  │    │  - Proxy Engine              │   │  │
│  │    │  - DNS (fake-ip)             │   │  │
│  │    │  - Rules / Routing           │   │  │
│  │    └──────────────────────────────┘   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**IPC** between the app and tunnel extension uses `NETunnelProviderSession.sendMessage` for mode switching, traffic stats, and version queries. Both targets share preferences via standard `UserDefaults`.

## Install

### Homebrew

```bash
brew tap madeye/BaoLianDeng https://github.com/madeye/BaoLianDeng
brew install --cask baoliandeng
```

### From DMG

1. Download the latest DMG from [Releases](https://github.com/madeye/BaoLianDeng/releases/latest)
2. Open the DMG and drag **BaoLianDeng** to **Applications**
3. Launch from Applications
4. Enable the network extension: **System Settings → General → Login Items & Extensions → Network Extensions** → toggle on **BaoLianDeng**

The DMG is signed with Developer ID and notarized by Apple.

### Build from Source

**Prerequisites:** macOS 14.0+ with Xcode 15+, Go 1.23+ (`brew install go`)

#### 1. Build the Go framework

```bash
make framework    # macOS universal (arm64 + x86_64)
```

This builds the Go cgo bridge under `Go/mihomo-bridge/` into `Framework/MihomoCore.xcframework`.

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

GPL-3.0 — see [LICENSE](LICENSE) for details.
