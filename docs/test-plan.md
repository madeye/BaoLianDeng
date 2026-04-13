# Test Plan: Mihomo UI Feature Expansion

**Project:** BaoLianDeng  
**Date:** 2026-04-13  
**Status:** Draft (will be refined as architecture solidifies)

---

## 1. Overview

This test plan covers the new mihomo UI features being added to BaoLianDeng:

| # | Feature | Dev Task | Priority | Description |
|---|---------|----------|----------|-------------|
| 1 | MihomoAPI service layer | #3 | Prereq | Centralized REST API client for mihomo (port 9090) |
| 2 | Proxy delay testing | #4 | P0 | Per-node and per-group latency measurement |
| 3 | Rules viewer | #5 | P0 | Read-only view of runtime rules with search/filter |
| 4 | Connections display | #6 | P1 | Real-time connection list with close/close-all |
| 5 | Diagnostics view | #8 | P1 | 4 bridge diagnostic tests + DNS query tool |
| 6 | Mode switching enhancement | #7 | P3 | Runtime PATCH /configs (no tunnel restart) |
| 7 | Providers management | — | P2 | Proxy/rule provider status and update |
| 8 | Memory stats | — | P3 | Engine memory display + Force GC |

**Reference:** `docs/feature-spec.md` for full requirements.  
**REST endpoints:** 14 new + 4 existing to migrate (see spec §API Endpoints Summary).

**Test framework:** Swift Testing (`@Suite`, `@Test`, `#expect`)  
**Test target:** `BaoLianDengTests`  
**Build command:**
```bash
xcodebuild test \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:BaoLianDengTests
```

---

## 2. MihomoAPI Service Layer (Task #3)

### 2.1 Unit Tests — API Request Formation

| ID | Test | Expected |
|----|------|----------|
| API-01 | `getProxies()` forms correct GET to `/proxies` | URL is `http://127.0.0.1:9090/proxies` |
| API-02 | `getProxyGroup(name:)` URL-encodes group names with spaces/unicode | Encoded path matches RFC 3986 |
| API-03 | `selectProxy(group:name:)` sends PUT to `/proxies/{group}` with JSON body `{"name": "..."}` | Correct method, path, and body |
| API-04 | `getConnections()` forms GET to `/connections` | Correct URL |
| API-05 | `getRules()` forms GET to `/rules` | Correct URL |
| API-06 | `patchMode(mode:)` sends PATCH to `/configs` with `{"mode": "..."}` | Correct method and body |
| API-07 | `getProxyDelay(name:url:timeout:)` forms GET to `/proxies/{name}/delay?timeout=...&url=...` | Correct query parameters |
| API-08 | `getGroupDelay(group:url:timeout:)` forms GET to `/group/{group}/delay?url=...&timeout=...` | Correct URL and params |
| API-09 | `deleteConnection(id:)` sends DELETE to `/connections/{id}` | Correct method and path |
| API-09b | `deleteAllConnections()` sends DELETE to `/connections` | Correct method |
| API-09c | `getProxyProviders()` forms GET to `/providers/proxies` | Correct URL |
| API-09d | `updateProxyProvider(name:)` sends PUT to `/providers/proxies/{name}` | Correct method and path |
| API-09e | `getRuleProviders()` forms GET to `/providers/rules` | Correct URL |
| API-09f | `updateRuleProvider(name:)` sends PUT to `/providers/rules/{name}` | Correct method and path |
| API-09g | `queryDNS(name:type:)` forms GET to `/dns/query?name=...&type=...` | Correct query params |
| API-09h | `getMemory()` forms GET to `/memory` | Correct URL |
| API-09i | `getConfigs()` forms GET to `/configs` | Correct URL |

### 2.2 Unit Tests — Response Parsing

| ID | Test | Expected |
|----|------|----------|
| API-10 | Parse valid proxies JSON response | All proxy groups and nodes extracted |
| API-11 | Parse proxies response with empty `all` array | Returns group with empty node list |
| API-12 | Parse connections response with active connections | Connection metadata (host, download, upload, rule, chain) extracted |
| API-13 | Parse connections response with zero connections | Returns empty array |
| API-14 | Parse rules response | Rule type, payload, and proxy fields extracted |
| API-15 | Parse delay response `{"delay": 150}` | Returns 150 |
| API-16 | Parse delay timeout response (HTTP 408 or delay error) | Returns timeout indicator |
| API-17 | Parse group delay response (multiple node delays) | All node delays extracted |
| API-18 | Parse providers/proxies response | Provider name, type, count, update time |
| API-19 | Parse providers/rules response | Provider name, behavior, rule count |
| API-19b | Parse DNS query response (answer records) | Name, TTL, type, data extracted |
| API-19c | Parse memory response `{"inuse": N, "oslimit": N}` | Both values extracted |
| API-19d | Parse configs response with mode field | Mode string extracted |

