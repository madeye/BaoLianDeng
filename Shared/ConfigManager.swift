// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import MihomoCore
import os
import Yams

final class ConfigManager {
    static let shared = ConfigManager()

    private let fileManager = FileManager.default

    // GEOIP needs GeoLite2-Country schema (country.mmdb) — the meow-rs engine
    // reads country/iso_code records; mihomo's geoip.metadb (Meta-geoip0
    // schema) opens fine but matches nothing.
    static let geodataFiles: [(name: String, ext: String, url: String)] = [
        ("Country", "mmdb", "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"),
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

    /// Sanity threshold (bytes) a downloaded geodata file must exceed to be
    /// considered valid rather than truncated. Country.mmdb/geosite.dat are
    /// both well over 1MB in practice; 1KB just rules out empty/truncated
    /// responses (e.g. an error page or a connection cut mid-transfer).
    private static let minGeodataFileSize = 1024

    /// Ensure geodata files (Country.mmdb, geosite.dat) exist in the given directory.
    /// Tries the app bundle first, then downloads from jsDelivr.
    func ensureGeodataFiles(configDir: String) {
        // Bound how long a stalled/slow download can block this call — it
        // runs synchronously (semaphore-gated) on the tunnel startup path.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForResource = 15
        let session = URLSession(configuration: sessionConfig)

        for file in Self.geodataFiles {
            let filename = "\(file.name).\(file.ext)"
            let dest = (configDir as NSString).appendingPathComponent(filename)

            // Treat an existing-but-truncated file (e.g. left over from a
            // prior interrupted download) as absent so it gets replaced,
            // rather than being mistaken for a valid, already-present file.
            if let attrs = try? fileManager.attributesOfItem(atPath: dest),
               let size = attrs[.size] as? Int,
               size > Self.minGeodataFileSize {
                continue
            }

            // Try bundled copy first. In the main app, geodata is packaged
            // inside the embedded provider extension rather than as a top-level
            // app resource.
            if let src = Self.bundledGeodataURL(name: file.name, ext: file.ext)?.path {
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
            let task = session.dataTask(with: url) { data, response, error in
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
                guard data.count > Self.minGeodataFileSize else {
                    AppLogger.config.warning("Downloaded \(filename) looks truncated (\(data.count) bytes), discarding")
                    return
                }
                do {
                    try data.write(to: URL(fileURLWithPath: dest), options: .atomic)
                    AppLogger.config.notice("Downloaded \(filename) (\(data.count) bytes)")
                } catch {
                    AppLogger.config.warning("Failed to write \(filename): \(error.localizedDescription)")
                }
            }
            task.resume()
            semaphore.wait()
        }
    }

    static func bundledGeodataURL(name: String, ext: String, bundle: Bundle = .main) -> URL? {
        let fileManager = FileManager.default
        if let path = bundle.path(forResource: name, ofType: ext) {
            return URL(fileURLWithPath: path)
        }

        let filename = "\(name).\(ext)"
        var bundleDirs: [URL] = []
        if let plugInsURL = bundle.builtInPlugInsURL {
            bundleDirs.append(plugInsURL)
        }
        bundleDirs.append(
            bundle.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("SystemExtensions", isDirectory: true)
        )

        for dir in bundleDirs {
            guard let children = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                let resourceURL = child
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(filename)
                if fileManager.fileExists(atPath: resourceURL.path) {
                    return resourceURL
                }

                let flatURL = child.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: flatURL.path) {
                    return flatURL
                }
            }
        }

        return nil
    }

    /// The single writer of config.yaml. Always runs `sanitizeConfigString`
    /// so raw-editor and subscription-merge callers can't bypass the TUN /
    /// geo-auto-update / subscriptions-section invariants by writing
    /// directly — sanitization is idempotent, so re-sanitizing an
    /// already-sanitized config is a no-op. Also locks the file down to
    /// owner-only permissions since it can hold subscription-derived proxy
    /// credentials.
    func saveConfig(_ yaml: String) throws {
        try ensureConfigDirectory()
        guard let fileURL = configFileURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        var content = yaml
        Self.sanitizeConfigString(&content)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
        config = Self.replacingTopLevelScalar(in: config, key: "log-level", value: level)
        try? saveConfig(config)
    }

