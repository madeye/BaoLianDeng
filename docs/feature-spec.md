# BaoLianDeng Mihomo UI Expansion — Feature Specification

**Version:** 1.0
**Date:** 2026-04-13
**Reference app:** meow-go (Flutter, `../meow-go`)

## Overview

Expose more mihomo proxy engine capabilities in the BaoLianDeng macOS UI. Features are prioritized by user value and implementation complexity.

### Current state

BaoLianDeng has 5 sidebar screens:
- **Subscriptions** (HomeView) — node selection, subscription CRUD, mode picker (Rule/Global/Direct)
- **Config Editor** — structured + raw YAML editing, proxy groups, rules
- **Traffic & Data** — session stats, 30-day chart, connection counts (proxy vs total)
- **Settings** — language, log level, per-app proxy, extension management
- **Tunnel Log** — real-time tunnel extension logs

Existing REST API usage (scattered, no service layer):
- `GET /connections` — polled every 2s for traffic attribution (counts only)
- `GET /proxies` + `PUT /proxies/{group}` — node selection
- `PUT /configs?force=true` — config reload

### Architecture prerequisite

All new features (except Diagnostics) depend on **Task #3: MihomoAPI service layer** — a centralized async Swift client for the mihomo REST API at `127.0.0.1:9090`. This replaces the current scattered URLSession calls and provides typed models for all endpoints.

---

## Feature 1: Proxy Delay Testing

**Priority:** P0 (highest)
**Complexity:** Low
**Depends on:** MihomoAPI service layer

### User value

Users need to know which proxy node is fastest before selecting it. Currently, NodeRow displays a `delay` field but there is no way to trigger a latency test from the UI.

### Requirements

1. **Per-node delay test** — tap a speed-test button on NodeRow to test a single proxy.
   - API: `GET /proxies/{name}/delay?url=http://www.gstatic.com/generate_204&timeout=5000`
   - Show spinner during test, then update delay value in-place.

2. **Per-group batch test** — button on subscription/group header to test all nodes in that group.
   - API: `GET /group/{group}/delay?url=http://www.gstatic.com/generate_204&timeout=5000`
   - Show group-level spinner, update all node delays on completion.

3. **Delay color coding** (already exists in NodeRow):
   - Green: <200ms
   - Orange: 200–500ms
   - Red: >500ms
   - Gray: untested/timeout

### UI changes

- Add speed-test icon button to `NodeRow` (right side, before checkmark).
- Add "Test All" button to subscription group header row.
- Disable test buttons when VPN is disconnected.

### meow-go reference

`flutter_module/lib/widgets/proxy_groups_section.dart` — individual and batch delay testing with color-coded results.

---

## Feature 2: Rules Viewer

**Priority:** P0
**Complexity:** Low
**Depends on:** MihomoAPI service layer

### User value

Users need to see what routing rules are active to understand why traffic goes through proxy vs direct. The Config Editor shows editable rules in the YAML, but there's no read-only view of the *runtime* rules loaded by mihomo.

### Requirements

1. **New sidebar item** — "Rules" under VPN section.
2. **Rule list** — fetch via `GET /rules`, display:
   - Rule type badge (DOMAIN, DOMAIN-SUFFIX, GEOSITE, IP-CIDR, GEOIP, MATCH, etc.)
   - Payload (the match pattern)
   - Target proxy/group (color: green=DIRECT, red=REJECT, blue=proxy name)
3. **Search/filter** — text field filtering across type, payload, and target.
4. **Rule count** in toolbar or header.
5. Auto-refresh on VPN connect; show empty state when disconnected.

### UI changes

- New `RulesView.swift` view file.
- New `SidebarItem.rules` enum case.
- Rule type badge colors (use consistent palette).

### meow-go reference

`flutter_module/lib/screens/rules_screen.dart` — searchable rule list with type badges and proxy coloring.

---

## Feature 3: Enhanced Connections List

**Priority:** P1
**Complexity:** Medium
**Depends on:** MihomoAPI service layer

### User value

TrafficView currently shows connection *counts* only. Users want to see individual connections to understand what apps are connecting, through which proxy, and how much data each uses.

### Requirements