### 2.3 Unit Tests — Error Handling

| ID | Test | Expected |
|----|------|----------|
| API-20 | API call when VPN is disconnected (connection refused) | Returns descriptive error, no crash |
| API-21 | API returns HTTP 500 | Error propagated with status code |
| API-22 | API returns malformed JSON | Decoding error handled gracefully |
| API-23 | API request times out (>5s) | Timeout error returned |
| API-24 | API returns HTTP 404 for unknown proxy group | Specific "not found" error |

### 2.4 Implementation Notes

- Use `URLProtocol` subclass to mock HTTP responses in tests (no real server needed)
- Test file: `BaoLianDengTests/MihomoAPITests.swift`

---

## 3. Proxy Delay Testing (Task #4)

### 3.1 Unit Tests — Delay Logic

| ID | Test | Expected |
|----|------|----------|
| DLY-01 | Delay value < 200ms | Displayed in green |
| DLY-02 | Delay value 200–499ms | Displayed in orange |
| DLY-03 | Delay value >= 500ms | Displayed in red |
| DLY-04 | Delay value is nil (not tested yet) | No delay badge shown |
| DLY-05 | Delay value is 0 (timeout/error) | Shows timeout indicator |
| DLY-06 | `delayColor()` returns correct SwiftUI Color for each threshold | Matches spec |

### 3.2 Unit Tests — Batch Group Delay

| ID | Test | Expected |
|----|------|----------|
| DLY-07 | Batch delay API returns delays for all nodes in group | All node delay values updated |
| DLY-08 | Batch delay with some nodes timing out | Timed-out nodes show gray, others show delay |

### 3.3 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| DLY-10 | Tap test button on a single node | Spinner shows during test, delay value appears |
| DLY-11 | Tap "Test All" on group header | Group spinner, all node delays updated on completion |
| DLY-12 | Test node when VPN is disconnected | Test buttons disabled |
| DLY-13 | Test node with very high latency (>5000ms) | Shows timeout after reasonable duration |
| DLY-14 | Rapid repeated taps on test button | Debounced; no duplicate requests or UI glitches |

---

## 4. Rules Viewer (Task #5)

### 4.1 Unit Tests — Rules Data

| ID | Test | Expected |
|----|------|----------|
| RUL-01 | Parse rules API response with mixed types (DOMAIN-SUFFIX, GEOIP, MATCH, etc.) | All rule types parsed correctly |
| RUL-02 | Rule count matches API response | Exact count |
| RUL-03 | Search filter by payload keyword | Only matching rules returned |
| RUL-04 | Search filter by rule type | Only matching type returned |
| RUL-05 | Search with empty string | All rules returned |
| RUL-06 | Search with no matches | Empty result set |
| RUL-07 | Rule target "DIRECT" renders green | Correct color |
| RUL-08 | Rule target "REJECT" renders red | Correct color |
| RUL-09 | Rule target proxy name renders blue | Correct color |

### 4.2 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| RUL-10 | Open rules viewer | Rules list loads and displays |
| RUL-11 | Scroll through large rule set (1000+ rules) | Smooth scrolling, no lag |
| RUL-12 | Type in search field | List filters in real-time |
| RUL-13 | Rules viewer when VPN disconnected | Shows empty state or error message |
| RUL-14 | Rules with long payload strings | Text truncated or wrapped gracefully |

---

## 5. Connections Display (Task #6)

### 5.1 Unit Tests — Connection Parsing

| ID | Test | Expected |
|----|------|----------|
| CON-01 | Parse connection with all fields (host, download, upload, chains, rule, start time) | All fields extracted |
| CON-02 | Parse connection with missing optional fields | Defaults used, no crash |
| CON-03 | Connection list sorting by download bytes | Descending order |
| CON-04 | Connection filtering by keyword | Matches host, rule, or chain |
| CON-05 | Connection count matches API response | Exact match |
| CON-06 | Connection includes protocol chain (e.g. "HTTPS → Vmess → DIRECT") | Chain parsed and formatted |
| CON-07 | Connection includes matched rule + payload | Rule info extracted |
| CON-08 | Connection duration calculated from start time | Duration displayed correctly |

### 5.2 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| CON-10 | Open connections view with active VPN | Live connections displayed |
| CON-11 | Real-time update (new connections appear) | List updates without full reload |
| CON-12 | Connections view when VPN disconnected | Empty state shown |
| CON-13 | Connection with very long hostname | Truncated with ellipsis |
| CON-14 | Swipe-to-close a single connection (`DELETE /connections/{id}`) | Connection removed from list |
| CON-15 | "Close All" toolbar button with confirmation (`DELETE /connections`) | All connections cleared |
| CON-16 | High connection count (100+) | UI remains responsive |
| CON-17 | Polling pauses when view is not visible | No unnecessary API calls |

