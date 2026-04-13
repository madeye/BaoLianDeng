// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Models

struct Subscription: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var nodes: [ProxyNode]
    var rawContent: String?
    var isUpdating: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, url, nodes, rawContent
    }
}

struct ProxyNode: Identifiable, Codable {
    var id = UUID()
    var name: String
    var type: String
    var server: String
    var port: Int
    var delay: Int?

    var typeIcon: String {
        switch type.lowercased() {
        case "ss", "shadowsocks": return "lock.shield"
        case "vmess": return "v.circle"
        case "vless": return "v.circle.fill"
        case "trojan": return "bolt.shield"
        case "hysteria", "hysteria2": return "hare"
        case "wireguard": return "network.badge.shield.half.filled"
        default: return "globe"
        }
    }

    var typeColor: Color {
        switch type.lowercased() {
        case "ss", "shadowsocks": return .blue
        case "vmess": return .purple
        case "vless": return .indigo
        case "trojan": return .red
        case "hysteria", "hysteria2": return .orange
        case "wireguard": return .green
        default: return .gray
        }
    }
}

// MARK: - Add Subscription Sheet

struct AddSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var subscriptions: [Subscription]
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Enter a subscription URL to import proxy nodes. Supported formats: Clash YAML, base64-encoded links.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSubscription()
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }

    private func addSubscription() {
        let sub = Subscription(name: name, url: url, nodes: [])
        subscriptions.append(sub)
        let snapshot = subscriptions
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: "subscriptions")
        }
    }
}

// MARK: - Edit Subscription Sheet