1. **New sidebar item** — "Connections" under VPN section.
2. **Connection list** — poll `GET /connections` every 1s, display:
   - Host:port (hostname preferred, fall back to IP)
   - Protocol chain (e.g., "HTTPS → Vmess → DIRECT")
   - Matched rule + rule payload
   - Upload/download bytes per connection
   - Connection duration
3. **Search/filter** — text field over host, IP, chain, rule.
4. **Close connection** — swipe-to-delete or context menu, calls `DELETE /connections/{id}`.
5. **Close all** — toolbar button with confirmation, calls `DELETE /connections`.
6. Auto-pause polling when view is not visible.

### UI changes

- New `ConnectionsView.swift` view file.
- New `SidebarItem.connections` enum case.
- Connection row component showing metadata compactly.

### meow-go reference

`flutter_module/lib/screens/connections_screen.dart` — 1s polling, swipe-to-close, search, close-all.

---

## Feature 4: Diagnostics Screen

**Priority:** P1
**Complexity:** Low
**Depends on:** Nothing (bridge functions already exist)

### User value

When the proxy isn't working, users need diagnostic tools to identify where the failure is. BaoLianDeng already has 4 diagnostic bridge functions compiled into MihomoCore — they just need a UI.

### Requirements

1. **New sidebar item** — "Diagnostics" under Settings section.
2. **Four diagnostic tests**, each with a "Run" button and result display:
   - **Direct TCP** — `BridgeTestDirectTCP(host, port)` → tests raw connectivity bypassing proxy
   - **Proxy HTTP** — `BridgeTestProxyHTTP(url)` → tests HTTP through SOCKS5 proxy
   - **DNS Resolver** — `BridgeTestDNSResolver(dnsAddr)` → tests DNS resolution
   - **Selected Proxy** — `BridgeTestSelectedProxy(apiAddr)` → tests latency of current proxy
3. Each test shows: OK/FAIL status, result details, elapsed time.
4. "Run All" button to execute all tests sequentially.
5. Tests run in the **main app process** via MihomoCore bridge calls (not in the extension), so they work when VPN is disconnected for direct TCP test, and when connected for proxy/DNS tests.

### UI changes

- New `DiagnosticsView.swift` view file.
- New `SidebarItem.diagnostics` enum case.

### meow-go reference

`flutter_module/lib/screens/diagnostics_screen.dart` — four test cards with run/status indicators.

### Note on bridge call context

The diagnostic bridge functions call into the Go cgo archive linked into the main app. `BridgeTestProxyHTTP` and `BridgeTestSelectedProxy` require the proxy engine to be running (in the extension), so they connect to the SOCKS5 port / REST API from the main app process. `BridgeTestDirectTCP` works regardless.

---

## Feature 5: Providers Management

**Priority:** P2
**Complexity:** Low
**Depends on:** MihomoAPI service layer

### User value

Users with proxy providers (remote subscription sources) or rule providers need to see their status and trigger updates. Currently this is only possible by editing YAML config.

### Requirements

1. **New sidebar item** — "Providers" under VPN section, OR a section within Subscriptions view.
2. **Proxy providers list** — `GET /providers/proxies`, display:
   - Provider name
   - Vehicle type (HTTP / File)
   - Proxy count
   - Last update timestamp
   - "Update" button → `PUT /providers/proxies/{name}`
3. **Rule providers list** — `GET /providers/rules`, display:
   - Provider name
   - Behavior + vehicle type
   - Rule count
   - Last update timestamp
   - "Update" button → `PUT /providers/rules/{name}`

### UI changes

- New `ProvidersView.swift` OR section in existing view.
- Provider row component.

### meow-go reference

`flutter_module/lib/screens/providers_screen.dart` — two-section list with update buttons.

---

## Feature 6: DNS Query Tool

**Priority:** P2
**Complexity:** Low
**Depends on:** MihomoAPI service layer

### User value

Debugging DNS resolution through the proxy. Lets users query mihomo's DNS resolver to verify domains resolve correctly.

### Requirements

1. **Embed in Diagnostics view** as an additional test section (not a separate sidebar item).
2. **Input fields**: domain name (default: `example.com`), record type (default: `A`).
3. **Query**: `GET /dns/query?name={domain}&type={type}`
4. **Results**: list of answers with name, TTL, type, data (IP address).

### UI changes

- Additional section in `DiagnosticsView.swift`.

### meow-go reference

