# Mihomo UI Expansion — Architecture Design

## Overview

Expose more mihomo proxy engine functions in the BaoLianDeng UI while minimizing Swift view changes. The approach creates a thin `MihomoAPI` service layer, extends existing views where possible, and adds only two new sidebar items (Rules, Connections).

## Architecture Decisions

### Decision 1: New `MihomoAPI.swift` service — NOT extending VPNManager

**Choice:** Create a standalone `MihomoAPI` actor in `BaoLianDeng/Services/MihomoAPI.swift`.

**Rationale:**
- `VPNManager` owns VPN lifecycle (NEVPNManager, NETunnelProviderManager). API calls to the mihomo REST controller are a separate concern.
- `VPNManager` lives in `Shared/` (used by both targets). The REST API is only called from the main app — it doesn't belong in `Shared/`.
- A dedicated service is easier to test and mock.
- meow-go uses the same separation (`MihomoApi` class vs VPN channel).

**Design:**
```swift
// BaoLianDeng/Services/MihomoAPI.swift
actor MihomoAPI {
    static let shared = MihomoAPI()
    private let baseURL = "http://\(AppConstants.externalControllerAddr)"

    // Proxies
    func getProxies() async throws -> ProxiesResponse
    func selectProxy(group: String, name: String) async throws
    func testGroupDelay(group: String, url: String, timeout: Int) async throws -> [String: Int]

    // Rules
    func getRules() async throws -> [MihomoRule]

    // Connections
    func getConnections() async throws -> ConnectionsResponse
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws

    // Config
    func getConfigs() async throws -> MihomoConfig
    func patchConfigs(_ patch: [String: Any]) async throws

    // Providers
    func getProxyProviders() async throws -> [String: ProxyProvider]
    func getRuleProviders() async throws -> [String: RuleProvider]
    func updateProxyProvider(name: String) async throws
    func updateRuleProvider(name: String) async throws

    // Diagnostics
    func dnsQuery(name: String, type: String?) async throws -> DNSQueryResponse
    func getMemory() async throws -> MemoryInfo
}
```

**Key patterns:**
- Swift `actor` for thread safety (no manual locking needed).
- All methods are `async throws` — callers use `try await`.
- Uses `URLSession.shared` with `async` data methods (no completion handlers).
- Returns strongly-typed `Codable` structs, not raw JSON.
- Throws `MihomoAPIError` enum with `.httpError(statusCode:, operation:)` and `.unavailable` cases.

### Decision 2: Migrate existing REST calls into MihomoAPI

**Current scattered API calls:**
- `TrafficStore.fetchConnections()` → `GET /connections` (closure-based URLSession)
- `VPNManager.selectNodeViaRestAPI()` → `GET /proxies` + `PUT /proxies/{group}` (closure-based)
- `HomeView.reloadMihomoConfig()` → `PUT /configs?force=true` (inline async/await)

**Plan:** After MihomoAPI is stable, migrate these calls to use it. This is a follow-up task, not blocking initial feature work. The existing calls continue to work unchanged.

### Decision 3: Mode switching via REST API instead of tunnel restart

**Current behavior:** `VPNManager.switchMode()` writes config to disk and restarts the tunnel (stop + wait + start). This takes several seconds and drops all connections.

**New behavior:** Call `PATCH /configs {"mode": "rule|global|direct"}` via MihomoAPI. The mihomo engine switches mode instantly without tunnel restart. Fall back to tunnel restart only if the API call fails.

**Where:** Modify `VPNManager.switchMode()` to try the API first:
```swift
func switchMode(_ mode: ProxyMode) {
    ConfigManager.shared.setMode(mode.rawValue)
    guard isConnected else { return }
    Task {
        do {
            try await MihomoAPI.shared.patchConfigs(["mode": mode.rawValue])
        } catch {
            // Fallback: restart tunnel (existing behavior)
            restartTunnel()
        }
    }
}
```

### Decision 4: UI placement — extend existing views vs new views

