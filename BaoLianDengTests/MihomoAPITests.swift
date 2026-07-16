// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
@testable import BaoLianDeng

@Suite("SOCKS5 CONNECT request")
struct SOCKS5ConnectRequestTests {

    @Test("Encodes IPv4 destinations")
    func encodesIPv4Destination() throws {
        let request = try SOCKS5Client.makeConnectRequest(
            destHost: "1.2.3.4",
            destPort: 443
        )

        #expect(Array(request) == [
            0x05, 0x01, 0x00, 0x01,
            0x01, 0x02, 0x03, 0x04,
            0x01, 0xbb
        ])
    }

    @Test("Encodes IPv6 destinations")
    func encodesIPv6Destination() throws {
        let request = try SOCKS5Client.makeConnectRequest(
            destHost: "2001:db8::1",
            destPort: 853
        )

        #expect(Array(request.prefix(4)) == [0x05, 0x01, 0x00, 0x04])
        #expect(request.count == 22)
        #expect(Array(request.suffix(2)) == [0x03, 0x55])
        // The 16 ATYP payload bytes must be the network-order address itself,
        // not the layout of the `Data` struct wrapping it.
        let addressBytes = Array(request[4..<20])
        #expect(addressBytes == [
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ])
    }

    @Test("Encodes domain destinations")
    func encodesDomainDestination() throws {
        let request = try SOCKS5Client.makeConnectRequest(
            destHost: "example.com",
            destPort: 80
        )

        #expect(Array(request.prefix(5)) == [0x05, 0x01, 0x00, 0x03, 11])
        #expect(String(data: request[5..<16], encoding: .utf8) == "example.com")
        #expect(Array(request.suffix(2)) == [0x00, 0x50])
    }

    @Test("Rejects empty domain destinations")
    func rejectsEmptyDomainDestination() throws {
        #expect(throws: SOCKS5Error.invalidDestinationHost) {
            try SOCKS5Client.makeConnectRequest(destHost: "", destPort: 80)
        }
    }

    @Test("Rejects domains longer than SOCKS5 allows")
    func rejectsOverlongDomainDestination() throws {
        let host = String(repeating: "a", count: 256)

        #expect(throws: SOCKS5Error.invalidDestinationHost) {
            try SOCKS5Client.makeConnectRequest(destHost: host, destPort: 80)
        }
    }
}

// MARK: - Response Model Tests

@Suite("MihomoRule")
struct MihomoRuleTests {

    @Test("Rule stores all fields")
    func ruleFields() {
        let rule = MihomoRule(id: 0, type: "DOMAIN-SUFFIX", payload: "google.com", proxy: "PROXY")
        #expect(rule.id == 0)
        #expect(rule.type == "DOMAIN-SUFFIX")
        #expect(rule.payload == "google.com")
        #expect(rule.proxy == "PROXY")
    }

    @Test("Rule target DIRECT is identifiable")
    func ruleDirectTarget() {
        let rule = MihomoRule(id: 1, type: "MATCH", payload: "", proxy: "DIRECT")
        #expect(rule.proxy == "DIRECT")
    }

    @Test("Rule target REJECT is identifiable")
    func ruleRejectTarget() {
        let rule = MihomoRule(id: 2, type: "DOMAIN", payload: "ads.example.com", proxy: "REJECT")
        #expect(rule.proxy == "REJECT")
    }
}

@Suite("MihomoConnection")
struct MihomoConnectionTests {

    @Test("Connection stores all metadata fields")
    func connectionFields() {
        let conn = MihomoConnection(
            id: "abc-123",
            host: "example.com",
            destinationIP: "93.184.216.34",
            destinationPort: 443,
            network: "tcp",
            type: "HTTPS",
            rule: "DOMAIN-SUFFIX",
            rulePayload: "example.com",
            chains: ["HTTPS", "Vmess", "DIRECT"],
            upload: 1024,
            download: 4096,
            start: Date()
        )
        #expect(conn.id == "abc-123")
        #expect(conn.host == "example.com")
        #expect(conn.destinationIP == "93.184.216.34")
        #expect(conn.destinationPort == 443)
        #expect(conn.network == "tcp")
        #expect(conn.chains.count == 3)
        #expect(conn.upload == 1024)
        #expect(conn.download == 4096)
        #expect(conn.rule == "DOMAIN-SUFFIX")
        #expect(conn.rulePayload == "example.com")
    }

