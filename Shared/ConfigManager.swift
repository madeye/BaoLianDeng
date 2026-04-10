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

import Foundation
import MihomoCore
import os
import Yams

final class ConfigManager {
    static let shared = ConfigManager()

    private let fileManager = FileManager.default

    static let geodataFiles: [(name: String, ext: String, url: String)] = [
        ("geoip", "metadb", "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb"),
        ("geosite", "dat", "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat"),
    ]

    private init() {}

    var configDirectoryURL: URL? {
        guard let containerPath = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return containerPath.appendingPathComponent("BaoLianDeng/mihomo", isDirectory: true)
    }

    var configFileURL: URL? {
        configDirectoryURL?.appendingPathComponent(AppConstants.configFileName)
    }

    func ensureConfigDirectory() throws {
        guard let dirURL = configDirectoryURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        if !fileManager.fileExists(atPath: dirURL.path) {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
    }

    /// Ensure geodata files (geoip.metadb, geosite.dat) exist in the given directory.
    /// Tries the app bundle first, then downloads from jsDelivr.
    func ensureGeodataFiles(configDir: String) {
        for file in Self.geodataFiles {
            let filename = "\(file.name).\(file.ext)"
            let dest = (configDir as NSString).appendingPathComponent(filename)
            guard !fileManager.fileExists(atPath: dest) else { continue }

            // Try bundled copy first
            if let src = Bundle.main.path(forResource: file.name, ofType: file.ext) {
                do {
                    try fileManager.copyItem(atPath: src, toPath: dest)
                    AppLogger.config.notice("Copied bundled \(filename) to config dir")
                    continue
                } catch {
                    AppLogger.config.warning("Failed to copy bundled \(filename): \(error.localizedDescription)")
                }
            }

            // Fall back to downloading from jsDelivr
            AppLogger.config.notice("Downloading \(filename) from jsDelivr...")
            guard let url = URL(string: file.url) else { continue }

            let semaphore = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                defer { semaphore.signal() }
                if let error = error {
                    AppLogger.config.warning("Failed to download \(filename): \(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    AppLogger.config.warning("Bad response downloading \(filename)")
                    return
                }
                do {
                    try data.write(to: URL(fileURLWithPath: dest))
                    AppLogger.config.notice("Downloaded \(filename) (\(data.count) bytes)")
                } catch {
                    AppLogger.config.warning("Failed to write \(filename): \(error.localizedDescription)")
                }
            }
            task.resume()
            semaphore.wait()
        }
    }

    func saveConfig(_ yaml: String) throws {
        try ensureConfigDirectory()
        guard let fileURL = configFileURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func loadConfig() throws -> String {
        guard let fileURL = configFileURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func configExists() -> Bool {
        guard let fileURL = configFileURL else { return false }
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Save the desired mode to UserDefaults. The tunnel reads this on startup.
    func setMode(_ mode: String) {
        AppConstants.sharedDefaults.set(mode, forKey: "proxyMode")
    }

    /// Apply the saved log level to config.yaml so Mihomo's engine uses it on startup.
    func applyLogLevel() {
        let level = AppConstants.sharedDefaults
            .string(forKey: "logLevel") ?? "info"
        guard var config = try? loadConfig() else { return }
        let levels = ["debug", "info", "warning", "error", "silent"]
        for l in levels {
            config = config.replacingOccurrences(of: "log-level: \(l)", with: "log-level: \(level)")
        }
        try? saveConfig(config)
    }

    /// Apply the saved mode to config.yaml. Call after applySelectedSubscription/sanitizeConfig.
    func applyMode() {
        let mode = AppConstants.sharedDefaults
            .string(forKey: "proxyMode") ?? "rule"
        guard var config = try? loadConfig() else { return }
        let modes = ["rule", "global", "direct"]
        for m in modes {
            config = config.replacingOccurrences(of: "mode: \(m)", with: "mode: \(mode)")
        }
        config = updateGlobalProxyGroup(config, enabled: mode == "global")
        try? saveConfig(config)
    }

    /// Return all proxy group names with type "select" from config.yaml.
    func selectProxyGroupNames() -> [String] {
        guard let yaml = try? loadConfig() else { return [] }
        return parseProxyGroups(from: yaml)
            .filter { $0.type == "select" }
            .map(\.name)
    }

    /// Update every select-type proxy group to put the user's selected node first
    /// — except groups whose existing default (first listed proxy) is a bypass
    /// member (`DIRECT`, `REJECT`, or a nested group that resolves to those).
    /// Those are treated as bypass / blocklist groups (e.g. CN-direct categories
    /// or ad-blockers) and left untouched. The selected node is only injected
    /// into groups that already list it as a member, so we never invent
    /// membership the user didn't grant.
    func applySelectedNode() {
        let defaults = AppConstants.sharedDefaults
        guard let selectedNode = defaults.string(forKey: "selectedNode"), !selectedNode.isEmpty else {
            return
        }
        guard var yaml = try? loadConfig() else { return }

        var groups = parseProxyGroups(from: yaml)
        let groupMembers = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.proxies) })
        var changed = false
        for i in groups.indices where groups[i].type == "select" {
            var members = groups[i].proxies
            // Skip bypass groups: the first listed proxy resolves to DIRECT or
            // REJECT (directly or via a nested group), meaning the group is
            // configured to bypass the proxy by default.
            guard let first = members.first else { continue }
            if isBypassGroup(firstMember: first, groupMembers: groupMembers) { continue }

            let promoted: String
            if members.contains(selectedNode) {
                // Explicit user choice wins: move the selected node to index 0.
                promoted = selectedNode
            } else if let bypass = firstBypassMember(in: members, groupMembers: groupMembers) {
                // Group exposes a Direct/REJECT option but the user's selected
                // node isn't a member. The subscription author listed the
                // bypass entry for a reason (CN-direct category, ad-block, …),
                // so prefer it over mihomo's "first listed proxy wins" default.
                promoted = bypass
            } else {
                continue
            }

            // Move the promoted member to index 0 so SelectorGroup defaults to
            // it, but keep all other members so the user can still switch at
            // runtime.
            members.removeAll { $0 == promoted }
            members.insert(promoted, at: 0)
            groups[i].proxies = members
            changed = true
        }
        guard changed else { return }

        yaml = updateProxyGroups(groups, in: yaml)
        try? saveConfig(yaml)
    }

    /// Add or remove a GLOBAL proxy group with the selected node.
    /// Mihomo's `mode: global` routes all traffic through the built-in GLOBAL selector,
    /// so we need to define it with the user's selected proxy node.
    func updateGlobalProxyGroup(_ yaml: String, enabled: Bool) -> String {
        // First, strip any existing GLOBAL group
        var lines = yaml.components(separatedBy: "\n")
        if let pgIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy-groups:")
        }) {
            var i = pgIdx + 1
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed == "- name: GLOBAL" {
                    // Remove this group entry until the next group or end of section
                    let start = i
                    i += 1
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        let isTopLevel = !lines[i].hasPrefix(" ") && !lines[i].hasPrefix("\t") && !t.isEmpty
                        if isTopLevel || t.hasPrefix("- name:") { break }
                        i += 1
                    }
                    lines.removeSubrange(start..<i)
                    break
                }
                let isTopLevel = !lines[i].hasPrefix(" ") && !lines[i].hasPrefix("\t") && !trimmed.isEmpty
                if isTopLevel { break }
                i += 1
            }
        }

        guard enabled else { return lines.joined(separator: "\n") }

        // Read selected node from shared UserDefaults
        let defaults = AppConstants.sharedDefaults
        let selectedNode = defaults.string(forKey: "selectedNode")

        // Find proxy-groups: line and insert GLOBAL group right after it
        guard let pgIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy-groups:")
        }) else { return lines.joined(separator: "\n") }

        var globalGroup = [
            "  - name: GLOBAL",
            "    type: select",
            "    proxies:",
        ]
        if let node = selectedNode, !node.isEmpty {
            globalGroup.append("      - \(node)")
        } else {
            globalGroup.append("      - DIRECT")
        }

        lines.insert(contentsOf: globalGroup, at: pgIdx + 1)
        return lines.joined(separator: "\n")
    }

    /// Patch the on-disk config.yaml to disable geo data downloads, which would
    /// block the Network Extension during startup. Safe to call on every launch.
    func sanitizeConfig() {
        guard let yaml = try? loadConfig() else { return }
        var lines = yaml.components(separatedBy: "\n")
        var hasGeoAutoUpdate = false

        var inTunBlock = false
        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Track top-level block transitions
            if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTunBlock = trimmed.hasPrefix("tun:")
            }
            // Disable TUN mode — transparent proxy intercepts at socket level, no TUN needed
            if inTunBlock && trimmed.hasPrefix("enable:") {
                return line.replacingOccurrences(of: "enable: true", with: "enable: false")
            }
            // Disable automatic geo database updates
            if trimmed.hasPrefix("geo-auto-update:") {
                hasGeoAutoUpdate = true
                return line.replacingOccurrences(of: "geo-auto-update: true", with: "geo-auto-update: false")
            }
            return line
        }

        // Inject geo-auto-update: false after the tun block if not already present
        if !hasGeoAutoUpdate {
            if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("dns:") }) {
                lines.insert("geo-auto-update: false", at: idx)
                lines.insert("", at: idx)
            }
        }

        // Remove subscriptions: section — mihomo's built-in subscription refresh
        // replaces only the proxies list, breaking proxy-group member references.
        var result = lines.joined(separator: "\n")
        Self.stripSubscriptionsSection(&result)
        try? saveConfig(result)
    }

    /// Sanitize a config string in-place (same rules as sanitizeConfig but on a String).
    static func sanitizeConfigString(_ config: inout String) {
        config = config
            .replacingOccurrences(of: "geo-auto-update: true", with: "geo-auto-update: false")
        // Disable TUN — transparent proxy intercepts at socket level.
        var lines = config.components(separatedBy: "\n")
        var inTunBlock = false
        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTunBlock = trimmed.hasPrefix("tun:")
            }
            if inTunBlock && trimmed.hasPrefix("enable:") {
                return line.replacingOccurrences(of: "enable: true", with: "enable: false")
            }
            return line
        }
        config = lines.joined(separator: "\n")
        stripSubscriptionsSection(&config)
    }

    /// Remove the top-level `subscriptions:` section from a config string.
    /// Mihomo's built-in subscription refresh replaces only the proxies list,
    /// breaking proxy-group member references. We handle refresh in the app instead.
    static func stripSubscriptionsSection(_ config: inout String) {
        let lines = config.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("subscriptions:")
                && !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
        }) else { return }
        // Find end: next top-level key or end of file
        var end = lines.count
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                end = i
                break
            }
        }
        var filtered = Array(lines[0..<start])
        filtered.append(contentsOf: lines[end...])
        config = filtered.joined(separator: "\n")
    }

    /// Merge a Clash subscription YAML into our base config.
    /// Keeps our DNS/port settings and local rules; takes only proxies and proxy-groups from the subscription.
    /// Returns the merged YAML so callers can push it via REST API without re-reading the file.
    @discardableResult
    func applySubscriptionConfig(_ subscriptionYAML: String) throws -> String {
        let merged = mergeSubscription(subscriptionYAML)
        try saveConfig(merged)
        return merged
    }

    /// Re-apply the currently selected subscription's config from shared UserDefaults.
    /// Safe to call from the Network Extension — reads the subscription list stored by the main app,
    /// finds the selected one, and merges its rawContent into config.yaml.
    /// Returns true if a subscription was applied, false if none selected or no rawContent.
    @discardableResult
    func applySelectedSubscription() -> Bool {
        let defaults = AppConstants.sharedDefaults
        guard let idString = defaults.string(forKey: "selectedSubscriptionID"),
              let data = defaults.data(forKey: "subscriptions") else {
            return false
        }
        // Decode just the fields we need — avoids coupling to the full Subscription type
        struct Sub: Decodable {
            var id: UUID
            var rawContent: String?
        }
        guard let subs = try? JSONDecoder().decode([Sub].self, from: data),
              let selectedID = UUID(uuidString: idString),
              let selected = subs.first(where: { $0.id == selectedID }),
              let raw = selected.rawContent else {
            return false
        }
        do {
            try applySubscriptionConfig(raw)
            return true
        } catch {
            return false
        }
    }

    /// Validate a subscription YAML by merging it with the base config and running Mihomo's parser.
    /// Returns nil if valid, or an error message string if invalid.
    func validateSubscriptionConfig(_ yaml: String) -> String? {
        let merged = mergeSubscription(yaml)
        AppLogger.config.notice("merged config length: \(merged.count), preview: \(String(merged.prefix(300)), privacy: .public)")

        // Mihomo's config.Parse needs HomeDir set so it can find geodata files
        // (geoip.metadb, geosite.dat) when validating GEOIP/GEOSITE rules.
        if let dir = configDirectoryURL?.path {
            ensureGeodataFiles(configDir: dir)
            BridgeSetHomeDir(dir)
        }

        var err: NSError?
        BridgeValidateConfig(merged, &err)
        if let err = err {
            AppLogger.config.error("BridgeValidateConfig error: \(err.localizedDescription, privacy: .public)")
        } else {
            AppLogger.config.notice("BridgeValidateConfig: OK")
        }
        return err?.localizedDescription
    }

    /// Merge subscription YAML: take proxies, proxy-groups, rules, and their providers from subscription.
    private func mergeSubscription(_ yaml: String) -> String {
        let base = (try? loadConfig()) ?? defaultConfig()
        return ConfigManager.mergeSubscription(yaml, baseConfig: base, defaultConfig: defaultConfig())
    }

    /// Pure merge logic — takes all inputs as parameters for testability.
    /// Keeps the header (ports, DNS settings) from the base config.
    /// Overwrites proxies, proxy-groups, rules, and providers directly from subscription
    /// (raw pass-through to preserve all fields mihomo needs).
    static func mergeSubscription(_ yaml: String, baseConfig: String, defaultConfig: String) -> String {
        // 1. Extract raw sections from subscription (preserves exact formatting)
        let sub = extractYAMLSections(from: yaml, named: ["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers"])

        // 2. Header from base config (everything before proxies:) preserves user edits to ports, DNS, etc.
        let baseLines = baseConfig.components(separatedBy: "\n")
        let proxiesCut = baseLines.firstIndex(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("proxies:") }) ?? baseLines.count
        let header = baseLines[0..<proxiesCut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // 3. Build merged config — pass through raw sections from subscription
        var result = header

        result += "\n\n" + (sub["proxies"] ?? "proxies: []")
        result += "\n\n" + (sub["proxy-groups"] ?? "proxy-groups: []")

        if let pp = sub["proxy-providers"] { result += "\n\n" + Self.disableProviderRefresh(pp) }
        if let rp = sub["rule-providers"] { result += "\n\n" + Self.disableProviderRefresh(rp) }

        let defaultRules = extractYAMLSections(from: defaultConfig, named: ["rules"])
        result += "\n\n" + (sub["rules"] ?? defaultRules["rules"] ?? "rules:\n  - MATCH,DIRECT")

        return result
    }

    /// Set interval to 0 in provider sections so Mihomo won't auto-refresh subscription URLs.
    static func disableProviderRefresh(_ section: String) -> String {
        section.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interval:") {
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                return indent + "interval: 0"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Extract top-level YAML sections by name.
    static func extractYAMLSections(from yaml: String, named wanted: [String]) -> [String: String] {
        var extracted: [String: String] = [:]
        var currentKey: String?
        var currentLines: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            extracted[key] = currentLines.joined(separator: "\n")
        }

        let normalized = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalized.components(separatedBy: "\n") {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.isEmpty && !line.hasPrefix("-") && !line.hasPrefix("#")
            if isTopLevel {
                flush()
                let key = String(line.prefix(while: { $0 != ":" }))
                    .trimmingCharacters(in: .whitespaces)
                currentKey = wanted.contains(key) ? key : nil
                currentLines = [line]
            } else if currentKey != nil {
                currentLines.append(line)
            }
        }
        flush()
        return extracted
    }

    /// Extract all proxy node names from a Yams-parsed proxies array.
    static func extractProxyNames(from proxies: [[String: Any]]) -> [String] {
        proxies.compactMap { $0["name"] as? String }
    }

    func defaultConfig() -> String {
        return """
        mixed-port: 7890
        mode: rule
        log-level: info
        allow-lan: false
        external-controller: \(AppConstants.externalControllerAddr)

        geo-auto-update: false

        dns:
          enable: true
          listen: 127.0.0.1:1053
          enhanced-mode: redir-host
          nameserver:
            - 114.114.114.114
            - 223.5.5.5

        proxies: []

        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT

        rules:
          # Google
          - DOMAIN-SUFFIX,google.com,PROXY
          - DOMAIN-SUFFIX,google.com.hk,PROXY
          - DOMAIN-SUFFIX,googleapis.com,PROXY
          - DOMAIN-SUFFIX,googlevideo.com,PROXY
          - DOMAIN-SUFFIX,gstatic.com,PROXY
          - DOMAIN-SUFFIX,ggpht.com,PROXY
          - DOMAIN-SUFFIX,googleusercontent.com,PROXY
          - DOMAIN-SUFFIX,gmail.com,PROXY
          # YouTube
          - DOMAIN-SUFFIX,youtube.com,PROXY
          - DOMAIN-SUFFIX,ytimg.com,PROXY
          - DOMAIN-SUFFIX,youtu.be,PROXY
          # Twitter / X
          - DOMAIN-SUFFIX,twitter.com,PROXY
          - DOMAIN-SUFFIX,x.com,PROXY
          - DOMAIN-SUFFIX,twimg.com,PROXY
          - DOMAIN-SUFFIX,t.co,PROXY
          # Telegram
          - DOMAIN-SUFFIX,telegram.org,PROXY
          - DOMAIN-SUFFIX,t.me,PROXY
          - IP-CIDR,91.108.0.0/16,PROXY,no-resolve
          - IP-CIDR,149.154.0.0/16,PROXY,no-resolve
          # Meta
          - DOMAIN-SUFFIX,facebook.com,PROXY
          - DOMAIN-SUFFIX,fbcdn.net,PROXY
          - DOMAIN-SUFFIX,instagram.com,PROXY
          - DOMAIN-SUFFIX,whatsapp.com,PROXY
          - DOMAIN-SUFFIX,whatsapp.net,PROXY
          # GitHub
          - DOMAIN-SUFFIX,github.com,PROXY
          - DOMAIN-SUFFIX,githubusercontent.com,PROXY
          - DOMAIN-SUFFIX,github.io,PROXY
          # Wikipedia / Reddit
          - DOMAIN-SUFFIX,wikipedia.org,PROXY
          - DOMAIN-SUFFIX,reddit.com,PROXY
          - DOMAIN-SUFFIX,redd.it,PROXY
          # AI services
          - DOMAIN-SUFFIX,openai.com,PROXY
          - DOMAIN-SUFFIX,anthropic.com,PROXY
          - DOMAIN-SUFFIX,claude.ai,PROXY
          - DOMAIN-SUFFIX,chatgpt.com,PROXY
          # CDN / Media
          - DOMAIN-SUFFIX,amazonaws.com,PROXY
          - DOMAIN-SUFFIX,cloudfront.net,PROXY
          # Apple (direct in China)
          - DOMAIN-SUFFIX,apple.com,DIRECT
          - DOMAIN-SUFFIX,icloud.com,DIRECT
          - DOMAIN-SUFFIX,icloud-content.com,DIRECT
          # China direct
          - DOMAIN-SUFFIX,cn,DIRECT
          - DOMAIN-SUFFIX,baidu.com,DIRECT
          - DOMAIN-SUFFIX,qq.com,DIRECT
          - DOMAIN-SUFFIX,taobao.com,DIRECT
          - DOMAIN-SUFFIX,jd.com,DIRECT
          - DOMAIN-SUFFIX,bilibili.com,DIRECT
          - DOMAIN-SUFFIX,zhihu.com,DIRECT
          # LAN
          - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
          - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
          - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
          # GeoIP China
          - GEOIP,CN,DIRECT
          # Catch-all
          - MATCH,PROXY
        """
    }
}

