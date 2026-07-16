// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Yams

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

        guard let dict = (try? Yams.load(yaml: yamlContent)) as? [String: Any] else {
            return ProxiesResult(groups: [:], proxies: [:])
        }

        if let proxyList = dict["proxies"] as? [[String: Any]] {
            for proxy in proxyList {
                guard let name = proxy["name"] as? String, !name.isEmpty else {
                    continue
                }
                proxies[name] = ProxyLeaf(
                    name: name,
                    type: proxy["type"] as? String ?? "Unknown",
                    latestDelay: nil
                )
            }
        }

        if let groupList = dict["proxy-groups"] as? [[String: Any]] {
            for group in groupList {
                guard let parsedGroup = makeGroup(from: group) else {
                    continue
                }
                groups[parsedGroup.name] = parsedGroup
            }
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

    private static func makeGroup(from dict: [String: Any]) -> MihomoProxyGroup? {
        guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
        let type = normalizeGroupType(dict["type"] as? String ?? "select")
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