    /// Apply the saved mode to config.yaml. Call after applySelectedSubscription/sanitizeConfig.
    func applyMode() {
        let mode = AppConstants.sharedDefaults
            .string(forKey: "proxyMode") ?? "rule"
        guard var config = try? loadConfig() else { return }
        config = Self.replacingTopLevelScalar(in: config, key: "mode", value: mode)
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
                if trimmed == "- name: GLOBAL" || trimmed == "- name: \"GLOBAL\"" {
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
            "  - name: \(Self.yamlQuotedString("GLOBAL"))",
            "    type: select",
            "    proxies:",
        ]
        if let node = selectedNode, !node.isEmpty {
            globalGroup.append("      - \(Self.yamlQuotedString(node))")
        } else {
            globalGroup.append("      - DIRECT")
        }

        lines.insert(contentsOf: globalGroup, at: pgIdx + 1)
        return lines.joined(separator: "\n")
    }

    /// If `trimmed` (an already-whitespace-trimmed line) sets `key:` to a
    /// truthy `true` value, returns its trailing whitespace/comment suffix
    /// (possibly empty) so the caller can preserve it when rewriting the
    /// line. Returns nil if the line doesn't set `key` to `true`.
    /// Tolerates extra internal whitespace, optional single/double quoting
    /// around the value, and a trailing comment — e.g. `enable:true`,
    /// `enable:   true`, `enable: "true"`, `enable: 'true'  # note`.
    /// A plain substring match on `"\(key): true"` misses the whitespace/
    /// quoting variants, which would let a subscription-supplied config
    /// re-enable TUN despite the sanitizer running.
    private static func truthySuffix(_ trimmed: String, key: String) -> String? {
        let pattern = "^\(NSRegularExpression.escapedPattern(for: key)):\\s*(?:\"true\"|'true'|true)(\\s*(?:#.*)?)$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let suffixRange = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[suffixRange])
    }

    /// Rewrites `line`'s `key:` value to `newValue`, preserving the line's
    /// original indentation and any trailing comment.
    private static func replacingScalarValue(_ line: String, key: String, newValue: String, suffix: String = "") -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return "\(indent)\(key): \(newValue)\(suffix)"
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
            if inTunBlock && trimmed.hasPrefix("enable:"), let suffix = Self.truthySuffix(trimmed, key: "enable") {
                return Self.replacingScalarValue(line, key: "enable", newValue: "false", suffix: suffix)
            }
            // Disable automatic geo database updates
            if trimmed.hasPrefix("geo-auto-update:") {
                hasGeoAutoUpdate = true
                if let suffix = Self.truthySuffix(trimmed, key: "geo-auto-update") {
                    return Self.replacingScalarValue(line, key: "geo-auto-update", newValue: "false", suffix: suffix)
                }
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
    /// Idempotent: re-running on an already-sanitized config is a no-op, since
    /// `saveConfig` calls this unconditionally on every write.
    static func sanitizeConfigString(_ config: inout String) {
        // Disable TUN and geo-auto-update — transparent proxy intercepts at
        // socket level, and geo downloads would block tunnel startup.
        var lines = config.components(separatedBy: "\n")
        var inTunBlock = false
        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                inTunBlock = trimmed.hasPrefix("tun:")
            }
            if inTunBlock && trimmed.hasPrefix("enable:"), let suffix = truthySuffix(trimmed, key: "enable") {
                return replacingScalarValue(line, key: "enable", newValue: "false", suffix: suffix)
            }
            if trimmed.hasPrefix("geo-auto-update:"), let suffix = truthySuffix(trimmed, key: "geo-auto-update") {
                return replacingScalarValue(line, key: "geo-auto-update", newValue: "false", suffix: suffix)
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

    static func replacingTopLevelScalar(in yaml: String, key: String, value: String) -> String {
        let normalized = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  trimmed.hasPrefix("\(key):") else {
                return line
            }
            return "\(key): \(value)"
        }
        return lines.joined(separator: "\n")
    }

    /// Merge a Clash subscription YAML into our base config.
    /// Keeps our DNS/port settings and local rules; takes only proxies and proxy-groups from the subscription.
    /// Returns the merged YAML so callers can inspect it without re-reading the file.
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

    /// Off-main wrapper for `validateSubscriptionConfig`. SwiftUI views are
    /// MainActor, so a plain `Task {}` in a view runs on the main thread —
    /// and validation is synchronous engine work plus (worst case) bounded
    /// geodata downloads in `ensureGeodataFiles`. Running it detached keeps
    /// the UI responsive during subscription updates (the 6.0 feedback hang:
    /// "更新配置文件无反应，只能强制退出").
    func validateSubscriptionConfigDetached(_ yaml: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            ConfigManager.shared.validateSubscriptionConfig(yaml)
        }.value
    }