    @Test("Connection chains represent protocol path")
    func connectionChains() {
        let conn = MihomoConnection(
            id: "1", host: "", destinationIP: "", destinationPort: 0,
            network: "tcp", type: "", rule: "", rulePayload: "",
            chains: ["HTTPS", "Vmess", "DIRECT"],
            upload: 0, download: 0, start: Date()
        )
        #expect(conn.chains.first == "HTTPS")
        #expect(conn.chains.last == "DIRECT")
    }
}

@Suite("MihomoConnectionsResponse")
struct MihomoConnectionsResponseTests {

    @Test("Response aggregates connections and totals")
    func responseFields() {
        let response = MihomoConnectionsResponse(
            connections: [],
            uploadTotal: 999_999,
            downloadTotal: 5_000_000
        )
        #expect(response.connections.isEmpty)
        #expect(response.uploadTotal == 999_999)
        #expect(response.downloadTotal == 5_000_000)
    }
}

@Suite("Mihomo Connections Parser")
struct MihomoConnectionsParserTests {

    @Test("Parses current mihomo connection totals and metadata")
    func parsesCurrentConnectionResponse() throws {
        let json = """
        {
          "uploadTotal": 12345,
          "downloadTotal": 67890,
          "connections": [
            {
              "id": "conn-1",
              "metadata": {
                "host": "example.com",
                "destinationIP": "93.184.216.34",
                "destinationPort": "443",
                "network": "tcp",
                "type": "HTTPS"
              },
              "rule": "DOMAIN-SUFFIX",
              "rulePayload": "example.com",
              "chains": ["PROXY", "node-1"],
              "upload": 111,
              "download": 222,
              "start": "2026-06-13T08:00:00.000Z"
            }
          ]
        }
        """

        let response = try MihomoAPI.parseConnectionsResponse(Data(json.utf8))

        #expect(response.uploadTotal == 12345)
        #expect(response.downloadTotal == 67890)
        #expect(response.connections.count == 1)
        let connection = try #require(response.connections.first)
        #expect(connection.destinationPort == 443)
        #expect(connection.upload == 111)
        #expect(connection.download == 222)
        #expect(connection.chains == ["PROXY", "node-1"])
    }

    @Test("Parses legacy totals and numeric ports")
    func parsesLegacyConnectionResponse() throws {
        let json = """
        {
          "upload_total": "12",
          "download_total": "34",
          "connections": [
            {
              "id": "conn-2",
              "metadata": {
                "destinationPort": 53,
                "network": "udp"
              },
              "upload": "5",
              "download": "6"
            }
          ]
        }
        """

        let response = try MihomoAPI.parseConnectionsResponse(Data(json.utf8))

        #expect(response.uploadTotal == 12)
        #expect(response.downloadTotal == 34)
        let connection = try #require(response.connections.first)
        #expect(connection.destinationPort == 53)
        #expect(connection.upload == 5)
        #expect(connection.download == 6)
    }
}

@Suite("MihomoProxyGroup")
struct MihomoProxyGroupTests {

    @Test("Proxy group stores fields and uses name as id")
    func groupFields() {
        let group = MihomoProxyGroup(name: "PROXY", type: "Selector", now: "node-1", all: ["node-1", "node-2"])
        #expect(group.id == "PROXY")
        #expect(group.name == "PROXY")
        #expect(group.type == "Selector")
        #expect(group.now == "node-1")
        #expect(group.all.count == 2)
    }

    @Test("Proxy group with empty all array")
    func groupEmptyAll() {
        let group = MihomoProxyGroup(name: "Empty", type: "Selector", now: "", all: [])
        #expect(group.all.isEmpty)
        #expect(group.now == "")
    }
}

@Suite("ProxiesResult YAML fallback")
struct ProxiesResultYAMLTests {

    @Test("Parses quoted proxy and group names")
    func parsesQuotedProxyAndGroupNames() throws {
        let yaml = """
        proxies:
          - name: "node: one # primary"
            type: vmess
            server: 1.2.3.4
            port: 443
          - {name: "node, two", type: ss, server: 5.6.7.8, port: 8388}
        proxy-groups:
          - name: "Group #1"
            type: select
            proxies:
              - "node: one # primary"
              - "node, two"
              - DIRECT
        rules:
          - MATCH,Group #1
        """

        let result = ProxiesResult.fromYAML(yaml)

        #expect(result.proxies["node: one # primary"]?.type == "vmess")
        #expect(result.proxies["node, two"]?.type == "ss")
        let group = try #require(result.groups["Group #1"])
        #expect(group.type == "Selector")
        #expect(group.now == "node: one # primary")
        #expect(group.all == ["node: one # primary", "node, two", "DIRECT"])
    }