---

## 6. Mode Switching (Task #7)

### 6.1 Unit Tests — Mode Logic

| ID | Test | Expected |
|----|------|----------|
| MOD-01 | Switch to Rule mode updates config YAML `mode: rule` | Config written correctly |
| MOD-02 | Switch to Global mode updates config YAML `mode: global` | Config written correctly |
| MOD-03 | Switch to Direct mode updates config YAML `mode: direct` | Config written correctly |
| MOD-04 | Mode persists in UserDefaults after switch | Value survives app restart |
| MOD-05 | `ProxyMode` enum rawValue round-trip | `.init(rawValue:)` matches `.rawValue` |
| MOD-06 | When VPN connected, mode switch uses `PATCH /configs` (no tunnel restart) | API called, not config rewrite |
| MOD-07 | When VPN disconnected, mode switch falls back to config rewrite | YAML updated for next start |

### 6.2 Integration Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| MOD-10 | Switch mode while VPN connected — verify via `GET /configs` | Runtime mode matches instantly |
| MOD-11 | Switch mode while VPN disconnected | Mode saved; applied on next VPN connect |
| MOD-12 | Mode picker reflects current state on app launch | Correct segment highlighted |
| MOD-13 | Switch mode rapidly between all three | No race conditions, final mode is correct |
| MOD-14 | Mode switch via PATCH does NOT restart tunnel | VPN stays connected, no brief disconnect |

---

## 7. Diagnostics View (Task #8)

### 7.1 Unit Tests — Bridge Diagnostic Functions

Note: Bridge functions run in the **main app process** via MihomoCore cgo archive. `BridgeTestDirectTCP` works without VPN. `BridgeTestProxyHTTP` and `BridgeTestSelectedProxy` require the proxy engine (extension) to be running.

| ID | Test | Expected |
|----|------|----------|
| DIA-01 | `BridgeTestDirectTCP(host, port)` — successful connection | Pass status with timing |
| DIA-02 | `BridgeTestDirectTCP` — unreachable host | Fail status with error message |
| DIA-03 | `BridgeTestProxyHTTP(url)` — successful via SOCKS5 | Pass with timing |
| DIA-04 | `BridgeTestDNSResolver(dnsAddr)` — successful resolution | Pass with resolved IP |
| DIA-05 | `BridgeTestSelectedProxy(apiAddr)` — latency measurement | Pass with delay in ms |
| DIA-06 | Direct TCP test works when VPN is disconnected | Pass (no proxy needed) |
| DIA-07 | Proxy HTTP / Selected Proxy tests fail when VPN disconnected | Descriptive failure messages |

### 7.2 Unit Tests — DNS Query Tool (Feature 6)

| ID | Test | Expected |
|----|------|----------|
| DNS-01 | Query `GET /dns/query?name=example.com&type=A` | Answer records with IP addresses |
| DNS-02 | Query with type=AAAA | IPv6 records returned |
| DNS-03 | Query for non-existent domain | Empty answer or NXDOMAIN indication |
| DNS-04 | Query when VPN disconnected | Error handled gracefully |
| DNS-05 | Parse DNS answer: name, TTL, type, data fields | All fields extracted |

### 7.3 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| DIA-10 | Open diagnostics view | 4 bridge test cards + DNS query section visible |
| DIA-11 | "Run All" button executes all 4 bridge tests sequentially | Each shows spinner then OK/FAIL with timing |
| DIA-12 | Run individual diagnostic test | Only that test executes |
| DIA-13 | Direct TCP test with VPN off | Passes (works without proxy) |
| DIA-14 | Proxy/DNS/Selected tests with VPN off | Clear failure messages |
| DIA-15 | DNS query: enter domain, select type, submit | Answer records displayed |
| DIA-16 | Copy diagnostic results | Results copied to clipboard |

---

## 8. Providers Management (Feature 5, P2)

### 8.1 Unit Tests — Provider Data

| ID | Test | Expected |
|----|------|----------|
| PRV-01 | Parse proxy providers response — name, vehicle type, proxy count, update time | All fields extracted |
| PRV-02 | Parse rule providers response — name, behavior, vehicle type, rule count | All fields extracted |
| PRV-03 | Provider with HTTP vehicle type | Type shown as "HTTP" |
| PRV-04 | Provider with File vehicle type | Type shown as "File" |
| PRV-05 | Update proxy provider (`PUT /providers/proxies/{name}`) succeeds | Success response handled |
| PRV-06 | Update rule provider (`PUT /providers/rules/{name}`) succeeds | Success response handled |
| PRV-07 | Update provider when VPN disconnected | Error handled gracefully |

