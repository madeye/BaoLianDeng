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
        // IP-ASN rules need the GeoLite2-ASN schema; a missing ASN reader is a
        // HARD config error in the engine, same as a missing Country.mmdb.
        ("GeoLite2-ASN", "mmdb", "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb"),
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

    /// Ensure geodata files (Country.mmdb, geosite.dat, GeoLite2-ASN.mmdb) exist in the given directory.
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
        // The provider extension never writes engineModeKey to its own
        // (per-process) defaults, so it always sanitizes as .vpn.
        Self.sanitizeConfigString(&content, engineMode: EngineMode.load(from: AppConstants.sharedDefaults))
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

    /// True when `name` is something this config can actually select: a
    /// built-in outbound, a declared proxy, or a proxy group. Used to reject
    /// selections carried over from another subscription before they reach
    /// the engine, which silently drops unknown members instead of erroring.
    static func configDefinesProxyName(
        _ name: String,
        in yaml: String,
        groups: [EditableProxyGroup]
    ) -> Bool {
        if name == "DIRECT" || name == "PASS" || name.hasPrefix("REJECT") { return true }
        if groups.contains(where: { $0.name == name }) { return true }
        guard let dict = (try? Yams.load(yaml: yaml)) as? [String: Any],
              let proxies = dict["proxies"] as? [[String: Any]] else { return false }
        return proxies.contains { ($0["name"] as? String) == name }
    }

    /// Return all proxy group names with type "select" from config.yaml.
    func selectProxyGroupNames() -> [String] {
        guard let yaml = try? loadConfig() else { return [] }
        return parseProxyGroups(from: yaml)
            .filter { $0.type == "select" }
            .map(\.name)
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
        guard var yaml = try? loadConfig() else { return }
        Self.normalizeFlowSection(&yaml, key: "tun")
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
    /// `engineMode` only forces DNS fields the engine cannot run without
    /// (enable / listen / enhanced-mode / fake-ip-range); nameservers and
    /// the rest of a user or subscription `dns:` block are left intact.
    static func sanitizeConfigString(_ config: inout String, engineMode: EngineMode = .vpn) {
        // Disable TUN and geo-auto-update — transparent proxy intercepts at
        // socket level, and geo downloads would block tunnel startup.
        // An inline `tun: {enable: true}` has no `enable:` line to rewrite,
        // so spell it out in block style first.
        normalizeFlowSection(&config, key: "tun")
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
        forceManagedDNS(&config, engineMode: engineMode)
        forceTunDisabled(&config)
    }

    /// Fallback `dns:` block inserted only when the config has none.
    /// Nameservers here are bootstrap-friendly IP literals so a missing
    /// section still starts the engine; an existing user or subscription
    /// block is patched in place instead of replaced (see `forceManagedDNS`).
    ///
    /// fake-ip answers every A query with a synthetic 28.0.0.0/8 address,
    /// so the engine — not a local upstream — resolves proxied domains.
    /// The range can't be mihomo's 198.18.0.0/15 default because the
    /// transparent proxy's excludedNetworkRules bypass that range.
    static let managedDNSSection = """
    dns:
      enable: true
      listen: 127.0.0.1:0
      enhanced-mode: fake-ip
      fake-ip-range: 28.0.0.0/8
      # Bootstrap-only resolvers: proxy-server hostnames must resolve
      # without going through a proxy (dial cycle otherwise).
      default-nameserver:
        - 223.5.5.5
        - 114.114.114.114
      # Only reached for DIRECT rules and fake-ip-filtered names — proxied
      # domains are resolved remotely by the proxy itself, so plaintext UDP
      # here can neither poison nor observe them.
      nameserver:
        - 119.29.29.29
        - 223.5.5.5
    """

    /// Fallback `dns:` block for local proxy mode when the config has none.
    /// Nothing is intercepted there — clients hand the engine real domains
    /// via HTTP/SOCKS — so fake-ip would only hand out unroutable 28.0.0.0/8
    /// addresses. redir-host returns real upstream IPs; the sniffing cache
    /// still restores domains for rules.
    static let managedLocalProxyDNSSection = """
    dns:
      enable: true
      listen: 127.0.0.1:0
      enhanced-mode: redir-host
      # Bootstrap-only resolvers: proxy-server hostnames must resolve
      # without going through a proxy (dial cycle otherwise).
      default-nameserver:
        - 223.5.5.5
        - 114.114.114.114
      nameserver:
        - 119.29.29.29
        - 223.5.5.5
    """

    /// Ensure the config has a usable `dns:` section for `engineMode`.
    ///
    /// Missing section → insert the mode's fallback block. Existing section
    /// → rewrite only the engine invariants (`enable`, `listen`,
    /// `enhanced-mode`, and `fake-ip-range` in VPN mode). Nameserver lists,
    /// fallback, nameserver-policy, fake-ip-filter, and comments stay as
    /// the user or subscription wrote them.
    static func forceManagedDNS(_ config: inout String, engineMode: EngineMode = .vpn) {
        normalizeFlowSection(&config, key: "dns")
        var lines = config.components(separatedBy: "\n")
        if let range = topLevelSectionRange(in: lines, key: "dns") {
            var section = Array(lines[range])
            patchDNSSection(&section, engineMode: engineMode)
            lines.replaceSubrange(range, with: section)
        } else {
            let section = engineMode == .localProxy
                ? Self.managedLocalProxyDNSSection : Self.managedDNSSection
            let block = section.components(separatedBy: "\n")
            if let idx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:")
                    && !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
            }) {
                lines.insert(contentsOf: block + [""], at: idx)
            } else {
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                    lines.removeLast()
                }
                lines.append(contentsOf: [""] + block)
            }
        }
        config = lines.joined(separator: "\n")
    }

    /// Rewrite the top-level `key:` section in block style when its header
    /// carries an inline flow mapping — `dns: {enable: true, nameserver:
    /// [1.1.1.1]}` — or, with `includingNested`, when any line inside it
    /// opens one (`p: {type: http, url: …}`). The line-based patchers only
    /// address block keys: `setSectionScalar` would push indented entries
    /// under an inline mapping (invalid YAML), the tun scan never sees an
    /// inline `enable:`, and `sanitizeProviders` cannot find `url:` /
    /// `path:` inside a flow provider. Block-style sections pass through
    /// untouched, so comments there stay put; a section that fails to
    /// parse is left as-is for the engine to reject.
    static func normalizeFlowSection(
        _ config: inout String, key: String, includingNested: Bool = false
    ) {
        var lines = config.components(separatedBy: "\n")
        guard let range = topLevelSectionRange(in: lines, key: key) else { return }
        let opensFlow = { (line: String) in
            opensFlowMapping(line.trimmingCharacters(in: .whitespaces))
        }
        guard opensFlow(lines[range.lowerBound])
            || (includingNested && lines[range].dropFirst().contains(where: opensFlow))
        else { return }

        // Trailing blank and comment lines sit outside the mapping; keep
        // them verbatim.
        var end = range.upperBound
        while end > range.lowerBound + 1 {
            let trimmed = lines[end - 1].trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
            end -= 1
        }
        let text = lines[range.lowerBound..<end].joined(separator: "\n")
        guard let node = try? Yams.compose(yaml: text),
              let root = node.mapping, root.count == 1,
              let value = root[key]?.mapping else { return }
        var block: [String]
        if value.isEmpty {
            // libyaml still emits an empty mapping as `{}`; a bare key
            // lets the patchers add children under it.
            block = ["\(key):"]
        } else {
            guard let text = try? Yams.serialize(
                node: blockStyled(node), width: -1, allowUnicode: true
            ) else { return }
            block = text.components(separatedBy: "\n")
            while block.last?.isEmpty == true { block.removeLast() }
        }
        lines.replaceSubrange(range.lowerBound..<end, with: block)
        config = lines.joined(separator: "\n")
    }

    /// True for a `key: {…`, `"key": {…`, `- {…`, or bare `{…` line.
    private static func opensFlowMapping(_ trimmed: String) -> Bool {
        var rest = Substring(trimmed)
        if rest.hasPrefix("-") {
            rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" }
        }
        if rest.hasPrefix("{") { return true }
        guard let first = rest.first, first != "#" else { return false }
        if first == "\"" || first == "'" {
            // Quoted key: the colon we want follows the closing quote.
            let (_, quote, after) = parseYAMLScalarWithComment(String(rest))
            guard quote != nil else { return false }
            rest = Substring(after)
        }
        guard let colon = rest.firstIndex(of: ":") else { return false }
        let value = rest[rest.index(after: colon)...].drop { $0 == " " || $0 == "\t" }
        return value.hasPrefix("{")
    }

    /// Copy of `node` with every mapping and sequence forced to block style.
    /// Scalars keep their quoting; empty collections still emit as `{}`/`[]`.
    private static func blockStyled(_ node: Yams.Node) -> Yams.Node {
        switch node {
        case .scalar, .alias:
            return node
        case .mapping(let mapping):
            let pairs = mapping.map { ($0.key, blockStyled($0.value)) }
            return .mapping(Yams.Node.Mapping(pairs, mapping.tag, .block))
        case .sequence(let sequence):
            return .sequence(Yams.Node.Sequence(sequence.map(blockStyled), sequence.tag, .block))
        }
    }

    /// Inclusive range of a top-level YAML mapping section named `key`.
    /// The range starts at `key:` and ends before the next top-level key
    /// (comments, blanks, and a column-0 `}` / `]` closing a multi-line
    /// flow collection stay with the section). A flow collection left open
    /// on the `key:` line — `dns: {` with its entries on the following
    /// lines, even at column 0 — is followed to its closing bracket first,
    /// since YAML lets flow entries ignore indentation.
    private static func topLevelSectionRange(
        in lines: [String], key: String
    ) -> Range<Int>? {
        guard let start = lines.firstIndex(where: {
            isYAMLKey($0.trimmingCharacters(in: .whitespaces), key)
                && !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
        }) else { return nil }
        var first = start + 1
        var depth = flowNestingDelta(of: lines[start])
        while depth > 0 && first < lines.count {
            depth += flowNestingDelta(of: lines[first])
            first += 1
        }
        var end = lines.count
        for i in first..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#")
                && !trimmed.hasPrefix("}") && !trimmed.hasPrefix("]")
                && !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                end = i
                break
            }
        }
        return start..<end
    }

    /// Net number of flow collections (`{` / `[`) opened minus closed on
    /// `line`, ignoring brackets inside quoted scalars and after a `#`
    /// comment. Positive means the line leaves a flow collection open.
    private static func flowNestingDelta(of line: String) -> Int {
        var delta = 0
        var quote: Character?
        var previous: Character = " "
        var escaped = false
        for character in line {
            defer { previous = character }
            if let open = quote {
                if open == "\"" && escaped {
                    escaped = false
                } else if open == "\"" && character == "\\" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
                continue
            }
            switch character {
            case "#" where previous == " " || previous == "\t":
                return delta
            case "\"", "'":
                // A quote opens a scalar only at a token boundary; an
                // apostrophe inside a plain scalar (`it's`) is literal.
                if " \t{[,:".contains(previous) { quote = character }
            case "{", "[":
                delta += 1
            case "}", "]":
                delta -= 1
            default:
                break
            }
        }
        return delta
    }

    /// Replace or insert a top-level YAML section. `body` should start with
    /// `key:` and include the full section text.
    private static func replaceTopLevelSection(
        _ config: inout String, key: String, with body: String
    ) {
        var lines = config.components(separatedBy: "\n")
        let block = body.components(separatedBy: "\n")
        if let range = topLevelSectionRange(in: lines, key: key) {
            lines.replaceSubrange(range, with: block)
        } else if let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:")
                && !$0.hasPrefix(" ") && !$0.hasPrefix("\t")
        }) {
            lines.insert(contentsOf: block + [""], at: idx)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            lines.append(contentsOf: [""] + block)
        }
        config = lines.joined(separator: "\n")
    }

    /// True when `trimmed` is a YAML `key:` mapping line (not a longer key
    /// that merely shares a prefix, e.g. `fake-ip-filter` vs `fake-ip-filter-mode`).
    private static func isYAMLKey(_ trimmed: String, _ key: String) -> Bool {
        guard trimmed.hasPrefix(key) else { return false }
        let rest = trimmed.dropFirst(key.count)
        return rest.first == ":"
    }

    /// Rewrite engine-required scalars inside an existing `dns:` section.
    /// Also drops loopback `proxy-server-nameserver` entries — see
    /// `dropSelfReferentialProxyNameservers`.
    private static func patchDNSSection(_ lines: inout [String], engineMode: EngineMode) {
        healSplitDNSBlock(&lines)
        let mode = engineMode == .localProxy ? "redir-host" : "fake-ip"
        setSectionScalar(&lines, key: "enable", value: "true")
        setSectionScalar(&lines, key: "listen", value: "127.0.0.1:0")
        setSectionScalar(&lines, key: "enhanced-mode", value: mode)
        if engineMode == .localProxy {
            removeSectionScalar(&lines, key: "fake-ip-range")
        } else {
            setSectionScalar(&lines, key: "fake-ip-range", value: "28.0.0.0/8")
        }
        dropSelfReferentialProxyNameservers(&lines)
    }

    /// Drop loopback `proxy-server-nameserver` entries. Some subscription
    /// exports set `listen: 127.0.0.1:PORT` together with
    /// `proxy-server-nameserver: [udp://127.0.0.1:PORT]` so proxy server
    /// hostnames resolve through the client's own DNS server. The engine
    /// always rebinds DNS to an ephemeral loopback port at runtime, so any
    /// fixed loopback pointer is stale: every node hostname lookup then times
    /// out and outbound dials fail ("no address for <host>"). Matching on the
    /// pre-patch `listen` port is not enough — a config saved by an older
    /// build already shows `listen: 127.0.0.1:0` while the stale entry
    /// survives, so loopback entries are dropped regardless of port. With
    /// them removed, the engine resolves proxy server hostnames through the
    /// regular `nameserver` list, dialed directly (nameserver entries without
    /// an explicit `#PROXY` tag never go through a proxy). Entries pointing
    /// at a non-loopback resolver stay untouched.
    private static func dropSelfReferentialProxyNameservers(
        _ lines: inout [String]
    ) {
        guard let keyIdx = lines.firstIndex(where: {
            isYAMLKey($0.trimmingCharacters(in: .whitespaces), "proxy-server-nameserver")
        }) else { return }

        func isSelfReference(_ entry: String) -> Bool {
            guard let (host, _) = splitHostPort(entry) else { return false }
            return isLoopbackHost(host)
        }

        let keyLine = lines[keyIdx]
        let keyIndent = String(keyLine.prefix { $0 == " " || $0 == "\t" })
        if let inline = sectionScalarValue(
            keyLine.trimmingCharacters(in: .whitespaces), key: "proxy-server-nameserver"
        ), inline.hasPrefix("["), inline.hasSuffix("]") {
            // Inline form: `proxy-server-nameserver: [a, b]`.
            let entries = inline.dropFirst().dropLast()
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let kept = entries.filter { !isSelfReference($0) }
            if kept.isEmpty {
                lines.remove(at: keyIdx)
            } else if kept.count != entries.count {
                lines[keyIdx] = "\(keyIndent)proxy-server-nameserver: [\(kept.joined(separator: ", "))]"
            }
            return
        }

        // Block form: a `key:` line followed by deeper-indented `- item` lines.
        var kept = 0
        var drop: [Int] = []
        var lastItemIdx: Int?
        var i = keyIdx + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            // A `- item` at the key's own indent still belongs to it (YAML
            // allows an unindented block sequence there, and the flow
            // normalizer emits that shape).
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            guard indent.count >= keyIndent.count, trimmed.hasPrefix("-") else { break }
            let entry = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if isSelfReference(entry) {
                drop.append(i)
            } else {
                kept += 1
            }
            lastItemIdx = i
            i += 1
        }
        if kept == 0, let lastItemIdx {
            // No usable entry left: remove the key line, its dead list, and
            // any blanks/comments in between.
            lines.removeSubrange(keyIdx...lastItemIdx)
        } else {
            for idx in drop.reversed() {
                lines.remove(at: idx)
            }
        }
    }

    /// Split a `listen` value or nameserver entry into host and port.
    /// Tolerates `scheme://` prefixes, `#fragment` suffixes, quoted strings,
    /// URL paths, and bracketed IPv6. A missing port comes back as nil.
    private static func splitHostPort(_ entry: String) -> (String, UInt16?)? {
        var s = entry.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if let scheme = s.range(of: "://") {
            s = String(s[scheme.upperBound...])
        }
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? UInt16(rest.dropFirst()) : nil
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return (s, nil) }
        guard let port = UInt16(s[s.index(after: colon)...]) else { return nil }
        return (String(s[..<colon]), port)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// Indent used by first-level keys under `dns:`.
    private static func dnsChildIndent(in lines: [String]) -> String {
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            if !indent.isEmpty { return String(indent) }
        }
        return "  "
    }

    /// Unquoted scalar after `key:` on a first-level section line, minus
    /// a trailing comment. Nil when the key is absent.
    private static func sectionScalarValue(_ trimmed: String, key: String) -> String? {
        guard isYAMLKey(trimmed, key) else { return nil }
        var rest = trimmed.dropFirst(key.count + 1)
            .trimmingCharacters(in: .whitespaces)
        if let hash = rest.firstIndex(of: "#") {
            rest = rest[..<hash].trimmingCharacters(in: .whitespaces)
        }
        return rest
    }

    /// Keys this patcher may insert. Used to recognize (and heal) a previous
    /// bug that dropped them between a block key like `nameserver:` and its list.
    private static let patchedDNSKeys: Set<String> = [
        "enable", "listen", "enhanced-mode", "fake-ip-range",
    ]

    /// Set a first-level scalar under the section header. Missing keys are
    /// inserted immediately under `dns:` — never after a block key such as
    /// `nameserver:` — so the new scalar cannot steal that key's list items.
    /// A matching value is left untouched so comments stay put.
    private static func setSectionScalar(_ lines: inout [String], key: String, value: String) {
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard isYAMLKey(trimmed, key) else { continue }
            if sectionScalarValue(trimmed, key: key) == value { return }
            lines[i] = replacingScalarValue(lines[i], key: key, newValue: value)
            return
        }
        let indent = dnsChildIndent(in: lines)
        lines.insert("\(indent)\(key): \(value)", at: 1)
    }

    /// Repair `nameserver:\n  listen: 127.0.0.1:0\n    - https://…` produced
    /// by an earlier inserter that split a block key from its nested list.
    /// The orphaned list/map lines move back under the empty block key.
    private static func healSplitDNSBlock(_ lines: inout [String]) {
        let indent = dnsChildIndent(in: lines)
        var i = 1
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let lineIndent = String(lines[i].prefix { $0 == " " || $0 == "\t" })
            guard lineIndent == indent,
                  let key = mappingKeyName(trimmed),
                  !patchedDNSKeys.contains(key),
                  sectionScalarValue(trimmed, key: key)?.isEmpty == true else {
                i += 1
                continue
            }
            var j = i + 1
            var stolen: Range<Int>?
            while j < lines.count {
                let t = lines[j].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("#") {
                    j += 1
                    continue
                }
                let ji = String(lines[j].prefix { $0 == " " || $0 == "\t" })
                if ji == indent, let k = mappingKeyName(t), patchedDNSKeys.contains(k) {
                    j += 1
                    continue
                }
                if ji.count > indent.count {
                    let start = j
                    var k = j + 1
                    while k < lines.count {
                        let kt = lines[k].trimmingCharacters(in: .whitespaces)
                        if kt.isEmpty {
                            k += 1
                            continue
                        }
                        let ki = String(lines[k].prefix { $0 == " " || $0 == "\t" })
                        if ki.count <= indent.count { break }
                        k += 1
                    }
                    stolen = start..<k
                }
                break
            }
            if let stolen {
                let items = Array(lines[stolen])
                lines.removeSubrange(stolen)
                lines.insert(contentsOf: items, at: i + 1)
                i += 1 + items.count
            } else {
                i += 1
            }
        }
    }

    /// Mapping key on a `key:` / `key: value` line, or nil.
    private static func mappingKeyName(_ trimmed: String) -> String? {
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colon])
        guard !name.isEmpty, !name.hasPrefix("#"), !name.hasPrefix("-") else { return nil }
        return name
    }

    /// Drop a first-level scalar key (and only that line). Used to strip
    /// `fake-ip-range` when switching the engine to redir-host.
    private static func removeSectionScalar(_ lines: inout [String], key: String) {
        lines.removeAll { isYAMLKey($0.trimmingCharacters(in: .whitespaces), key) }
    }

    /// Ensure the config carries an explicit, disabled top-level `tun:`
    /// block. Truthy `enable:` values in an existing block are already
    /// rewritten to false by the sanitize passes; this injects the block
    /// when absent so the effective config states the invariant outright
    /// instead of relying on the engine's default. Idempotent.
    static func forceTunDisabled(_ config: inout String) {
        var lines = config.components(separatedBy: "\n")
        let hasTun = lines.contains {
            !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("tun:")
        }
        guard !hasTun else { return }
        let block = ["tun:", "  enable: false", ""]
        if let idx = lines.firstIndex(where: {
            !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("dns:")
        }) {
            lines.insert(contentsOf: block, at: idx)
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            lines.append(contentsOf: [""] + block.dropLast())
        }
        config = lines.joined(separator: "\n")
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
        // Find end: next top-level key or end of file (a column-0 `}` / `]`
        // closing a multi-line flow value belongs to the section)
        var end = lines.count
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !trimmed.hasPrefix("}") && !trimmed.hasPrefix("]") {
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
        var found = false
        let lines = normalized.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  trimmed.hasPrefix("\(key):") else {
                return line
            }
            found = true
            return "\(key): \(value)"
        }
        if found {
            return lines.joined(separator: "\n")
        }
        // Key absent (e.g. subscription-only YAML): insert at the top so
        // callers can always force allow-lan / bind-address / mixed-port.
        let insertion = "\(key): \(value)"
        if normalized.isEmpty {
            return insertion
        }
        return insertion + "\n" + normalized
    }

    /// Merge a Clash subscription YAML into our base config.
    /// Keeps port settings from the base header; takes proxies, groups,
    /// rules, providers, and (when present) the subscription `dns:` block.
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
        return ConfigManager.mergeSubscription(
            yaml, baseConfig: base, defaultConfig: defaultConfig(),
            engineMode: EngineMode.load(from: AppConstants.sharedDefaults)
        )
    }

    /// Pure merge logic — takes all inputs as parameters for testability.
    /// Keeps the header (ports, DNS settings) from the base config.
    /// Overwrites proxies, proxy-groups, rules, and providers directly from subscription
    /// (raw pass-through to preserve all fields mihomo needs).
    static func mergeSubscription(
        _ yaml: String, baseConfig: String, defaultConfig: String,
        engineMode: EngineMode = .vpn
    ) -> String {
        // 1. Extract raw sections from subscription (preserves exact formatting)
        let sub = extractYAMLSections(
            from: yaml,
            named: ["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers", "dns"]
        )

        // 2. Header from base config (everything before proxies:) preserves
        // user edits to ports. A subscription `dns:` block replaces the
        // header's dns section so provider nameservers/fallback survive;
        // otherwise the base dns is kept.
        let baseLines = baseConfig.components(separatedBy: "\n")
        let proxiesCut = baseLines.firstIndex(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("proxies:") }) ?? baseLines.count
        var header = baseLines[0..<proxiesCut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if let subDNS = sub["dns"] {
            replaceTopLevelSection(&header, key: "dns", with: subDNS)
        }

        // 3. Build merged config — pass through raw sections from subscription
        var result = header

        result += "\n\n" + (sub["proxies"] ?? "proxies: []")
        result += "\n\n" + (sub["proxy-groups"] ?? "proxy-groups: []")

        if let pp = sub["proxy-providers"] { result += "\n\n" + Self.disableProviderRefresh(Self.sanitizeProviders(pp)) }
        if let rp = sub["rule-providers"] { result += "\n\n" + Self.disableProviderRefresh(Self.sanitizeProviders(rp)) }

        let defaultRules = extractYAMLSections(from: defaultConfig, named: ["rules"])
        result += "\n\n" + (sub["rules"] ?? defaultRules["rules"] ?? "rules:\n  - MATCH,DIRECT")

        // Force only engine invariants (enable / listen / enhanced-mode /
        // fake-ip-range). Nameservers, fallback, and nameserver-policy stay.
        forceManagedDNS(&result, engineMode: engineMode)

        // The app's own default rules target `PROXY`. When those rules are
        // in play and no such group exists, insert one so traffic still
        // flows instead of hitting a missing name.
        ensureProxyGroupFallback(&result)

        return result
    }

    /// Insert a `PROXY` select group defaulting to DIRECT when the merged
    /// config resolves that name but does not define it. Existing groups are
    /// left intact (prepended, not rewritten) so subscription fields like
    /// `filter` / `icon` survive. Leaf proxy names are listed after DIRECT so
    /// the user can still pick a node later.
    ///
    /// The name check alone is not enough to decide whether to inject. A
    /// subscription that ships its own rules and primary group — commonly
    /// named `Proxies`, differing from `PROXY` only in case and plural — has
    /// no dangling reference to repair, so injecting anyway produced a decoy
    /// group that no rule ever routes through. Worse, `ProxyGroupsViewModel`
    /// sorts groups by name and `"PROXY" < "Proxies"`, so the decoy rendered
    /// directly above the real one: picking a node in it silently changed
    /// nothing while the live group stayed on its default first member.
    static func ensureProxyGroupFallback(_ config: inout String) {
        if hasNamedProxyGroup(config, name: "PROXY") { return }
        guard referencesProxyName(config, name: "PROXY") else { return }

        var members = ["DIRECT"]
        if let dict = (try? Yams.load(yaml: config)) as? [String: Any],
           let proxies = dict["proxies"] as? [[String: Any]] {
            for name in extractProxyNames(from: proxies)
            where name != "DIRECT" && name != "REJECT" && !members.contains(name) {
                members.append(name)
            }
        }

        let groupLines = [
            "  - name: \(yamlQuotedString("PROXY"))",
            "    type: select",
            "    proxies:",
        ] + members.map { "      - \(yamlQuotedString($0))" }

        var lines = config.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { isTopLevelYAMLKey($0, "proxy-groups") }) {
            let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("proxy-groups: []") {
                lines[idx] = "proxy-groups:"
                lines.insert(contentsOf: groupLines, at: idx + 1)
            } else {
                lines.insert(contentsOf: groupLines, at: idx + 1)
            }
        } else if let rulesIdx = lines.firstIndex(where: { isTopLevelYAMLKey($0, "rules") }) {
            lines.insert(contentsOf: ["proxy-groups:"] + groupLines + [""], at: rulesIdx)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("proxy-groups:")
            lines.append(contentsOf: groupLines)
        }
        config = lines.joined(separator: "\n")
    }

    private static func isTopLevelYAMLKey(_ line: String, _ key: String) -> Bool {
        !line.hasPrefix(" ") && !line.hasPrefix("\t")
            && isYAMLKey(line.trimmingCharacters(in: .whitespaces), key)
    }

    private static func hasNamedProxyGroup(_ yaml: String, name: String) -> Bool {
        ConfigManager.shared.parseProxyGroups(from: yaml).contains { $0.name == name }
    }

    /// Whether anything in the merged config resolves `name` as a proxy: a
    /// rule target, or a member of another proxy group. Either one dangles if
    /// the group is missing, so either one warrants the fallback.
    private static func referencesProxyName(_ yaml: String, name: String) -> Bool {
        let manager = ConfigManager.shared
        if manager.parseRules(from: yaml).contains(where: { $0.target == name }) {
            return true
        }
        return manager.parseProxyGroups(from: yaml).contains { $0.proxies.contains(name) }
    }

    /// Set interval to 0 in provider sections so Mihomo won't auto-refresh subscription URLs.
    /// Only each provider's own `interval:` is rewritten; a nested one
    /// (`health-check: {interval: 300}`) is the provider's business.
    static func disableProviderRefresh(_ section: String) -> String {
        guard let (header, blocks) = splitProviderBlocks(section) else { return section }
        let rewritten = blocks.flatMap { block -> [String] in
            let depth = providerChildIndent(of: block)
            return block.map { line in
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard indent.count == depth, trimmed.hasPrefix("interval:") else { return line }
                return indent + "interval: 0"
            }
        }
        return ([header] + rewritten).joined(separator: "\n")
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
        guard let (header, blocks) = splitProviderBlocks(section) else { return section }
        let kept = blocks.compactMap { sanitizeProviderBlock($0) }
        guard !kept.isEmpty else { return header }
        return ([header] + kept.flatMap { $0 }).joined(separator: "\n")
    }

    /// Split a `proxy-providers:` / `rule-providers:` section into its
    /// header line and one line group per provider entry (each starting
    /// at the `name:` line). Flow-style entries are first re-emitted in
    /// block style: `p: {type: http, url: file:///…}` keeps its `url:` /
    /// `path:` off their own lines, which would let it slip past the
    /// checks untouched. Nil when the section has no entries.
    private static func splitProviderBlocks(_ section: String) -> (String, [[String]])? {
        var section = section
        if let key = mappingKeyName(section.components(separatedBy: "\n")[0]) {
            normalizeFlowSection(&section, key: key, includingNested: true)
        }
        var lines = section.components(separatedBy: "\n")
        guard lines.count > 1 else { return nil }
        let header = lines.removeFirst()

        // The indentation of the first provider-name line (e.g. 2 spaces)
        // marks the start of each subsequent provider entry.
        guard let baseIndent = lines
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map({ line in line.prefix(while: { $0 == " " }).count })
        else {
            return nil
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
        return (header, blocks)
    }

    /// Indentation of a provider entry's own keys: the first non-blank,
    /// non-comment line after the `name:` line. Deeper lines belong to a
    /// nested mapping such as `health-check:` or `header:`, whose `url:` /
    /// `interval:` must not be mistaken for the provider's.
    private static func providerChildIndent(of block: [String]) -> Int {
        for line in block.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return line.prefix(while: { $0 == " " || $0 == "\t" }).count
        }
        return Int.max
    }

    /// Returns the (possibly rewritten) lines of a single provider block, or
    /// nil if the whole block should be dropped (non-https `url:`). Only the
    /// provider's first-level keys are inspected — `health-check: {url:
    /// http://www.gstatic.com/generate_204}` is a probe target, not a
    /// download URL, and must not get the provider dropped.
    private static func sanitizeProviderBlock(_ block: [String]) -> [String]? {
        let depth = providerChildIndent(of: block)
        var result: [String] = []
        for line in block {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard indent.count == depth else {
                result.append(line)
                continue
            }
            if trimmed.hasPrefix("url:") {
                let value = scalarValue(afterKey: "url", in: line)
                guard value.lowercased().hasPrefix("https://") else { return nil }
                result.append(line)
                continue
            }
            if trimmed.hasPrefix("path:") {
                let value = scalarValue(afterKey: "path", in: line)
                if value.contains("..") || value.hasPrefix("/") || value.hasPrefix("~") {
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

    /// Extracts the scalar value of `key:` from a raw config line,
    /// indentation- and quote-aware.
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
            // A column-0 `}` / `]` closes a multi-line flow collection and
            // stays with the section it ends.
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.isEmpty && !line.hasPrefix("-") && !line.hasPrefix("#")
                && !line.hasPrefix("}") && !line.hasPrefix("]")
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
        // placeholders only — the bridge forces SOCKS/DNS/API ports at
        // runtime. allow-lan / bind-address / mixed-port are rewritten by
        // VPNManager.buildEffectiveConfigYAML from LANSharingSettings.
        return """
        mixed-port: 0
        mode: rule
        log-level: info
        allow-lan: false
        bind-address: 127.0.0.1
        external-controller: 127.0.0.1:0

        geo-auto-update: false

        \(Self.managedDNSSection)

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

struct EditableProxyGroup: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: String
    var proxies: [String]
    var url: String?
    var interval: Int?
    /// Group fields the structured editor does not model (`use`, `filter`,
    /// `lazy`, `tolerance`, `include-all`, …), in source order. They are
    /// re-emitted verbatim on save so a structured edit — or a mere
    /// Structured → Raw switch — cannot strip provider-backed membership
    /// or tuning options the editor never showed.
    var extraFields: [ProxyGroupField] = []

    /// Keys the structured editor maps onto dedicated properties. Anything
    /// else lands in `extraFields`.
    static let modelledKeys: Set<String> = ["name", "type", "proxies", "url", "interval"]

    /// Whether the group's members come from somewhere other than
    /// `proxies:` — a provider list or an include-all flag. Such a group
    /// legitimately has no `proxies:` key, so none is synthesized for it.
    var hasProviderMembership: Bool {
        extraFields.contains {
            ["use", "include-all", "include-all-proxies", "include-all-providers"].contains($0.key)
        }
    }
}

/// One unmodelled `key: value` pair of a proxy group, held as a parsed
/// YAML node so nested lists and mappings survive the round trip.
struct ProxyGroupField: Hashable {
    var key: String
    var value: Yams.Node
}

struct EditableRule: Identifiable, Equatable {
    var id = UUID()
    var type: String
    var value: String
    var target: String
    var noResolve: Bool
}

// MARK: - Config Parsing & Update

extension ConfigManager {

    func parseProxyGroups(from yaml: String) -> [EditableProxyGroup] {
        // Composed nodes (not `Yams.load`'s `[String: Any]`) so unmodelled
        // fields keep their order, nesting, and scalar quoting for re-emit.
        guard let root = try? Yams.compose(yaml: yaml),
              let groupList = root["proxy-groups"]?.sequence else {
            return []
        }
        return groupList.compactMap { group -> EditableProxyGroup? in
            guard let mapping = group.mapping,
                  let name = mapping["name"]?.string,
                  let type = mapping["type"]?.string else { return nil }
            let proxies = mapping["proxies"]?.sequence?.compactMap(\.string) ?? []
            let url = Self.presentScalar(mapping["url"])?.string
            let interval = mapping["interval"]?.int
            let extras = mapping.compactMap { pair -> ProxyGroupField? in
                guard let key = pair.key.string,
                      !EditableProxyGroup.modelledKeys.contains(key) else { return nil }
                return ProxyGroupField(key: key, value: pair.value)
            }
            return EditableProxyGroup(
                name: name, type: type, proxies: proxies, url: url, interval: interval,
                extraFields: extras
            )
        }
    }

    /// `node`'s scalar unless it is a YAML null (`url: null`, `url: ~`,
    /// or a bare `url:`), whose `Node.string` would still hand back the
    /// raw text and re-emit it as the string `"null"`.
    private static func presentScalar(_ node: Yams.Node?) -> Yams.Node.Scalar? {
        guard let scalar = node?.scalar, NSNull.construct(from: scalar) == nil else { return nil }
        return scalar
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
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("#")
                && !trimmed.hasPrefix("}") && !trimmed.hasPrefix("]") {
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
            if !group.proxies.isEmpty {
                result.append("    proxies:")
                for proxy in group.proxies {
                    result.append("      - \(Self.yamlQuotedString(proxy))")
                }
            } else if !group.hasProviderMembership {
                result.append("    proxies: []")
            }
            for field in group.extraFields {
                result.append(contentsOf: Self.serializeProxyGroupField(field))
            }
        }
        return result
    }

    /// Emit one unmodelled group field as indented YAML lines. The node is
    /// serialized on its own (`use: [p]`, `filter: test`, a block list…)
    /// and every line shifted under the group entry, which keeps nested
    /// structure intact whatever its style.
    private static func serializeProxyGroupField(_ field: ProxyGroupField) -> [String] {
        let node = Yams.Node.mapping(Yams.Node.Mapping([(Yams.Node(field.key), field.value)]))
        // Unlimited width and raw unicode: a `filter: "(?i)香港|HK"` regex
        // must not come back as `\u9999\u6E2F` folded across lines.
        guard let text = try? Yams.serialize(node: node, width: -1, allowUnicode: true) else { return [] }
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { "    " + $0 }
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