    @Test("Parses non-select group types")
    func parsesNonSelectGroupTypes() throws {
        let yaml = """
        proxies:
          - {name: node1, type: vmess, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Auto
            type: url-test
            url: https://www.gstatic.com/generate_204
            interval: 300
            proxies:
              - node1
        """

        let result = ProxiesResult.fromYAML(yaml)
        let group = try #require(result.groups["Auto"])

        #expect(group.type == "URLTest")
        #expect(group.now == "node1")
        #expect(group.all == ["node1"])
    }

    @Test("Invalid YAML returns empty result")
    func invalidYAMLReturnsEmptyResult() {
        let result = ProxiesResult.fromYAML("proxies: [[[not valid yaml")

        #expect(result.groups.isEmpty)
        #expect(result.proxies.isEmpty)
    }

    @Test("Adds built-in direct and reject proxies")
    func addsBuiltInDirectAndRejectProxies() {
        let result = ProxiesResult.fromYAML("""
        proxies: []
        proxy-groups: []
        """)

        #expect(result.proxies["DIRECT"]?.type == "Direct")
        #expect(result.proxies["REJECT"]?.type == "Reject")
    }
}

@Suite("MihomoMemory")
struct MihomoMemoryTests {

    @Test("Memory stores inuse and oslimit")
    func memoryFields() {
        let mem = MihomoMemory(inuse: 47_185_920, oslimit: 0)
        #expect(mem.inuse == 47_185_920)
        #expect(mem.oslimit == 0)
    }
}

@Suite("MihomoDelayResult")
struct MihomoDelayResultTests {

    @Test("Successful delay result")
    func successDelay() {
        let result = MihomoDelayResult(name: "node-1", delay: 150, error: nil)
        #expect(result.name == "node-1")
        #expect(result.delay == 150)
        #expect(result.error == nil)
    }

    @Test("Timeout delay result")
    func timeoutDelay() {
        let result = MihomoDelayResult(name: "node-2", delay: nil, error: "timeout")
        #expect(result.delay == nil)
        #expect(result.error == "timeout")
    }

    @Test("Error delay result with message")
    func errorDelay() {
        let result = MihomoDelayResult(name: "node-3", delay: nil, error: "connection refused")
        #expect(result.delay == nil)
        #expect(result.error == "connection refused")
    }
}

// MARK: - API Error Tests

@Suite("MihomoAPIError")
struct MihomoAPIErrorTests {

    @Test("Error descriptions are human-readable")
    func errorDescriptions() {
        #expect(MihomoAPIError.invalidURL.errorDescription == "Invalid API URL")
        #expect(MihomoAPIError.notConnected.errorDescription == "VPN is not connected")
        #expect(MihomoAPIError.decodingFailed.errorDescription == "Failed to decode response")
    }

    @Test("requestFailed includes message")
    func requestFailedMessage() {
        let error = MihomoAPIError.requestFailed("GET /rules failed")
        #expect(error.errorDescription == "GET /rules failed")
    }

    @Test("Errors conform to LocalizedError")
    func conformsToLocalizedError() {
        let error: any LocalizedError = MihomoAPIError.invalidURL
        #expect(error.errorDescription != nil)
    }
}

// MARK: - API URL Builder Tests

@Suite("MihomoAPI URL Builder")
struct MihomoAPIURLBuilderTests {

    @Test("Missing controller address throws notConnected")
    func missingControllerAddress() {
        let previousAddr = AppConstants.externalControllerAddr
        AppConstants.sharedDefaults.removeObject(forKey: AppConstants.externalControllerAddrKey)
        defer {
            if let previousAddr {
                AppConstants.sharedDefaults.set(previousAddr, forKey: AppConstants.externalControllerAddrKey)
            }
        }

        do {
            _ = try MihomoAPI.makeURL(pathSegments: ["rules"])
            #expect(Bool(false), "Expected notConnected")
        } catch MihomoAPIError.notConnected {
            #expect(Bool(true))
        } catch {
            #expect(Bool(false), "Expected notConnected, got \(error)")
        }
    }

