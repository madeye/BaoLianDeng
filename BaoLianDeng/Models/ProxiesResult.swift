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

// MARK: - Proxy Leaf (non-group proxy from /proxies endpoint)

struct ProxyLeaf: Identifiable {
    let name: String
    let type: String
    let latestDelay: Int?

    var id: String { name }

    static func fromJSON(name: String, json: [String: Any]) -> ProxyLeaf {
        // Extract delay from history array's last entry
        var delay: Int?
        if let history = json["history"] as? [[String: Any]], let last = history.last {
            delay = last["delay"] as? Int
        }
        return ProxyLeaf(
            name: name,
            type: json["type"] as? String ?? "",
            latestDelay: delay
        )
    }
}

// MARK: - Proxies Result (groups + leaf proxies)

/// Result of GET /proxies, split into proxy groups and leaf proxies.
/// Mirrors meow-go's `ProxiesResult` in `proxy_group.dart`.
struct ProxiesResult {
    let groups: [String: MihomoProxyGroup]
    let proxies: [String: ProxyLeaf]

    /// Group types as reported by mihomo's /proxies endpoint.
    private static let groupTypes: Set<String> = [
        "Selector", "URLTest", "Fallback", "LoadBalance", "Relay"
    ]

    /// Parse the raw /proxies JSON response body.
    static func fromAPI(_ json: [String: Any]) -> ProxiesResult {
        guard let raw = json["proxies"] as? [String: Any] else {
            return ProxiesResult(groups: [:], proxies: [:])
        }

        var groups: [String: MihomoProxyGroup] = [:]
        var proxies: [String: ProxyLeaf] = [:]

        for (name, value) in raw {
            guard let data = value as? [String: Any],
                  let type = data["type"] as? String else { continue }

            if groupTypes.contains(type) {
                let now = data["now"] as? String ?? ""
                let all = data["all"] as? [String] ?? []
                groups[name] = MihomoProxyGroup(name: name, type: type, now: now, all: all)
            } else {
                proxies[name] = ProxyLeaf.fromJSON(name: name, json: data)
            }
        }

        return ProxiesResult(groups: groups, proxies: proxies)
    }

    /// Parse a clash config YAML string into a ProxiesResult for offline display
    /// when the embedded engine isn't running (VPN is off).
    /// Returns empty groups/proxies on any parse error. No history/delay data.
    static func fromYAML(_ yamlContent: String) -> ProxiesResult {
        guard !yamlContent.isEmpty else {
            return ProxiesResult(groups: [:], proxies: [:])
        }

        var proxies: [String: ProxyLeaf] = [:]
        var groups: [String: MihomoProxyGroup] = [:]

        let lines = yamlContent.components(separatedBy: "\n")
        var inProxies = false
        var inProxyGroups = false
        var currentGroup: [String: Any] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Section detection
            if line.hasPrefix("proxies:") {
                inProxies = true
                inProxyGroups = false
                continue
            }
            if line.hasPrefix("proxy-groups:") {
                inProxyGroups = true
                inProxies = false
                continue
            }
            // Top-level key ends current section
            if !line.hasPrefix(" ") && !line.isEmpty && line.contains(":") &&
               !line.hasPrefix("proxies:") && !line.hasPrefix("proxy-groups:") {
                if inProxyGroups, let group = makeGroup(from: currentGroup) {
                    groups[group.name] = group
                }
                inProxies = false
                inProxyGroups = false
                currentGroup = [:]
                continue
            }

            // Parse proxies section
            if inProxies {
                if let name = extractProxyName(from: trimmed) {
                    // We don't have full type info from simple parsing, use "Unknown"
                    proxies[name] = ProxyLeaf(name: name, type: "Unknown", latestDelay: nil)
                }
            }

            // Parse proxy-groups section
            if inProxyGroups {
                if trimmed.hasPrefix("- name:") || trimmed == "-" {
                    if let group = makeGroup(from: currentGroup) {
                        groups[group.name] = group
                    }
                    currentGroup = [:]
                }
                parseGroupLine(trimmed, into: &currentGroup)
            }
        }

        // Handle last group
        if inProxyGroups, let group = makeGroup(from: currentGroup) {
            groups[group.name] = group
        }

        // Add built-in DIRECT/REJECT if not present
        if proxies["DIRECT"] == nil {
            proxies["DIRECT"] = ProxyLeaf(name: "DIRECT", type: "Direct", latestDelay: nil)
        }
        if proxies["REJECT"] == nil {
            proxies["REJECT"] = ProxyLeaf(name: "REJECT", type: "Reject", latestDelay: nil)
        }

        return ProxiesResult(groups: groups, proxies: proxies)
    }

    // MARK: - YAML Parsing Helpers

    private static func extractProxyName(from line: String) -> String? {
        // Flow style: - {name: "foo", ...}
        if line.hasPrefix("- {") && line.contains("name:") {
            if let nameRange = line.range(of: "name:") {
                let afterName = line[nameRange.upperBound...]
                let trimmed = afterName.trimmingCharacters(in: .whitespaces)
                // Extract value until comma or }
                var value = ""
                var inQuote: Character?
                for ch in trimmed {
                    if inQuote != nil {
                        if ch == inQuote { break }
                        value.append(ch)
                    } else if ch == "\"" || ch == "'" {
                        inQuote = ch
                    } else if ch == "," || ch == "}" {
                        break
                    } else {
                        value.append(ch)
                    }
                }
                let name = value.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        // Block style: - name: foo or name: foo
        if line.hasPrefix("- name:") {
            return extractValue(from: line, key: "- name:")
        }
        if line.hasPrefix("name:") {
            return extractValue(from: line, key: "name:")
        }
        return nil
    }

    private static func extractValue(from line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        var value = String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
        // Remove quotes
        if value.count >= 2 {
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
        }
        return value.isEmpty ? nil : value
    }

    private static func parseGroupLine(_ line: String, into group: inout [String: Any]) {
        if line.contains("name:") {
            if let value = extractValue(from: line.replacingOccurrences(of: "- ", with: ""), key: "name:") {
                group["name"] = value
            }
        } else if line.contains("type:") {
            if let value = extractValue(from: line, key: "type:") {
                group["type"] = normalizeGroupType(value)
            }
        } else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") &&
                  !line.contains(":") {
            // Proxy member line
            var members = group["proxies"] as? [String] ?? []
            let member = line.trimmingCharacters(in: .whitespaces)
                .dropFirst(2) // Remove "- "
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !member.isEmpty {
                members.append(String(member))
                group["proxies"] = members
            }
        }
    }

    private static func makeGroup(from dict: [String: Any]) -> MihomoProxyGroup? {
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let type = dict["type"] as? String ?? "Selector"
        let all = dict["proxies"] as? [String] ?? []
        let now = all.first ?? ""
        return MihomoProxyGroup(name: name, type: type, now: now, all: all)
    }

    /// Map clash YAML group type strings to mihomo API strings.
    private static func normalizeGroupType(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "Selector"
        case "url-test": return "URLTest"
        case "fallback": return "Fallback"
        case "load-balance": return "LoadBalance"
        case "relay": return "Relay"
        default: return type
        }
    }
}