// MARK: - Editable Config Models

struct EditableProxyGroup: Identifiable {
    var id = UUID()
    var name: String
    var type: String
    var proxies: [String]
    var url: String?
    var interval: Int?
}

struct EditableRule: Identifiable {
    var id = UUID()
    var type: String
    var value: String
    var target: String
    var noResolve: Bool
}

// MARK: - Config Parsing & Update

extension ConfigManager {

    func parseProxyGroups(from yaml: String) -> [EditableProxyGroup] {
        guard let dict = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let groupList = dict["proxy-groups"] as? [[String: Any]] else {
            return []
        }
        return groupList.compactMap { group -> EditableProxyGroup? in
            guard let name = group["name"] as? String,
                  let type = group["type"] as? String else { return nil }
            let proxies = group["proxies"] as? [String] ?? []
            let url = group["url"] as? String
            let interval = group["interval"] as? Int
            return EditableProxyGroup(name: name, type: type, proxies: proxies, url: url, interval: interval)
        }
    }

    func parseRules(from yaml: String) -> [EditableRule] {
        guard let dict = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let ruleStrings = dict["rules"] as? [String] else {
            return []
        }
        var rules: [EditableRule] = []
        for ruleStr in ruleStrings {
            let parts = ruleStr.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }
            let ruleType = parts[0].trimmingCharacters(in: .whitespaces)
            if ruleType == "MATCH" {
                rules.append(EditableRule(type: ruleType, value: "", target: parts[1].trimmingCharacters(in: .whitespaces), noResolve: false))
            } else if parts.count >= 3 {
                let noResolve = parts.count >= 4 && parts[3].trimmingCharacters(in: .whitespaces) == "no-resolve"
                rules.append(EditableRule(
                    type: ruleType,
                    value: parts[1].trimmingCharacters(in: .whitespaces),
                    target: parts[2].trimmingCharacters(in: .whitespaces),
                    noResolve: noResolve
                ))
            }
        }
        return rules
    }

    func updateProxyGroups(_ groups: [EditableProxyGroup], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let startIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("proxy-groups:") && !t.hasPrefix("#")
        }) else {
            let insertIdx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("rules:")
            }) ?? lines.count
            var newLines = serializeProxyGroups(groups)
            newLines.append("")
            lines.insert(contentsOf: newLines, at: insertIdx)
            return lines.joined(separator: "\n")
        }

        var endIdx = startIdx + 1
        while endIdx < lines.count {
            let line = lines[endIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                break
            }
            endIdx += 1
        }

        var newLines = serializeProxyGroups(groups)
        newLines.append("")
        lines.replaceSubrange(startIdx..<endIdx, with: newLines)
        return lines.joined(separator: "\n")
    }

    func updateRules(_ rules: [EditableRule], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let startIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("rules:") && !t.hasPrefix("#")
        }) else {
            lines.append(contentsOf: serializeRules(rules))
            return lines.joined(separator: "\n")
        }

        var endIdx = startIdx + 1
        while endIdx < lines.count {
            let line = lines[endIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty
                && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#") && line.contains(":") {
                break
            }
            endIdx += 1
        }

        let newLines = serializeRules(rules)
        lines.replaceSubrange(startIdx..<endIdx, with: newLines)
        return lines.joined(separator: "\n")
    }

    private func serializeProxyGroups(_ groups: [EditableProxyGroup]) -> [String] {
        if groups.isEmpty { return ["proxy-groups: []"] }
        var result = ["proxy-groups:"]
        for group in groups {
            result.append("  - name: \(group.name)")
            result.append("    type: \(group.type)")
            if let url = group.url, !url.isEmpty {
                result.append("    url: \(url)")
            }
            if let interval = group.interval {
                result.append("    interval: \(interval)")
            }
            if group.proxies.isEmpty {
                result.append("    proxies: []")
            } else {
                result.append("    proxies:")
                for proxy in group.proxies {
                    result.append("      - \(proxy)")
                }
            }
        }
        return result
    }

    private func serializeRules(_ rules: [EditableRule]) -> [String] {
        if rules.isEmpty { return ["rules: []"] }
        var result = ["rules:"]
        for rule in rules {
            if rule.type == "MATCH" {
                result.append("  - MATCH,\(rule.target)")
            } else {
                var line = "  - \(rule.type),\(rule.value),\(rule.target)"
                if rule.noResolve { line += ",no-resolve" }
                result.append(line)
            }
        }
        return result
    }

    private func stripQuotes(_ s: String) -> String {
        if s.count >= 2 &&
            ((s.hasPrefix("\"") && s.hasSuffix("\"")) ||
             (s.hasPrefix("'") && s.hasSuffix("'"))) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Returns true if `name` refers to `DIRECT`, `REJECT`, or a proxy group
/// whose members are all (recursively) bypass members. Used to detect
/// bypass / blocklist groups so we don't inject the user's selected node
/// into them. `groupMembers` maps group name → its ordered members list.
func isBypassMember(
    _ name: String,
    groupMembers: [String: [String]],
    seen: inout Set<String>
) -> Bool {
    if name == "DIRECT" || name == "REJECT" { return true }
    guard let members = groupMembers[name] else { return false } // real proxy
    if !seen.insert(name).inserted { return false }              // cycle guard
    guard !members.isEmpty else { return false }
    return members.allSatisfy { isBypassMember($0, groupMembers: groupMembers, seen: &seen) }
}

/// Returns true if a group whose first listed member is `firstMember`
/// should be treated as a bypass group and skipped when injecting the
/// user's selected node. The first member is the group's default
/// selection in mihomo, so we key the decision off it.
func isBypassGroup(firstMember: String, groupMembers: [String: [String]]) -> Bool {
    var seen: Set<String> = []
    return isBypassMember(firstMember, groupMembers: groupMembers, seen: &seen)
}

/// Returns true if `name` is `DIRECT`/`REJECT`, or refers to a proxy group
/// whose runtime default (its first listed member) is itself first-default
/// bypass. Models mihomo's actual routing: a `type: select` group's active
/// selection is the first listed member until the user changes it, so a
/// group like `🎯Direct: [DIRECT, Proxies]` defaults to `DIRECT` even
/// though it isn't all-members-bypass.
func isFirstDefaultBypass(
    _ name: String,
    groupMembers: [String: [String]],
    seen: inout Set<String>
) -> Bool {
    if name == "DIRECT" || name == "REJECT" { return true }
    guard let members = groupMembers[name] else { return false } // real proxy
    if !seen.insert(name).inserted { return false }              // cycle guard
    guard let first = members.first else { return false }
    return isFirstDefaultBypass(first, groupMembers: groupMembers, seen: &seen)
}

/// Return the first member of `members` whose mihomo runtime default
/// resolves to DIRECT/REJECT, or nil if none. Used to promote a
/// direct-like option when the user's selected node is not a member of
/// this group — matches the subscription author's intent that "this group
/// exposes a Direct option because it's meant to bypass".
func firstBypassMember(
    in members: [String],
    groupMembers: [String: [String]]
) -> String? {
    for member in members {
        var seen: Set<String> = []
        if isFirstDefaultBypass(member, groupMembers: groupMembers, seen: &seen) {
            return member
        }
    }
    return nil
}

enum ConfigError: LocalizedError {
    case sharedContainerUnavailable
    case configNotFound

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            return "App Group shared container is not available"
        case .configNotFound:
            return "Configuration file not found"
        }
    }
}