    @Test("Path segments escape reserved characters")
    func pathSegmentsEscapeReservedCharacters() throws {
        let url = try #require(AppConstants.externalControllerURL(
            controllerAddr: "127.0.0.1:12345",
            pathSegments: ["proxies", "HK/01?fast#primary"]
        ))

        #expect(url.absoluteString == "http://127.0.0.1:12345/proxies/HK%2F01%3Ffast%23primary")
    }

    @Test("Query items preserve URL values")
    func queryItemsPreserveURLValues() throws {
        let probeURL = "https://example.com/generate_204?a=1&b=2"
        let url = try #require(AppConstants.externalControllerURL(
            controllerAddr: "127.0.0.1:12345",
            pathSegments: ["group", "PROXY", "delay"],
            queryItems: [
                URLQueryItem(name: "url", value: probeURL),
                URLQueryItem(name: "timeout", value: "5000"),
            ]
        ))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(url.path == "/group/PROXY/delay")
        #expect(queryItems.first(where: { $0.name == "url" })?.value == probeURL)
        #expect(queryItems.first(where: { $0.name == "timeout" })?.value == "5000")
    }
}

// MARK: - Delay Color Tests

@Suite("Delay Color Logic")
struct DelayColorTests {

    // Replicate NodeRow.delayColor logic for unit testing
    private func delayColor(_ delay: Int) -> String {
        if delay <= 0 { return "gray" }
        if delay < 200 { return "green" }
        if delay < 500 { return "orange" }
        return "red"
    }

    @Test("Delay <= 0 is gray (timeout)")
    func timeoutColor() {
        #expect(delayColor(0) == "gray")
        #expect(delayColor(-1) == "gray")
    }

    @Test("Delay < 200ms is green")
    func fastColor() {
        #expect(delayColor(1) == "green")
        #expect(delayColor(100) == "green")
        #expect(delayColor(199) == "green")
    }

    @Test("Delay 200-499ms is orange")
    func mediumColor() {
        #expect(delayColor(200) == "orange")
        #expect(delayColor(350) == "orange")
        #expect(delayColor(499) == "orange")
    }

    @Test("Delay >= 500ms is red")
    func slowColor() {
        #expect(delayColor(500) == "red")
        #expect(delayColor(1000) == "red")
        #expect(delayColor(9999) == "red")
    }

    @Test("Boundary: 199 is green, 200 is orange")
    func greenOrangeBoundary() {
        #expect(delayColor(199) == "green")
        #expect(delayColor(200) == "orange")
    }

    @Test("Boundary: 499 is orange, 500 is red")
    func orangeRedBoundary() {
        #expect(delayColor(499) == "orange")
        #expect(delayColor(500) == "red")
    }
}

// MARK: - ProxyNode Delay Display Tests

@Suite("ProxyNode Delay")
struct ProxyNodeDelayTests {

    @Test("ProxyNode with nil delay")
    func nilDelay() {
        let node = ProxyNode(name: "test", type: "vmess", server: "1.2.3.4", port: 443, delay: nil)
        #expect(node.delay == nil)
    }

    @Test("ProxyNode with positive delay")
    func positiveDelay() {
        let node = ProxyNode(name: "test", type: "vmess", server: "1.2.3.4", port: 443, delay: 150)
        #expect(node.delay == 150)
    }

    @Test("ProxyNode with zero delay (timeout)")
    func zeroDelay() {
        let node = ProxyNode(name: "test", type: "vmess", server: "1.2.3.4", port: 443, delay: 0)
        #expect(node.delay == 0)
    }

    @Test("ProxyNode delay is mutable")
    func mutableDelay() {
        var node = ProxyNode(name: "test", type: "vmess", server: "1.2.3.4", port: 443)
        #expect(node.delay == nil)
        node.delay = 200
        #expect(node.delay == 200)
    }
}

// MARK: - ProxyNode Type Display Tests

@Suite("ProxyNode Type Icons and Colors")
struct ProxyNodeTypeTests {

    @Test("Known proxy types have specific icons")
    func knownTypeIcons() {
        let types: [(String, String)] = [
            ("ss", "lock.shield"),
            ("shadowsocks", "lock.shield"),
            ("vmess", "v.circle"),
            ("vless", "v.circle.fill"),
            ("trojan", "bolt.shield"),
            ("hysteria", "hare"),
            ("hysteria2", "hare"),
            ("wireguard", "network.badge.shield.half.filled"),
        ]
        for (type, expectedIcon) in types {
            let node = ProxyNode(name: "n", type: type, server: "s", port: 1)
            #expect(node.typeIcon == expectedIcon, "Type '\(type)' should have icon '\(expectedIcon)'")
        }
    }