    /// Validate a subscription YAML by merging it with the base config and running Mihomo's parser.
    /// Returns nil if valid, or an error message string if invalid.
    /// The bridge validates offline (provider sections are stripped in
    /// meow-ffi before parsing), so this never blocks on network fetches —
    /// but it can still take seconds; prefer `validateSubscriptionConfigDetached`
    /// from UI code.
    func validateSubscriptionConfig(_ yaml: String) -> String? {
        let merged = mergeSubscription(yaml)
        // Do not log config content here — it can contain plaintext proxy
        // passwords/UUIDs from the subscription's proxies section.
        AppLogger.config.notice("merged config length: \(merged.count)")

        // The engine needs HomeDir set so it can find geodata files
        // (Country.mmdb, geosite.dat) when validating GEOIP/GEOSITE rules.
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

        if let pp = sub["proxy-providers"] { result += "\n\n" + Self.disableProviderRefresh(Self.sanitizeProviders(pp)) }
        if let rp = sub["rule-providers"] { result += "\n\n" + Self.disableProviderRefresh(Self.sanitizeProviders(rp)) }

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

    /// Validate/sanitize subscription-controlled provider entries
    /// (proxy-providers / rule-providers) before they're merged into
    /// config.yaml. Subscriptions are untrusted input:
    ///  - a provider whose `url:` scheme isn't https is dropped entirely, so
    ///    a malicious subscription can't point mihomo at a `file://` path (
    ///    local file exfiltration) or a plaintext `http://` endpoint;
    ///  - a provider whose `path:` tries to escape the app's config
    ///    directory (contains `..`, or is an absolute/home-relative path)
    ///    has its path rewritten to a safe basename under the config dir
    ///    instead of being honored verbatim, so it can't be used to read or
    ///    overwrite arbitrary files on disk.
    /// This manipulates provider YAML as text (matching the rest of this
    /// file's line-based approach, not a parsed tree), so it only
    /// special-cases the `url:`/`path:` keys and otherwise passes provider
    /// blocks through untouched. Valid providers are preserved as-is.
    static func sanitizeProviders(_ section: String) -> String {
        var lines = section.components(separatedBy: "\n")
        guard lines.count > 1 else { return section }
        let header = lines.removeFirst()

        // The indentation of the first provider-name line (e.g. 2 spaces)
        // marks the start of each subsequent provider entry.
        guard let baseIndent = lines
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map({ line in line.prefix(while: { $0 == " " }).count })
        else {
            return section
        }

        func isBlockStart(_ line: String) -> Bool {
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return indent == baseIndent && !trimmed.isEmpty && trimmed.hasSuffix(":")
        }

        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if isBlockStart(line) {
                if !current.isEmpty { blocks.append(current) }
                current = [line]
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        let kept = blocks.compactMap { sanitizeProviderBlock($0) }
        guard !kept.isEmpty else { return header }
        return ([header] + kept.flatMap { $0 }).joined(separator: "\n")
    }

    /// Returns the (possibly rewritten) lines of a single provider block, or
    /// nil if the whole block should be dropped (non-https `url:`).
    private static func sanitizeProviderBlock(_ block: [String]) -> [String]? {
        var result: [String] = []
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("url:") {
                let value = scalarValue(afterKey: "url", in: line)
                guard value.lowercased().hasPrefix("https://") else { return nil }
                result.append(line)
                continue
            }
            if trimmed.hasPrefix("path:") {
                let value = scalarValue(afterKey: "path", in: line)
                if value.contains("..") || value.hasPrefix("/") || value.hasPrefix("~") {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    var safeName = (value as NSString).lastPathComponent
                        .replacingOccurrences(of: "..", with: "_")
                    if safeName.isEmpty || safeName == "/" {
                        safeName = "provider.yaml"
                    }
                    result.append("\(indent)path: \(yamlQuotedString(safeName))")
                    continue
                }
            }
            result.append(line)
        }
        return result
    }

    /// Extracts the scalar value of `key:` from a raw config line, matching
    /// `rewriteServerLine`'s indentation- and quote-aware parsing.
    private static func scalarValue(afterKey key: String, in line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("\(key):") else { return "" }
        let afterColon = rest.dropFirst("\(key):".count)
        let valueStart = afterColon.prefix { $0 == " " || $0 == "\t" }
        let valueAndComment = String(afterColon.dropFirst(valueStart.count))
        return parseYAMLScalarWithComment(valueAndComment).value
    }

    private static func yamlQuotedString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    static func rewriteProxyServerHostnames(
        in yaml: String,
        hostToIP: [String: String]
    ) -> String {
        guard !hostToIP.isEmpty else { return yaml }
        return yaml.components(separatedBy: "\n")
            .map { rewriteServerLine($0, hostToIP: hostToIP) }
            .joined(separator: "\n")
    }

    private static func rewriteServerLine(_ line: String, hostToIP: [String: String]) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("server:") else { return line }

        let afterColon = rest.dropFirst("server:".count)
        let valueStart = afterColon.prefix { $0 == " " || $0 == "\t" }
        let valueAndComment = String(afterColon.dropFirst(valueStart.count))
        guard !valueAndComment.isEmpty else { return line }

        let parsed = parseYAMLScalarWithComment(valueAndComment)
        guard let replacement = hostToIP[parsed.value] else { return line }

        let quotedReplacement: String
        switch parsed.quote {
        case "\"":
            quotedReplacement = yamlQuotedString(replacement)
        case "'":
            quotedReplacement = "'\(replacement.replacingOccurrences(of: "'", with: "''"))'"
        default:
            quotedReplacement = replacement
        }
        return "\(indent)server:\(valueStart)\(quotedReplacement)\(parsed.comment)"
    }