`flutter_module/lib/screens/diagnostics_screen.dart` — DNS query integrated with other diagnostic tests.

---

## Feature 7: Memory Stats

**Priority:** P3
**Complexity:** Trivial
**Depends on:** MihomoAPI service layer

### User value

Low — mainly useful for developers or debugging memory leaks in the Go engine.

### Requirements

1. **Embed in Settings view** — small info row showing mihomo engine memory usage.
2. **API**: `GET /memory` → `{ inuse: bytes, oslimit: bytes }`
3. Display formatted (e.g., "Engine: 45 MB").
4. "Force GC" button calling `BridgeForceGC()`.
5. Refresh on tap or when Settings view appears.

### UI changes

- Additional row in `SettingsView.swift`.

### meow-go reference

`flutter_module/lib/screens/settings_screen.dart` — memory info display in settings.

---

## Feature 8: Mode Switching Card Enhancement

**Priority:** P3 (deprioritized — already exists)
**Complexity:** Trivial
**Depends on:** MihomoAPI service layer (for runtime PATCH)

### User value

Mode switching already exists as a segmented picker in HomeView. Enhancement: use `PATCH /configs` to change mode at runtime without restarting the tunnel (currently it rewrites config YAML and may restart).

### Requirements

1. Keep existing segmented picker in HomeView.
2. When VPN is connected, switch mode via `PATCH /configs` with `{"mode": "rule|global|direct"}`.
3. Fall back to config rewrite + restart when VPN is disconnected.

### UI changes

- Minimal — update `HomeView` mode switching logic only.

### meow-go reference

`flutter_module/lib/widgets/mode_card.dart` — runtime mode PATCH.

---

## New Sidebar Layout

After all features are implemented, the sidebar will have:

```
VPN
  ├── Subscriptions      (existing)
  ├── Rules              (new — Feature 2)
  ├── Connections        (new — Feature 3)
  ├── Config Editor      (existing)
  ├── Traffic & Data     (existing)
  └── Providers          (new — Feature 5)

Settings
  ├── Settings           (existing, +memory stats Feature 7)
  ├── Diagnostics        (new — Features 4 & 6)
  └── Tunnel Log         (existing)
```

---

## Implementation Order

Based on dependencies and priority:

| Phase | Task | Features | Rationale |
|-------|------|----------|-----------|
| 1 | MihomoAPI service layer | (prerequisite) | All REST-based features depend on this |
| 2a | Proxy delay testing | Feature 1 | Highest user value, extends existing UI |
| 2b | Diagnostics view | Feature 4 | No API dependency, uses existing bridge |
| 3 | Rules viewer | Feature 2 | High value, simple read-only view |
| 4 | Enhanced connections | Feature 3 | Medium complexity, real-time polling |
| 5 | Providers management | Feature 5 | Lower priority, simple CRUD |
| 6 | DNS query + Memory | Features 6 & 7 | Bolt-ons to existing views |
| 7 | Mode switching enhancement | Feature 8 | Trivial improvement to existing code |

---

## API Endpoints Summary

New endpoints the MihomoAPI service layer must support:

| Method | Endpoint | Used by |
|--------|----------|---------|
| GET | `/proxies/{name}/delay?url=...&timeout=...` | Feature 1 |
| GET | `/group/{group}/delay?url=...&timeout=...` | Feature 1 |
| GET | `/rules` | Feature 2 |
| GET | `/connections` | Feature 3 (enhanced) |
| DELETE | `/connections/{id}` | Feature 3 |
| DELETE | `/connections` | Feature 3 |
| GET | `/providers/proxies` | Feature 5 |
| PUT | `/providers/proxies/{name}` | Feature 5 |
| GET | `/providers/rules` | Feature 5 |
| PUT | `/providers/rules/{name}` | Feature 5 |
| GET | `/dns/query?name=...&type=...` | Feature 6 |
| GET | `/memory` | Feature 7 |
| PATCH | `/configs` | Feature 8 |
| GET | `/configs` | Feature 8 |

Already used (to migrate into service layer):
| GET | `/connections` | TrafficStore (existing) |
| GET | `/proxies` | VPNManager (existing) |
| PUT | `/proxies/{group}` | VPNManager (existing) |
| PUT | `/configs?force=true` | HomeView (existing) |