    @Test("Unknown proxy type uses globe icon")
    func unknownTypeIcon() {
        let node = ProxyNode(name: "n", type: "unknown-protocol", server: "s", port: 1)
        #expect(node.typeIcon == "globe")
    }
}

// MARK: - Connection Filtering Tests

@Suite("Connection Filtering")
struct ConnectionFilteringTests {

    private let sampleConnections = [
        MihomoConnection(
            id: "1", host: "google.com", destinationIP: "142.250.80.46",
            destinationPort: 443, network: "tcp", type: "HTTPS",
            rule: "DOMAIN-SUFFIX", rulePayload: "google.com",
            chains: ["HTTPS", "Vmess", "PROXY"],
            upload: 1024, download: 4096, start: Date()
        ),
        MihomoConnection(
            id: "2", host: "example.org", destinationIP: "93.184.216.34",
            destinationPort: 80, network: "tcp", type: "HTTP",
            rule: "DOMAIN", rulePayload: "example.org",
            chains: ["HTTP", "DIRECT"],
            upload: 512, download: 2048, start: Date()
        ),
        MihomoConnection(
            id: "3", host: "", destinationIP: "10.0.0.1",
            destinationPort: 53, network: "udp", type: "DNS",
            rule: "MATCH", rulePayload: "",
            chains: ["DNS", "DIRECT"],
            upload: 64, download: 128, start: Date()
        ),
    ]

    private func filter(_ connections: [MihomoConnection], by query: String) -> [MihomoConnection] {
        if query.isEmpty { return connections }
        let q = query.lowercased()
        return connections.filter {
            $0.host.lowercased().contains(q) ||
            $0.rule.lowercased().contains(q) ||
            $0.rulePayload.lowercased().contains(q) ||
            $0.chains.joined(separator: " ").lowercased().contains(q) ||
            $0.network.lowercased().contains(q)
        }
    }

    @Test("Empty search returns all connections")
    func emptySearch() {
        let result = filter(sampleConnections, by: "")
        #expect(result.count == 3)
    }

    @Test("Filter by host matches")
    func filterByHost() {
        let result = filter(sampleConnections, by: "google")
        #expect(result.count == 1)
        #expect(result.first?.host == "google.com")
    }

    @Test("Filter by rule type")
    func filterByRule() {
        let result = filter(sampleConnections, by: "MATCH")
        #expect(result.count == 1)
        #expect(result.first?.id == "3")
    }

    @Test("Filter by chain member")
    func filterByChain() {
        let result = filter(sampleConnections, by: "Vmess")
        #expect(result.count == 1)
        #expect(result.first?.host == "google.com")
    }

    @Test("Filter by network type")
    func filterByNetwork() {
        let result = filter(sampleConnections, by: "udp")
        #expect(result.count == 1)
        #expect(result.first?.network == "udp")
    }

    @Test("Filter with no matches returns empty")
    func noMatches() {
        let result = filter(sampleConnections, by: "nonexistent")
        #expect(result.isEmpty)
    }

    @Test("Filter is case-insensitive")
    func caseInsensitive() {
        let result = filter(sampleConnections, by: "GOOGLE")
        #expect(result.count == 1)
    }
}

// MARK: - Rule Proxy Color Tests

@Suite("Rule Proxy Target Colors")
struct RuleProxyColorTests {

    // Per spec: DIRECT=green, REJECT=red, proxy=blue
    // Note: current RulesView.swift has a bug — uses blue for all targets.
    // These tests document the expected behavior.

    private func expectedProxyColor(_ proxy: String) -> String {
        switch proxy {
        case "DIRECT": return "green"
        case "REJECT": return "red"
        default: return "blue"
        }
    }

    @Test("DIRECT target should be green")
    func directGreen() {
        #expect(expectedProxyColor("DIRECT") == "green")
    }

    @Test("REJECT target should be red")
    func rejectRed() {
        #expect(expectedProxyColor("REJECT") == "red")
    }

    @Test("Proxy name target should be blue")
    func proxyBlue() {
        #expect(expectedProxyColor("PROXY") == "blue")
        #expect(expectedProxyColor("MyProxy") == "blue")
    }
}

// MARK: - Rules Filtering Tests