    private static func parseYAMLScalarWithComment(_ s: String) -> (value: String, quote: Character?, comment: String) {
        guard let first = s.first else { return ("", nil, "") }
        if first == "\"" || first == "'" {
            var escaped = false
            var value = ""
            var index = s.index(after: s.startIndex)
            while index < s.endIndex {
                let character = s[index]
                if first == "\"" && escaped {
                    value.append(character)
                    escaped = false
                } else if first == "\"" && character == "\\" {
                    escaped = true
                } else if character == first {
                    let comment = String(s[s.index(after: index)...])
                    return (value, first, comment)
                } else {
                    value.append(character)
                }
                index = s.index(after: index)
            }
            return (value, first, "")
        }

        if let commentRange = s.range(of: #"(\s+#.*)$"#, options: .regularExpression) {
            let value = String(s[..<commentRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value, nil, String(s[commentRange.lowerBound...]))
        }
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), nil, "")
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
        // mixed-port / dns.listen / external-controller values below are
        // placeholders only — the bridge picks ephemeral ports at runtime
        // (see bridge_start_with_ephemeral_ports) so multiple mihomo
        // instances on the host don't collide. Editing them in the UI has
        // no effect on the actual bound ports.
        return """
        mixed-port: 0
        mode: rule
        log-level: info
        allow-lan: false
        external-controller: 127.0.0.1:0

        geo-auto-update: false

        dns:
          enable: true
          listen: 127.0.0.1:0
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
            result.append("  - name: \(Self.yamlQuotedString(group.name))")
            result.append("    type: \(group.type)")
            if let url = group.url, !url.isEmpty {
                result.append("    url: \(Self.yamlQuotedString(url))")
            }
            if let interval = group.interval {
                result.append("    interval: \(interval)")
            }
            if group.proxies.isEmpty {
                result.append("    proxies: []")
            } else {
                result.append("    proxies:")
                for proxy in group.proxies {
                    result.append("      - \(Self.yamlQuotedString(proxy))")
                }
            }
        }
        return result
    }

    private func serializeRules(_ rules: [EditableRule]) -> [String] {
        if rules.isEmpty { return ["rules: []"] }
        var result = ["rules:"]
        for rule in rules {
            let ruleLine: String
            if rule.type == "MATCH" {
                ruleLine = "MATCH,\(rule.target)"
            } else {
                var line = "\(rule.type),\(rule.value),\(rule.target)"
                if rule.noResolve { line += ",no-resolve" }
                ruleLine = line
            }
            result.append("  - \(Self.yamlQuotedString(ruleLine))")
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