| Feature | Placement | Rationale |
|---------|-----------|-----------|
| **Mode switching** | Extend HomeView (already has `routingSection`) | Already exists as a segmented picker. Just improve it to use REST API. No view changes needed. |
| **Proxy delay testing** | Extend HomeView / NodeRow | Add a speed-test button per node or per group. Extends existing node list UI. |
| **Rules viewer** | **New sidebar item** → `RulesView` | Rules are a distinct domain. No existing view is a natural home. Searchable/filterable list. |
| **Connections list** | **NavigationLink in TrafficView** → pushes `ConnectionsView` | TrafficView is the natural context for connections. A NavigationLink with summary ("X proxy / Y total") invites drill-down. Avoids sidebar bloat (would be 9 items otherwise). ConnectionsView manages its own 1s polling timer independently. |
| **Diagnostics** | **New sidebar item** → `DiagnosticsView` | Diagnostics has 4 bridge tests + DNS query tool — too much for a Settings section. Gets its own view under Settings section in sidebar. |
| **Providers** | **New sidebar item** → `ProvidersView` | Proxy/rule provider management (update, status). Separate from Subscriptions (which is app-level). |
| **Memory usage** | Extend SettingsView | One line showing memory usage + Force GC button. Trivial addition. |

### Decision 5: Sidebar changes

Add three new items to `SidebarItem` (Connections stays as a NavigationLink inside TrafficView):

```swift
enum SidebarItem: String, CaseIterable, Identifiable {
    case subscriptions   // HomeView (existing)
    case config          // ConfigEditorView (existing)
    case rules           // RulesView (NEW)
    case traffic         // TrafficView (existing) — ConnectionsView accessed via NavigationLink
    case providers       // ProvidersView (NEW)
    case settings        // SettingsView (existing)
    case diagnostics     // DiagnosticsView (NEW)
    case tunnelLog       // TunnelLogView (existing)
}
```

Sidebar layout:
```
VPN
  ├─ Subscriptions       (existing)
  ├─ Config Editor       (existing)
  ├─ Rules               ← NEW
  ├─ Traffic & Data      (existing, ConnectionsView via NavigationLink)
  └─ Providers           ← NEW

Settings
  ├─ Settings            (existing, +memory stats)
  ├─ Diagnostics         ← NEW (bridge tests + DNS query)
  └─ Tunnel Log          (existing)
```

### Decision 6: API unavailable state (VPN disconnected)

When the VPN is disconnected, the mihomo engine isn't running and the REST API at 127.0.0.1:9090 is unreachable.

**Approach:** Each view that depends on the API checks `vpnManager.isConnected`:
- **Connected:** Fetch and display data normally.
- **Disconnected:** Show a non-intrusive placeholder: "Connect VPN to view [rules/connections/etc.]" with a disabled state. No error alerts.

This follows the existing pattern in TrafficView, which starts/stops polling based on VPN connection state.

**In MihomoAPI:** All methods throw `MihomoAPIError.unavailable` on connection failure. Views catch this and show the placeholder rather than an error.

## Data Models

New `Codable` structs in `BaoLianDeng/Models/MihomoModels.swift`:

```swift
// GET /rules response
struct MihomoRule: Codable, Identifiable {
    let type: String      // "DOMAIN-SUFFIX", "GEOIP", etc.
    let payload: String   // "google.com", "CN", etc.
    let proxy: String     // "DIRECT", "Proxy", etc.
    var id: String { "\(type)-\(payload)" }
}

// GET /connections response
struct ConnectionsResponse: Codable {
    let downloadTotal: Int64
    let uploadTotal: Int64
    let connections: [MihomoConnection]
}

struct MihomoConnection: Codable, Identifiable {
    let id: String
    let metadata: ConnectionMetadata
    let upload: Int64
    let download: Int64
    let start: String     // ISO 8601
    let chains: [String]
    let rule: String
    let rulePayload: String
}

struct ConnectionMetadata: Codable {
    let network: String          // "tcp" or "udp"
    let type: String             // "Socks5"
    let sourceIP: String
    let destinationIP: String
    let sourcePort: String
    let destinationPort: String
    let host: String
    let processPath: String?
}

// GET /configs response
struct MihomoConfig: Codable {
    let mode: String
    let logLevel: String?
    let allowLan: Bool?
    let ipv6: Bool?

    enum CodingKeys: String, CodingKey {
        case mode
        case logLevel = "log-level"
        case allowLan = "allow-lan"
        case ipv6
    }
}

// GET /proxies response
struct ProxiesResponse: Codable {
    let proxies: [String: ProxyInfo]
}

struct ProxyInfo: Codable {
    let name: String
    let type: String
    let all: [String]?
    let now: String?
    let history: [ProxyHistory]?
}

struct ProxyHistory: Codable {
    let delay: Int
}

// GET /dns/query response
struct DNSQueryResponse: Codable {
    let Status: Int
    let Answer: [DNSAnswer]?
}

struct DNSAnswer: Codable {
    let name: String
    let type: Int
    let TTL: Int
    let data: String
}

// GET /memory response
struct MemoryInfo: Codable {
    let inuse: Int64
    let oslimit: Int64?
}

// GET /providers/proxies response
struct ProxyProvider: Codable {
    let name: String
    let type: String           // "Proxy"
    let vehicleType: String    // "HTTP", "File"
    let proxies: [ProxyInfo]?
    let updatedAt: String?
}

// GET /providers/rules response
struct RuleProvider: Codable {
    let name: String
    let type: String
    let behavior: String       // "domain", "ipcidr", "classical"
    let vehicleType: String
    let ruleCount: Int
    let updatedAt: String?
}
```

## New Views

### RulesView (`BaoLianDeng/Views/RulesView.swift`)

Searchable list of mihomo rules. Minimal view — just a filtered List.

```
┌─────────────────────────────────────┐
│ 🔍 Search rules...                  │
├─────────────────────────────────────┤
│ DOMAIN-SUFFIX  google.com  → Proxy  │
│ DOMAIN-SUFFIX  github.com  → Proxy  │
│ GEOIP          CN          → DIRECT │
│ MATCH          *           → Proxy  │
└─────────────────────────────────────┘
```

**State:** `@State private var rules: [MihomoRule]`, `@State private var searchText: String`
**Fetch:** On appear (if connected), call `MihomoAPI.shared.getRules()`.
**Filter:** Client-side filter on type, payload, or proxy matching searchText.

### ConnectionsView (`BaoLianDeng/Views/ConnectionsView.swift`)

Active connections list with metadata, auto-refreshing.

```
┌──────────────────────────────────────────────┐
│ 🔍 Filter connections...        [Close All]  │
├──────────────────────────────────────────────┤
│ github.com:443  tcp  ↑1.2KB ↓45KB  Proxy    │
│   Rule: DOMAIN-SUFFIX,github.com             │
│   Chain: ss-server → Proxy                   │
│ 8.8.8.8:443     tcp  ↑0.5KB ↓12KB  DIRECT   │
│   Rule: GEOIP,US                             │
└──────────────────────────────────────────────┘
```