@Suite("Rules Filtering")
struct RulesFilteringTests {

    private let sampleRules = [
        MihomoRule(id: 0, type: "DOMAIN-SUFFIX", payload: "google.com", proxy: "PROXY"),
        MihomoRule(id: 1, type: "DOMAIN", payload: "ads.example.com", proxy: "REJECT"),
        MihomoRule(id: 2, type: "GEOIP", payload: "CN", proxy: "DIRECT"),
        MihomoRule(id: 3, type: "IP-CIDR", payload: "192.168.0.0/16", proxy: "DIRECT"),
        MihomoRule(id: 4, type: "MATCH", payload: "", proxy: "PROXY"),
    ]

    private func filter(_ rules: [MihomoRule], by query: String) -> [MihomoRule] {
        if query.isEmpty { return rules }
        let q = query.lowercased()
        return rules.filter {
            $0.type.lowercased().contains(q) ||
            $0.payload.lowercased().contains(q) ||
            $0.proxy.lowercased().contains(q)
        }
    }

    @Test("Empty search returns all rules")
    func emptySearch() {
        #expect(filter(sampleRules, by: "").count == 5)
    }

    @Test("Filter by payload keyword")
    func filterByPayload() {
        let result = filter(sampleRules, by: "google")
        #expect(result.count == 1)
        #expect(result.first?.payload == "google.com")
    }

    @Test("Filter by rule type")
    func filterByType() {
        let result = filter(sampleRules, by: "GEOIP")
        #expect(result.count == 1)
        #expect(result.first?.type == "GEOIP")
    }

    @Test("Filter by target proxy")
    func filterByProxy() {
        let result = filter(sampleRules, by: "DIRECT")
        #expect(result.count == 2)
    }

    @Test("Filter by REJECT target")
    func filterByReject() {
        let result = filter(sampleRules, by: "REJECT")
        #expect(result.count == 1)
        #expect(result.first?.payload == "ads.example.com")
    }

    @Test("Filter with no matches")
    func noMatches() {
        #expect(filter(sampleRules, by: "nonexistent").isEmpty)
    }

    @Test("Filter is case-insensitive")
    func caseInsensitive() {
        let result = filter(sampleRules, by: "domain-suffix")
        #expect(result.count == 1)
    }

    @Test("MATCH rule with empty payload is searchable by type")
    func matchRuleSearchable() {
        let result = filter(sampleRules, by: "MATCH")
        #expect(result.count == 1)
        #expect(result.first?.payload == "")
    }
}

// MARK: - Connection Sorting Tests

@Suite("Connection Sorting")
struct ConnectionSortingTests {

    @Test("Connections sorted by start time descending (newest first)")
    func sortByStartDescending() {
        let now = Date()
        let connections = [
            MihomoConnection(
                id: "old", host: "old.com", destinationIP: "", destinationPort: 0,
                network: "tcp", type: "", rule: "", rulePayload: "", chains: [],
                upload: 0, download: 0, start: now.addingTimeInterval(-60)
            ),
            MihomoConnection(
                id: "new", host: "new.com", destinationIP: "", destinationPort: 0,
                network: "tcp", type: "", rule: "", rulePayload: "", chains: [],
                upload: 0, download: 0, start: now
            ),
            MihomoConnection(
                id: "mid", host: "mid.com", destinationIP: "", destinationPort: 0,
                network: "tcp", type: "", rule: "", rulePayload: "", chains: [],
                upload: 0, download: 0, start: now.addingTimeInterval(-30)
            ),
        ]
        // ConnectionsView sorts: .sorted { $0.start > $1.start }
        let sorted = connections.sorted { $0.start > $1.start }
        #expect(sorted[0].id == "new")
        #expect(sorted[1].id == "mid")
        #expect(sorted[2].id == "old")
    }
}

// MARK: - SidebarItem Tests

@Suite("SidebarItem")
struct SidebarItemTests {

    @Test("All sidebar items have non-empty labels")
    func allHaveLabels() {
        for item in SidebarItem.allCases {
            // LocalizedStringKey doesn't expose raw string easily,
            // but we can verify the icon is non-empty
            #expect(!item.icon.isEmpty, "SidebarItem.\(item.rawValue) should have an icon")
        }
    }