### 8.2 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| PRV-10 | Open providers view | Proxy and rule providers listed in separate sections |
| PRV-11 | Tap "Update" on a proxy provider | Spinner, then updated timestamp |
| PRV-12 | Tap "Update" on a rule provider | Spinner, then updated timestamp |
| PRV-13 | Providers view when VPN disconnected | Empty state or error message |

---

## 9. Memory Stats (Feature 7, P3)

### 9.1 Unit Tests

| ID | Test | Expected |
|----|------|----------|
| MEM-01 | Parse memory response `{"inuse": 47185920, "oslimit": 0}` | Formatted as "45 MB" |
| MEM-02 | `BridgeForceGC()` call completes without error | No crash |
| MEM-03 | Memory display with zero inuse | Shows "0 MB" |

### 9.2 UI Verification (Manual)

| ID | Test | Expected |
|----|------|----------|
| MEM-10 | Memory row visible in Settings view | Shows "Engine: XX MB" |
| MEM-11 | "Force GC" button tap | Memory value decreases (or stays same) |
| MEM-12 | Memory display when VPN disconnected | Shows N/A or hides |
| MEM-13 | Memory refreshes when Settings view appears | Value is current |

---

## 10. Cross-Cutting Concerns

### 10.1 VPN State Transitions

| ID | Test | Expected |
|----|------|----------|
| VPN-01 | All new views handle VPN connect during viewing | Data populates without manual refresh |
| VPN-02 | All new views handle VPN disconnect during viewing | Graceful degradation, no crashes |
| VPN-03 | API polling stops when VPN disconnects | No repeated connection-refused errors |
| VPN-04 | API polling resumes on VPN reconnect | Data refreshes automatically |

### 10.2 Performance

| ID | Test | Expected |
|----|------|----------|
| PERF-01 | Memory usage with connections polling active | No unbounded growth over 10+ minutes |
| PERF-02 | CPU usage during idle (VPN on, all views open) | < 5% sustained |
| PERF-03 | App launch time not regressed | No noticeable delay vs baseline |

### 10.3 Regression

| ID | Test | Expected |
|----|------|----------|
| REG-01 | Existing unit tests still pass | Zero failures |
| REG-02 | Traffic view still updates correctly | Upload/download counters match |
| REG-03 | Proxy node selection still works | Node selected via REST API |
| REG-04 | Config editor unaffected | Rules/proxy-groups edit and save |
| REG-05 | Per-app proxy settings unaffected | Settings persist and apply |

---

## 11. Test Infrastructure Requirements

### Mock HTTP Server (for unit tests)
- `URLProtocol` subclass that intercepts requests to `127.0.0.1:9090`
- Configurable responses per endpoint (JSON fixtures)
- Supports simulating: delays, HTTP errors, malformed responses, connection refused

### JSON Fixtures
Create fixture files in `BaoLianDengTests/Fixtures/`:
- `proxies.json` — sample `/proxies` response
- `connections.json` — sample `/connections` response
- `rules.json` — sample `/rules` response
- `configs.json` — sample `/configs` response
- `delay.json` — sample single-node delay response
- `group_delay.json` — sample batch group delay response
- `providers_proxies.json` — sample `/providers/proxies` response
- `providers_rules.json` — sample `/providers/rules` response
- `dns_query.json` — sample `/dns/query` response
- `memory.json` — sample `/memory` response

### Test Helpers
- `makeProxyNode(name:delay:)` — factory for test ProxyNode instances
- `makeConnection(host:rule:download:)` — factory for test connection data
- `makeProvider(name:type:count:)` — factory for test provider data
- `makeDNSAnswer(name:ttl:type:data:)` — factory for DNS answer records

---

## 12. Execution Plan

| Phase | When | Scope |
|-------|------|-------|
| Phase 1 | After Task #3 (API layer) done | API unit tests (Section 2) |
| Phase 2a | After Task #4 (delay) done | Delay testing (Section 3) |
| Phase 2b | After Task #8 (diagnostics) done | Diagnostics + DNS query (Section 7) |
| Phase 3 | After Tasks #5-#7 done | Rules, connections, mode switching (Sections 4-6) |
| Phase 4 | After P2/P3 features done | Providers, memory stats (Sections 8-9) |
| Phase 5 | After all dev tasks done | Manual UI verification, cross-cutting tests (Section 10) |
| Phase 6 | Pre-release | Full regression suite |

---

## 13. Exit Criteria

- All unit tests pass (`xcodebuild test` exits 0)
- `swiftlint lint --strict` passes
- No P0/P1 bugs open
- Manual UI verification checklist 100% complete
- No memory leaks detected in new features
- Existing tests still pass (zero regressions)