**State:** `@StateObject` wrapper or `@State` with timer-based polling (reuse TrafficStore's 2s timer pattern).
**Actions:** Swipe-to-close individual connection, toolbar "Close All" button.
**Filter:** By host, rule, or chain.

### DiagnosticsView (`BaoLianDeng/Views/DiagnosticsView.swift`)

Dedicated view for network diagnostic tests + DNS query tool. Gets its own sidebar item under Settings section.

```
┌──────────────────────────────────────────────┐
│ Network Diagnostics                [Run All] │
├──────────────────────────────────────────────┤
│ Direct TCP       ✅ OK  (45ms)    [Run]      │
│ Proxy HTTP       ✅ OK  (230ms)   [Run]      │
│ DNS Resolver     ❌ FAIL (timeout) [Run]     │
│ Selected Proxy   ✅ OK  (180ms)   [Run]      │
├──────────────────────────────────────────────┤
│ DNS Query                                    │
│ Domain: [example.com    ]  Type: [A ▾]       │
│ [Query]                                      │
│ example.com  A  93.184.216.34  TTL: 300      │
└──────────────────────────────────────────────┘
```

**Bridge tests (run in main app process):**
- Direct TCP → `BridgeTestDirectTCP(host, port)` — works without VPN
- Proxy HTTP → `BridgeTestProxyHTTP(url)` — requires VPN connected
- DNS Resolver → `BridgeTestDNSResolver(dnsAddr)` — requires VPN connected
- Selected Proxy → `BridgeTestSelectedProxy(apiAddr)` — requires VPN connected

**DNS Query section:**
- Input: domain name + record type picker (A, AAAA, CNAME, MX, TXT)
- API: `GET /dns/query?name={domain}&type={type}` via MihomoAPI
- Results: table of answers (name, type, TTL, data)

**"Run All" button:** Executes all 4 bridge tests sequentially, updating each result in place.

### ProvidersView (`BaoLianDeng/Views/ProvidersView.swift`)

Two-section list showing proxy providers and rule providers with update buttons.

```
┌──────────────────────────────────────────────┐
│ Proxy Providers                              │
├──────────────────────────────────────────────┤
│ my-provider   HTTP  12 proxies  [Update]     │
│   Updated: 2 hours ago                       │
├──────────────────────────────────────────────┤
│ Rule Providers                               │
├──────────────────────────────────────────────┤
│ geosite-cn    HTTP  1200 rules  [Update]     │
│   Updated: 1 day ago                         │
└──────────────────────────────────────────────┘
```

**State:** `@State` arrays for proxy providers and rule providers.
**Fetch:** On appear (if connected), call `MihomoAPI.shared.getProxyProviders()` and `getRuleProviders()`.
**Update:** Button calls `PUT /providers/proxies/{name}` or `PUT /providers/rules/{name}`.

### SettingsView additions

Add one new section to the existing SettingsView:

- **Runtime section** — memory usage row from `MihomoAPI.shared.getMemory()`, "Force GC" button calling `BridgeForceGC()`.

## File Layout

```
BaoLianDeng/
├── Services/
│   └── MihomoAPI.swift          # NEW — REST API service (actor)
├── Models/
│   ├── MihomoModels.swift       # NEW — Codable response types
│   ├── TrafficStore.swift       # EXISTING — unchanged initially
│   └── SubscriptionModels.swift # EXISTING — unchanged
├── Views/
│   ├── RulesView.swift          # NEW — rules list
│   ├── ConnectionsView.swift    # NEW — connections list
│   ├── DiagnosticsView.swift    # NEW — bridge tests + DNS query
│   ├── ProvidersView.swift      # NEW — proxy/rule provider management
│   ├── SidebarView.swift        # MODIFY — add 4 new sidebar items
│   ├── MainContentView.swift    # MODIFY — add 4 cases to detailView switch
│   ├── HomeView.swift           # MODIFY — delay testing + mode switching
│   ├── SettingsView.swift       # MODIFY — add memory stats section
│   └── ...                      # EXISTING — unchanged
└── ...

Shared/
├── VPNManager.swift             # MODIFY — switchMode uses MihomoAPI
└── Constants.swift              # EXISTING — already has externalControllerAddr
```

## Implementation Order

The implementation should proceed in this order (matches task dependencies):

1. **MihomoAPI service + models** (Task #3) — Foundation. All REST-based features depend on this.
2. **Proxy delay testing** (Task #4) — P0. Extends HomeView/NodeRow. Uses `testGroupDelay`, `testProxyDelay`.
3. **Rules viewer** (Task #5) — P0. New RulesView + sidebar item. Uses `getRules`.
4. **Connections list** (Task #6) — P1. New ConnectionsView + sidebar item. Uses `getConnections`, `closeConnection`, `closeAllConnections`.
5. **Mode switching improvement** (Task #7) — P3. Small change to VPNManager.switchMode(). Uses `patchConfigs`.
6. **Diagnostics** (Task #8) — P1. New DiagnosticsView + sidebar item. Uses bridge functions + `dnsQuery` + `getMemory`.

Tasks 4, 5, 6, 7, 8 can be parallelized once MihomoAPI (Task #3) is ready.

## Testing Strategy

- **MihomoAPI:** Unit-testable by injecting a mock URLProtocol. Test JSON parsing with fixture data.
- **Views:** Verify behavior with VPN connected vs disconnected states.
- **Integration:** E2E tests in VM validate actual API responses from running mihomo engine.