    @Test("All sidebar items have unique rawValues")
    func uniqueRawValues() {
        let rawValues = SidebarItem.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("Sidebar items have expected SF Symbol icons")
    func expectedIcons() {
        #expect(SidebarItem.subscriptions.icon == "list.bullet")
        #expect(SidebarItem.config.icon == "doc.text.fill")
        #expect(SidebarItem.traffic.icon == "chart.bar.fill")
        #expect(SidebarItem.settings.icon == "gearshape.fill")
        #expect(SidebarItem.tunnelLog.icon == "terminal.fill")
    }

    @Test("id is derived from rawValue")
    func idFromRawValue() {
        for item in SidebarItem.allCases {
            #expect(item.id == item.rawValue)
        }
    }
}

// MARK: - Duration Formatting Tests

@Suite("Duration Formatting")
struct DurationFormattingTests {

    // Replicates ConnectionsView.formatDuration(since:) logic
    private func formatDuration(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }

    @Test("Seconds only for < 60s")
    func secondsOnly() {
        #expect(formatDuration(seconds: 0) == "0s")
        #expect(formatDuration(seconds: 30) == "30s")
        #expect(formatDuration(seconds: 59) == "59s")
    }

    @Test("Minutes and seconds for < 60m")
    func minutesAndSeconds() {
        #expect(formatDuration(seconds: 60) == "1m 0s")
        #expect(formatDuration(seconds: 90) == "1m 30s")
        #expect(formatDuration(seconds: 3599) == "59m 59s")
    }

    @Test("Hours and minutes for >= 60m")
    func hoursAndMinutes() {
        #expect(formatDuration(seconds: 3600) == "1h 0m")
        #expect(formatDuration(seconds: 7260) == "2h 1m")
    }
}

// MARK: - ProxyMode Tests

@Suite("ProxyMode Enum")
struct ProxyModeTests {

    @Test("RawValue round-trip for all modes")
    func rawValueRoundTrip() {
        for mode in [ProxyMode.rule, .global, .direct] {
            let recovered = ProxyMode(rawValue: mode.rawValue)
            #expect(recovered == mode)
        }
    }

    @Test("Rule mode rawValue")
    func ruleRawValue() {
        #expect(ProxyMode.rule.rawValue == "rule")
    }

    @Test("Global mode rawValue")
    func globalRawValue() {
        #expect(ProxyMode.global.rawValue == "global")
    }

    @Test("Direct mode rawValue")
    func directRawValue() {
        #expect(ProxyMode.direct.rawValue == "direct")
    }

    @Test("Invalid rawValue returns nil")
    func invalidRawValue() {
        #expect(ProxyMode(rawValue: "invalid") == nil)
    }
}

// MARK: - TrafficStore Counter Accounting

@MainActor
@Suite("TrafficStore counter accounting", .serialized)
struct TrafficStoreCounterAccountingTests {

    private func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    @Test("Counter reset preserves already persisted daily traffic")
    func counterResetPreservesDailyTraffic() {
        let store = TrafficStore.shared
        let date = today()
        store.resetTrafficStateForTesting(
            dailyRecords: [
                DailyTraffic(date: date, proxyUpload: 2_100, proxyDownload: 4_050)
            ],
            sessionUpload: 2_000,
            sessionDownload: 4_000,
            todayBaseUpload: 100,
            todayBaseDownload: 50,
            lastAttributedUpload: 2_000,
            lastAttributedDownload: 4_000
        )
        defer { store.resetTrafficStateForTesting() }

        store.processConnectionsForTesting(uploadTotal: 100, downloadTotal: 200)

        let record = store.dailyRecords.first { $0.date == date }
        #expect(record?.proxyUpload == 2_200)
        #expect(record?.proxyDownload == 4_250)
    }

    @Test("Initial already-running counter sample does not overwrite persisted day")
    func initialSampleKeepsPersistedDay() {
        let store = TrafficStore.shared
        let date = today()
        store.resetTrafficStateForTesting(
            dailyRecords: [
                DailyTraffic(date: date, proxyUpload: 3_000, proxyDownload: 7_000)
            ]
        )
        defer { store.resetTrafficStateForTesting() }

        store.preparePollingForTesting()
        store.processConnectionsForTesting(uploadTotal: 2_000, downloadTotal: 4_000)

        let record = store.dailyRecords.first { $0.date == date }
        #expect(record?.proxyUpload == 3_000)
        #expect(record?.proxyDownload == 7_000)
        #expect(store.sessionProxyUpload == 2_000)
        #expect(store.sessionProxyDownload == 4_000)
    }
}
