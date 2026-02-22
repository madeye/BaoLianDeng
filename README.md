# BaoLianDeng

iOS global proxy app powered by [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) core.

## Architecture

```
┌─────────────────────────────────────────────┐
│                iOS App (Swift)              │
│  ┌─────────────┐  ┌─────────────────────┐  │
│  │  SwiftUI    │  │  VPNManager         │  │
│  │  MainView   │──│  (NETunnelProvider  │  │
│  │  ConfigEdit │  │   Manager)          │  │
│  └─────────────┘  └────────┬────────────┘  │
├────────────────────────────┼────────────────┤
│         Network Extension (PacketTunnel)    │
│  ┌─────────────────────────┴──────────────┐ │
│  │    NEPacketTunnelProvider              │ │
│  │    ┌───────────────────────────────┐   │ │
│  │    │  MihomoCore.xcframework (Go)  │   │ │
│  │    │  - Proxy Engine               │   │ │
│  │    │  - DNS (fake-ip)              │   │ │
│  │    │  - Rules / Routing            │   │ │
│  │    └───────────────────────────────┘   │ │
│  └────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Prerequisites

- macOS with Xcode 15+
- Go 1.25+
- `gomobile` and `gobind` are installed automatically by the build system — no manual setup needed

## Build

### 1. Build the Go framework

```bash
make framework            # Build for iOS + Simulator (universal)
make framework-arm64      # Build for arm64 only (faster, device-only)
```

This compiles the Mihomo Go core into `Framework/MihomoCore.xcframework` using gomobile. To remove the built framework:

```bash
make clean
```

### 2. Configure signing

Copy the xcconfig template and set your Apple development team ID:

```bash
cp Local.xcconfig.template Local.xcconfig
# Edit Local.xcconfig and replace YOUR_TEAM_ID_HERE with your Team ID
```

> **Finding your Team ID:** Apple Developer portal → Membership → Team ID (10-character string, e.g. `AB12CD34EF`).

Both targets require these capabilities (already configured in entitlements):
- **App Groups** — `group.io.github.baoliandeng`
- **Network Extensions** — Packet Tunnel Provider

If you distribute under a different bundle ID, also update `appGroupIdentifier` and `tunnelBundleIdentifier` in `Shared/Constants.swift` and the matching entitlement files.

### 3. Build and run

```bash
open BaoLianDeng.xcodeproj
```

Select your device and press `Cmd+R`.

**CI-style simulator build (no signing required):**

```bash
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Configuration

The app uses Mihomo YAML configuration format. Edit the config through the in-app editor or place a `config.yaml` in the app's shared container.

Example config:

```yaml
mixed-port: 7890
mode: rule
log-level: info
allow-lan: false
external-controller: 127.0.0.1:9090

tun:
  enable: true
  stack: gvisor
  dns-hijack:
    - 198.18.0.2:53
  auto-route: false
  auto-detect-interface: false

geo-auto-update: false

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query

proxies:
  - name: "my-proxy"
    type: ss
    server: your-server.com
    port: 8388
    cipher: aes-256-gcm
    password: "your-password"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-proxy

rules:
  # Google
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,googlevideo.com,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,gmail.com,PROXY
  # YouTube
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,ytimg.com,PROXY
  # Social
  - DOMAIN-SUFFIX,twitter.com,PROXY
  - DOMAIN-SUFFIX,x.com,PROXY
  - DOMAIN-SUFFIX,instagram.com,PROXY
  - DOMAIN-SUFFIX,facebook.com,PROXY
  # Messaging
  - DOMAIN-SUFFIX,telegram.org,PROXY
  - DOMAIN-SUFFIX,t.me,PROXY
  # Dev
  - DOMAIN-SUFFIX,github.com,PROXY
  - DOMAIN-SUFFIX,githubusercontent.com,PROXY
  # AI
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  # Catch-all
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

> **Note:** The app includes a more comprehensive default config with additional rules when no config file is present. The TUN stack must be `gvisor` (not `system`) and `geo-auto-update` must be `false` for the Network Extension to work reliably. The app will auto-correct these settings on launch if needed.

## Project Structure

```
BaoLianDeng/
├── BaoLianDeng/              # Main iOS app target
│   ├── BaoLianDengApp.swift  # App entry point
│   ├── Views/                # SwiftUI views
│   │   ├── HomeView.swift    #   VPN toggle, mode selector, subscriptions
│   │   ├── ConfigEditorView  #   YAML config editor
│   │   ├── TrafficView.swift #   Usage stats and charts
│   │   ├── SettingsView.swift#   Proxy groups, log level, about
│   │   └── ...               #   ProxyGroupView, TunnelLogView, etc.
│   ├── Assets.xcassets/      # App assets
│   └── Info.plist
├── PacketTunnel/             # Network Extension target
│   └── PacketTunnelProvider.swift
├── Shared/                   # Code shared between targets
│   ├── Constants.swift       # App group ID, bundle IDs, network constants
│   ├── ConfigManager.swift   # YAML config I/O, defaults, sanitization
│   └── VPNManager.swift      # VPN lifecycle (ObservableObject)
├── Go/mihomo-bridge/         # Go bridge to Mihomo core
│   ├── bridge.go             # gomobile API boundary
│   ├── tun_ios.go            # iOS TUN fd discovery
│   ├── Makefile              # gomobile build (setup, ios, ios-arm64)
│   └── patches/              # Vendored dependency patches
├── Framework/                # Built xcframework output (gitignored)
├── Local.xcconfig.template   # Copy to Local.xcconfig, set DEVELOPMENT_TEAM
└── Makefile                  # Top-level: make framework / clean
```

## License

GPL-3.0