struct EditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    let onSave: (Subscription) -> Void

    @State private var name: String
    @State private var url: String

    init(subscription: Subscription, onSave: @escaping (Subscription) -> Void) {
        self.subscription = subscription
        self.onSave = onSave
        _name = State(initialValue: subscription.name)
        _url = State(initialValue: subscription.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = subscription
                        updated.name = name
                        updated.url = url
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

// MARK: - Reload Result

struct ReloadResult: Identifiable {
    let id = UUID()
    let succeeded: [String]
    let failed: [(String, String)]

    var message: String {
        var parts: [String] = []
        if !succeeded.isEmpty {
            parts.append("✓ \(succeeded.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            let names = failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            parts.append("✗ \(names)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Subscription Parser

enum SubscriptionParser {

    /// Parse subscription text. Handles both YAML (Clash) and base64-encoded proxy URI lists.
    /// Returns `(nodes, yaml)` where `yaml` is the generated YAML for URI lists, or nil for YAML input.
    static func parseWithYAML(_ text: String) -> (nodes: [ProxyNode], generatedYAML: String?) {
        // Try base64 decode first — subscription services return base64-encoded URI lists
        if let decoded = tryBase64Decode(text) {
            let lines = decoded.components(separatedBy: "\n").filter { !$0.isEmpty }
            let hasURIs = lines.contains { isProxyURI($0) }
            if hasURIs {
                AppLogger.log(AppLogger.parser, category: "parser", "detected base64-encoded URI list (\(lines.count) lines)")
                let (nodes, yaml) = parseURIList(lines)
                return (nodes, yaml)
            }
        }
        // Check if raw text is already a URI list (not base64 encoded)
        let rawLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        if rawLines.count > 0, rawLines.allSatisfy({ isProxyURI($0) || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            AppLogger.log(AppLogger.parser, category: "parser", "detected raw URI list (\(rawLines.count) lines)")
            let (nodes, yaml) = parseURIList(rawLines)
            return (nodes, yaml)
        }
        // Fall back to YAML parsing
        return (parse(text), nil)
    }

    static func parse(_ text: String) -> [ProxyNode] {
        // Normalize CRLF / bare CR to LF so trailing \r doesn't break value parsing
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var nodes: [ProxyNode] = []
        var inProxies = false
        var current: [String: String] = [:]

        AppLogger.log(AppLogger.parser, category: "parser", "total lines: \(lines.count), text length: \(text.count)")

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("proxies:") {
                inProxies = true
                AppLogger.log(AppLogger.parser, category: "parser", "found 'proxies:' at line \(lineNum)")
                continue
            }
            // Top-level key ends the proxies section
            if inProxies, !line.hasPrefix(" "), !line.isEmpty, line.contains(":") {
                AppLogger.log(AppLogger.parser, category: "parser", "proxies section ended at line \(lineNum): '\(String(line.prefix(80)))'")
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                inProxies = false
                continue
            }
            guard inProxies else { continue }

            if trimmed == "-" {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
            } else if trimmed.hasPrefix("- {") && trimmed.hasSuffix("}") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                let inner = String(trimmed.dropFirst(3).dropLast())
                for pair in splitFlowMapping(inner) {
                    parseKV(pair, into: &current)
                }
            } else if trimmed.hasPrefix("- ") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                parseKV(String(trimmed.dropFirst(2)), into: &current)
            } else {
                parseKV(trimmed, into: &current)
            }
        }
        if let node = makeNode(from: current) { nodes.append(node) }
        AppLogger.log(AppLogger.parser, category: "parser", "result: \(nodes.count) nodes parsed")
        if nodes.isEmpty {
            // Dump first few proxies-section lines for debugging
            var proxiesStart = -1
            for (i, l) in lines.enumerated() {
                if l.hasPrefix("proxies:") { proxiesStart = i; break }
            }
            if proxiesStart >= 0 {
                let end = min(proxiesStart + 10, lines.count)
                for i in proxiesStart..<end {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            } else {
                AppLogger.log(AppLogger.parser, category: "parser", "WARNING: no 'proxies:' section found in text")
                // Log first 10 lines to see what we got
                for i in 0..<min(10, lines.count) {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            }
        }
        return nodes
    }

    private static func parseKV(_ s: String, into dict: inout [String: String]) {
        guard let idx = s.firstIndex(of: ":") else { return }
        let key = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        var value = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { dict[key] = value }
    }

    /// Split a YAML flow mapping interior on commas, respecting quoted values.
    /// e.g. `name: "a, b", type: ss` → [`name: "a, b"`, `type: ss`]
    private static func splitFlowMapping(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote: Character?
        for ch in s {
            if inQuote != nil {
                current.append(ch)
                if ch == inQuote { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func makeNode(from dict: [String: String]) -> ProxyNode? {
        guard !dict.isEmpty else { return nil }
        guard let name = dict["name"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'name', keys=\(dict.keys.sorted().joined(separator: ","))")
            return nil
        }
        guard let type_ = dict["type"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'type' for '\(name)'")
            return nil
        }
        guard let server = dict["server"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'server' for '\(name)'")
            return nil
        }
        guard let portStr = dict["port"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'port' for '\(name)'")
            return nil
        }
        guard let port = Int(portStr) else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: invalid port '\(portStr)' for '\(name)'")
            return nil
        }
        return ProxyNode(name: name, type: type_, server: server, port: port)
    }

    // MARK: - Base64 / URI List Support

    private static func tryBase64Decode(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        // Base64 text shouldn't contain proxy URI schemes or YAML markers
        if cleaned.hasPrefix("proxies:") || cleaned.contains("://") { return nil }
        // Pad if needed
        var padded = cleaned
        let remainder = padded.count % 4
        if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private static func isProxyURI(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["vless://", "vmess://", "trojan://", "ss://", "ssr://", "hysteria2://", "hysteria://", "tuic://"]
        return schemes.contains { trimmed.hasPrefix($0) }
    }

    /// Parse a list of proxy URI lines into nodes + generated YAML.
    private static func parseURIList(_ lines: [String]) -> (nodes: [ProxyNode], yaml: String) {
        var nodes: [ProxyNode] = []
        var yamlProxies: [String] = []
        var seenNames: [String: Int] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, isProxyURI(trimmed) else { continue }

            if let (node, yaml) = parseProxyURI(trimmed, seenNames: &seenNames) {
                nodes.append(node)
                yamlProxies.append(yaml)
            }
        }

        // Build complete YAML with proxies + proxy-groups (no leading indentation)
        let nodeNames = nodes.map { "      - \"\($0.name)\"" }.joined(separator: "\n")
        var fullYAML = "proxies:\n"
        fullYAML += yamlProxies.joined(separator: "\n")
        fullYAML += "\n\nproxy-groups:\n"
        fullYAML += "  - name: PROXY\n"
        fullYAML += "    type: select\n"
        fullYAML += "    proxies:\n"
        fullYAML += nodeNames

        AppLogger.log(AppLogger.parser, category: "parser", "URI list: parsed \(nodes.count) nodes")
        return (nodes, fullYAML)
    }

    /// Parse a single proxy URI and return a ProxyNode + YAML snippet.
    private static func parseProxyURI(_ uri: String, seenNames: inout [String: Int]) -> (ProxyNode, String)? {
        guard let schemeEnd = uri.range(of: "://") else { return nil }
        let scheme = String(uri[..<schemeEnd.lowerBound]).lowercased()

        switch scheme {
        case "vless":
            return parseVlessURI(uri, seenNames: &seenNames)
        case "vmess":
            return parseVmessURI(uri, seenNames: &seenNames)
        case "trojan":
            return parseTrojanURI(uri, seenNames: &seenNames)
        case "ss":
            return parseShadowsocksURI(uri, seenNames: &seenNames)
        default:
            AppLogger.log(AppLogger.parser, category: "parser", "unsupported URI scheme: \(scheme)")
            return nil
        }
    }

    /// Deduplicate node names by appending a counter.
    private static func uniqueName(_ name: String, seenNames: inout [String: Int]) -> String {
        let count = seenNames[name, default: 0]
        seenNames[name] = count + 1
        return count == 0 ? name : "\(name) (\(count + 1))"
    }

    /// Escape a string for YAML double-quoted value.
    private static func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - VLESS Parser

    private static func parseVlessURI(_ uri: String, seenNames: inout [String: Int]) -> (ProxyNode, String)? {
        // vless://uuid@server:port?params#name
        guard let hashIdx = uri.lastIndex(of: "#") else { return nil }
        let rawName = String(uri[uri.index(after: hashIdx)...])
            .removingPercentEncoding ?? String(uri[uri.index(after: hashIdx)...])
        let beforeHash = String(uri[..<hashIdx])

        guard let schemeEnd = beforeHash.range(of: "://") else { return nil }
        let afterScheme = String(beforeHash[schemeEnd.upperBound...])

        let queryParts = afterScheme.components(separatedBy: "?")
        let userHost = queryParts[0]
        let queryString = queryParts.count > 1 ? queryParts[1] : ""
        let params = parseQueryString(queryString)

        guard let atIdx = userHost.lastIndex(of: "@") else { return nil }
        let uuid = String(userHost[..<atIdx])
        let hostPort = String(userHost[userHost.index(after: atIdx)...])
        guard let colonIdx = hostPort.lastIndex(of: ":") else { return nil }
        let server = String(hostPort[..<colonIdx])
        guard let port = Int(hostPort[hostPort.index(after: colonIdx)...]) else { return nil }

        let name = uniqueName(rawName, seenNames: &seenNames)
        let escapedName = yamlEscape(name)

        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    type: vless\n"
        yaml += "    server: \(server)\n"
        yaml += "    port: \(port)\n"
        yaml += "    uuid: \(uuid)\n"
        yaml += "    udp: true\n"

        if let tls = params["security"], tls == "tls" {
            yaml += "    tls: true\n"
            if let sni = params["sni"] { yaml += "    servername: \(sni)\n" }
            if let fp = params["fp"] { yaml += "    client-fingerprint: \(fp)\n" }
            if let alpn = params["alpn"] {
                let alpnList = alpn.removingPercentEncoding?.components(separatedBy: ",") ?? [alpn]
                yaml += "    alpn:\n"
                for a in alpnList { yaml += "      - \(a)\n" }
            }
        } else if params["security"] == "reality" {
            yaml += "    tls: true\n"
            if let sni = params["sni"] { yaml += "    servername: \(sni)\n" }
            if let fp = params["fp"] { yaml += "    client-fingerprint: \(fp)\n" }
            yaml += "    reality-opts:\n"
            if let pbk = params["pbk"] { yaml += "      public-key: \(pbk)\n" }
            if let sid = params["sid"] { yaml += "      short-id: \(sid)\n" }
        }

        let network = params["type"] ?? "tcp"
        yaml += "    network: \(network)\n"
        if network == "ws" {
            yaml += "    ws-opts:\n"
            if let path = params["path"]?.removingPercentEncoding {
                yaml += "      path: \"\(yamlEscape(path))\"\n"
            }
            if let host = params["host"] {
                yaml += "      headers:\n"
                yaml += "        Host: \(host)\n"
            }
        } else if network == "grpc" {
            if let serviceName = params["serviceName"] {
                yaml += "    grpc-opts:\n"
                yaml += "      grpc-service-name: \(serviceName)\n"
            }
        }

        if let flow = params["flow"], !flow.isEmpty {
            yaml += "    flow: \(flow)\n"
        }

        let node = ProxyNode(name: name, type: "vless", server: server, port: port)
        return (node, yaml)
    }

    // MARK: - VMess Parser

    private static func parseVmessURI(_ uri: String, seenNames: inout [String: Int]) -> (ProxyNode, String)? {
        // vmess://base64json
        guard let schemeEnd = uri.range(of: "://") else { return nil }
        let encoded = String(uri[schemeEnd.upperBound...])
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let server = json["add"] as? String,
              let portVal = json["port"],
              let uuid = json["id"] as? String else { return nil }

        let port: Int
        if let p = portVal as? Int { port = p
        } else if let ps = portVal as? String, let p = Int(ps) { port = p
        } else { return nil }

        let rawName = (json["ps"] as? String) ?? "\(server):\(port)"
        let name = uniqueName(rawName, seenNames: &seenNames)
        let escapedName = yamlEscape(name)
        let aid = (json["aid"] as? Int) ?? Int(json["aid"] as? String ?? "0") ?? 0
        let network = (json["net"] as? String) ?? "tcp"
        let tls = (json["tls"] as? String) ?? ""

        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    type: vmess\n"
        yaml += "    server: \(server)\n"
        yaml += "    port: \(port)\n"
        yaml += "    uuid: \(uuid)\n"
        yaml += "    alterId: \(aid)\n"
        yaml += "    cipher: auto\n"
        yaml += "    udp: true\n"

        if tls == "tls" {
            yaml += "    tls: true\n"
            if let sni = json["sni"] as? String, !sni.isEmpty {
                yaml += "    servername: \(sni)\n"
            }
        }

        yaml += "    network: \(network)\n"
        if network == "ws" {
            yaml += "    ws-opts:\n"
            let path = (json["path"] as? String) ?? "/"
            yaml += "      path: \"\(yamlEscape(path))\"\n"
            if let host = json["host"] as? String, !host.isEmpty {
                yaml += "      headers:\n"
                yaml += "        Host: \(host)\n"
            }
        } else if network == "grpc" {
            if let serviceName = json["path"] as? String {
                yaml += "    grpc-opts:\n"
                yaml += "      grpc-service-name: \(serviceName)\n"
            }
        }

        let node = ProxyNode(name: name, type: "vmess", server: server, port: port)
        return (node, yaml)
    }

    // MARK: - Trojan Parser

    private static func parseTrojanURI(_ uri: String, seenNames: inout [String: Int]) -> (ProxyNode, String)? {
        // trojan://password@server:port?params#name
        guard let hashIdx = uri.lastIndex(of: "#") else { return nil }
        let rawName = String(uri[uri.index(after: hashIdx)...])
            .removingPercentEncoding ?? String(uri[uri.index(after: hashIdx)...])
        let beforeHash = String(uri[..<hashIdx])

        guard let schemeEnd = beforeHash.range(of: "://") else { return nil }
        let afterScheme = String(beforeHash[schemeEnd.upperBound...])

        let queryParts = afterScheme.components(separatedBy: "?")
        let userHost = queryParts[0]
        let queryString = queryParts.count > 1 ? queryParts[1] : ""
        let params = parseQueryString(queryString)

        guard let atIdx = userHost.lastIndex(of: "@") else { return nil }
        let password = String(userHost[..<atIdx]).removingPercentEncoding ?? String(userHost[..<atIdx])
        let hostPort = String(userHost[userHost.index(after: atIdx)...])
        guard let colonIdx = hostPort.lastIndex(of: ":") else { return nil }
        let server = String(hostPort[..<colonIdx])
        guard let port = Int(hostPort[hostPort.index(after: colonIdx)...]) else { return nil }

        let name = uniqueName(rawName, seenNames: &seenNames)
        let escapedName = yamlEscape(name)

        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    type: trojan\n"
        yaml += "    server: \(server)\n"
        yaml += "    port: \(port)\n"
        yaml += "    password: \"\(yamlEscape(password))\"\n"
        yaml += "    udp: true\n"

        if let sni = params["sni"] { yaml += "    sni: \(sni)\n" }
        if let fp = params["fp"] { yaml += "    client-fingerprint: \(fp)\n" }

        let network = params["type"] ?? "tcp"
        if network == "ws" {
            yaml += "    network: ws\n"
            yaml += "    ws-opts:\n"
            if let path = params["path"]?.removingPercentEncoding {
                yaml += "      path: \"\(yamlEscape(path))\"\n"
            }
            if let host = params["host"] {
                yaml += "      headers:\n"
                yaml += "        Host: \(host)\n"
            }
        } else if network == "grpc" {
            yaml += "    network: grpc\n"
            if let serviceName = params["serviceName"] {
                yaml += "    grpc-opts:\n"
                yaml += "      grpc-service-name: \(serviceName)\n"
            }
        }

        let node = ProxyNode(name: name, type: "trojan", server: server, port: port)
        return (node, yaml)
    }

    // MARK: - Shadowsocks Parser

    private static func parseShadowsocksURI(_ uri: String, seenNames: inout [String: Int]) -> (ProxyNode, String)? {
        // ss://base64(method:password)@server:port#name
        // or ss://base64(method:password@server:port)#name (SIP002)
        guard let schemeEnd = uri.range(of: "://") else { return nil }
        var rest = String(uri[schemeEnd.upperBound...])

        // Extract fragment (name)
        let rawName: String
        if let hashIdx = rest.lastIndex(of: "#") {
            rawName = (String(rest[rest.index(after: hashIdx)...]).removingPercentEncoding) ?? ""
            rest = String(rest[..<hashIdx])
        } else {
            rawName = ""
        }

        var method: String
        var password: String
        var server: String
        var port: Int

        if rest.contains("@") {
            // SIP002: base64(method:password)@server:port or method:password@server:port
            let parts = rest.components(separatedBy: "@")
            let userInfo = parts[0]
            let hostPort = parts[1].components(separatedBy: "?")[0] // strip query

            // Decode userInfo if base64
            let decoded: String
            if let data = Data(base64Encoded: userInfo, options: .ignoreUnknownCharacters),
               let d = String(data: data, encoding: .utf8) {
                decoded = d
            } else {
                decoded = userInfo
            }

            guard let colonIdx = decoded.firstIndex(of: ":") else { return nil }
            method = String(decoded[..<colonIdx])
            password = String(decoded[decoded.index(after: colonIdx)...])

            guard let portColonIdx = hostPort.lastIndex(of: ":") else { return nil }
            server = String(hostPort[..<portColonIdx])
            guard let p = Int(hostPort[hostPort.index(after: portColonIdx)...]) else { return nil }
            port = p
        } else {
            // Legacy: ss://base64(method:password@server:port)
            guard let data = Data(base64Encoded: rest, options: .ignoreUnknownCharacters),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            guard let atIdx = decoded.lastIndex(of: "@") else { return nil }
            let userInfo = String(decoded[..<atIdx])
            let hostPort = String(decoded[decoded.index(after: atIdx)...])
            guard let colonIdx = userInfo.firstIndex(of: ":") else { return nil }
            method = String(userInfo[..<colonIdx])
            password = String(userInfo[userInfo.index(after: colonIdx)...])
            guard let portColonIdx = hostPort.lastIndex(of: ":") else { return nil }
            server = String(hostPort[..<portColonIdx])
            guard let p = Int(hostPort[hostPort.index(after: portColonIdx)...]) else { return nil }
            port = p
        }

        let finalName = rawName.isEmpty ? "\(server):\(port)" : rawName
        let name = uniqueName(finalName, seenNames: &seenNames)
        let escapedName = yamlEscape(name)

        var yaml = "  - name: \"\(escapedName)\"\n"
        yaml += "    type: ss\n"
        yaml += "    server: \(server)\n"
        yaml += "    port: \(port)\n"
        yaml += "    cipher: \(method)\n"
        yaml += "    password: \"\(yamlEscape(password))\"\n"
        yaml += "    udp: true\n"

        let node = ProxyNode(name: name, type: "ss", server: server, port: port)
        return (node, yaml)
    }

    // MARK: - Query String Helper

    private static func parseQueryString(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            result[kv[0]] = kv[1]
        }
        return result
    }
}
