// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
@testable import BaoLianDeng

// MARK: - YAML Section Extraction

@Suite("extractYAMLSections")
struct ExtractYAMLSectionsTests {

    @Test("Extracts named top-level sections")
    func extractsNamedSections() {
        let yaml = """
        port: 7890
        proxies:
          - name: node1
            type: vless
        proxy-groups:
          - name: PROXY
            type: select
        rules:
          - MATCH,DIRECT
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies", "proxy-groups", "rules"]
        )
        #expect(sections["proxies"] != nil)
        #expect(sections["proxy-groups"] != nil)
        #expect(sections["rules"] != nil)
        #expect(sections["proxies"]!.hasPrefix("proxies:"))
        #expect(sections["proxy-groups"]!.hasPrefix("proxy-groups:"))
        #expect(sections["rules"]!.hasPrefix("rules:"))
    }

    @Test("Ignores sections not in wanted list")
    func ignoresUnwantedSections() {
        let yaml = """
        port: 7890
        dns:
          enable: true
        proxies:
          - name: node1
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies"]
        )
        #expect(sections["proxies"] != nil)
        #expect(sections["dns"] == nil)
        #expect(sections["port"] == nil)
    }

    @Test("Returns empty dict when no sections match")
    func emptyWhenNoMatch() {
        let yaml = """
        port: 7890
        mode: rule
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies", "rules"]
        )
        #expect(sections.isEmpty)
    }

    @Test("Handles indented content correctly")
    func indentedContentBelongsToSection() {
        let yaml = """
        proxies:
          - name: node1
            type: vless
            server: 1.2.3.4
          - name: node2
            type: trojan
        rules:
          - MATCH,DIRECT
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies"]
        )
        let proxies = sections["proxies"]!
        #expect(proxies.contains("node1"))
        #expect(proxies.contains("node2"))
        // rules should not leak into proxies section
        #expect(!proxies.contains("MATCH"))
    }

    @Test("Handles CRLF line endings")
    func handlesCRLF() {
        let yaml = "proxies:\r\n  - name: node1\r\nrules:\r\n  - MATCH,DIRECT"
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies", "rules"]
        )
        #expect(sections["proxies"] != nil)
        #expect(sections["rules"] != nil)
    }

    @Test("Skips comment lines at top level")
    func skipsComments() {
        let yaml = """
        # This is a comment
        proxies:
          - name: node1
        # Another comment
          - name: node2
        rules:
          - MATCH,DIRECT
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies"]
        )
        let proxies = sections["proxies"]!
        #expect(proxies.contains("node1"))
        #expect(proxies.contains("node2"))
    }

    @Test("Indented lines not treated as top-level keys")
    func indentedLinesNotTopLevel() {
        // Regression: YAML generated with leading spaces should not match top-level keys
        let yaml = """
                proxies:
                  - name: node1
                proxy-groups:
                  - name: PROXY
        """
        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies", "proxy-groups"]
        )
        // Indented lines should NOT be extracted as top-level sections
        #expect(sections["proxies"] == nil)
        #expect(sections["proxy-groups"] == nil)
    }
}

// MARK: - Config Merge

@Suite("mergeSubscription")
struct MergeSubscriptionTests {

    static let baseConfig = """
    mixed-port: 7890
    mode: rule
    dns:
      enable: true
    proxies: []
    proxy-groups:
      - name: PROXY
        type: select
        proxies: []
    rules:
      - MATCH,PROXY
    """

    static let defaultConfig = baseConfig

    @Test("Subscription proxies replace base proxies")
    func subscriptionProxiesReplace() {
        let sub = """
        proxies:
          - {name: sub-node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: MyGroup
            type: select
            proxies:
              - sub-node
        rules:
          - MATCH,MyGroup
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("sub-node"))
        #expect(merged.contains("MyGroup"))
        #expect(merged.contains("MATCH,MyGroup"))
    }

    @Test("Header from base config is preserved")
    func headerPreserved() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("mixed-port: 7890"))
        #expect(merged.contains("dns:"))
    }

    @Test("Falls back to default rules when subscription has none")
    func fallsBackToDefaultRules() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        // Should use default rules since subscription has no rules section
        #expect(merged.contains("MATCH,PROXY"))
    }

    @Test("Subscription rules override default rules")
    func subscriptionRulesOverride() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Proxies
            type: select
            proxies:
              - node
        rules:
          - DOMAIN-SUFFIX,example.com,Proxies
          - MATCH,DIRECT
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("example.com,Proxies"))
        #expect(merged.contains("MATCH,DIRECT"))
        // Default rules should NOT be present
        #expect(!merged.contains("MATCH,PROXY"))
    }

    @Test("Empty subscription produces valid merged config")
    func emptySubscription() {
        let sub = ""
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        // Should still have header and fallback rules
        #expect(merged.contains("mixed-port: 7890"))
        #expect(merged.contains("rules:"))
    }
}

// MARK: - Proxy-Routed DNS Retargeting

@Suite("retargetProxiedNameservers")
struct RetargetProxiedNameserversTests {

    static let taggedBase = """
    mixed-port: 7890
    mode: rule
    dns:
      enable: true
      default-nameserver:
        - 223.5.5.5
      nameserver:
        - 'tcp://1.1.1.1:53#PROXY'
        - 'tcp://8.8.8.8:53#PROXY'
    proxies: []
    proxy-groups:
      - name: PROXY
        type: select
        proxies: []
    rules:
      - MATCH,PROXY
    """

    @Test("Merge retargets #PROXY to the subscription's first select group")
    func retargetsToFirstSelectGroup() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: '🚀 节点选择'
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 'tcp://1.1.1.1:53#🚀 节点选择'"))
        #expect(merged.contains("- 'tcp://8.8.8.8:53#🚀 节点选择'"))
        #expect(!merged.contains("#PROXY'"))
    }

    @Test("Non-select groups are skipped in favor of the first select group")
    func prefersSelectOverAutoGroups() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Auto
            type: url-test
            url: http://www.gstatic.com/generate_204
            interval: 300
            proxies:
              - node
          - name: Manual
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 'tcp://1.1.1.1:53#Manual'"))
    }

    @Test("Falls back to first group when subscription has no select group")
    func fallsBackToFirstGroup() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Auto
            type: url-test
            url: http://www.gstatic.com/generate_204
            interval: 300
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 'tcp://1.1.1.1:53#Auto'"))
    }

    @Test("Strips tag when subscription defines no proxy-groups")
    func stripsTagWithoutGroups() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 'tcp://1.1.1.1:53'"))
        #expect(merged.contains("- 'tcp://8.8.8.8:53'"))
        #expect(!merged.contains("#PROXY"))
    }

    @Test("default-nameserver entries are never tagged")
    func defaultNameserverUntouched() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Group
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 223.5.5.5"))
        #expect(!merged.contains("223.5.5.5#"))
    }

    @Test("Re-merge retargets a previously retargeted header")
    func remergeRetargetsStaleTag() {
        let firstSub = """
        proxies:
          - {name: a, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: OldGroup
            type: select
            proxies:
              - a
        """
        let secondSub = """
        proxies:
          - {name: b, type: vless, server: 5.6.7.8, port: 443}
        proxy-groups:
          - name: NewGroup
            type: select
            proxies:
              - b
        """
        let first = ConfigManager.mergeSubscription(
            firstSub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        // Second merge uses the first merge's output as base, the same way
        // applySelectedSubscription reuses the on-disk config as base.
        let second = ConfigManager.mergeSubscription(
            secondSub, baseConfig: first, defaultConfig: Self.taggedBase
        )
        #expect(second.contains("- 'tcp://1.1.1.1:53#NewGroup'"))
        #expect(!second.contains("OldGroup'"))
    }

    @Test("tls:// nameserver fragments (SNI) are left untouched")
    func tlsSNIFragmentUntouched() {
        let base = """
        dns:
          enable: true
          nameserver:
            - 'tls://1.1.1.1:853#cloudflare-dns.com'
        proxies: []
        """
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Group
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: base, defaultConfig: base
        )
        #expect(merged.contains("- 'tls://1.1.1.1:853#cloudflare-dns.com'"))
    }

    @Test("Group names containing single quotes are YAML-escaped")
    func escapesSingleQuotesInGroupName() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: "It's Fast"
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.taggedBase, defaultConfig: Self.taggedBase
        )
        #expect(merged.contains("- 'tcp://1.1.1.1:53#It''s Fast'"))
    }
}

@Suite("Proxy group serialization")
struct ProxyGroupSerializationTests {

    @Test("Quotes editable proxy group string values")
    func quotesEditableProxyGroupStringValues() {
        let groups = [
            EditableProxyGroup(
                name: "Node # chooser",
                type: "select",
                proxies: ["proxy: one", "line\nbreak"],
                url: "https://example.com/health?x=1#frag",
                interval: 300
            )
        ]

        let yaml = ConfigManager.shared.updateProxyGroups(
            groups,
            in: "rules:\n  - MATCH,DIRECT"
        )

        #expect(yaml.contains("  - name: \"Node # chooser\""))
        #expect(yaml.contains("    url: \"https://example.com/health?x=1#frag\""))
        #expect(yaml.contains("      - \"proxy: one\""))
        #expect(yaml.contains("      - \"line\\nbreak\""))

        let parsed = ConfigManager.shared.parseProxyGroups(from: yaml)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "Node # chooser")
        #expect(parsed[0].proxies == ["proxy: one", "line\nbreak"])
    }

    @Test("Global proxy group quotes selected node and replaces previous group")
    func globalProxyGroupQuotesSelectedNodeAndReplacesPreviousGroup() {
        let defaults = AppConstants.sharedDefaults
        let previous = defaults.string(forKey: "selectedNode")
        defer {
            if let previous {
                defaults.set(previous, forKey: "selectedNode")
            } else {
                defaults.removeObject(forKey: "selectedNode")
            }
        }
        defaults.set("node #1\nnext", forKey: "selectedNode")

        let yaml = """
        proxy-groups:
          - name: "GLOBAL"
            type: select
            proxies:
              - old
          - name: PROXY
            type: select
            proxies:
              - node #1
        rules:
          - MATCH,PROXY
        """

        let updated = ConfigManager.shared.updateGlobalProxyGroup(yaml, enabled: true)
        let globalNameCount = updated.components(separatedBy: "name: \"GLOBAL\"").count - 1

        #expect(globalNameCount == 1)
        #expect(updated.contains("      - \"node #1\\nnext\""))
        #expect(!updated.contains("      - old"))
    }

}

@Suite("Proxy server hostname rewrite")
struct ProxyServerHostnameRewriteTests {

    @Test("Rewrites only exact server scalar matches")
    func rewritesOnlyExactServerScalarMatches() {
        let yaml = """
        proxies:
          - name: exact
            server: example.com
          - name: prefix
            server: example.com.hk
          - name: quoted
            server: "example.com"
          - name: single-quoted
            server: 'example.com'
          - name: comment
            server: example.com # pre-resolved at startup
          - name: different-key
            servername: example.com
        """

        let rewritten = ConfigManager.rewriteProxyServerHostnames(
            in: yaml,
            hostToIP: ["example.com": "93.184.216.34"]
        )

        #expect(rewritten.contains("server: 93.184.216.34\n"))
        #expect(rewritten.contains("server: example.com.hk"))
        #expect(rewritten.contains("server: \"93.184.216.34\""))
        #expect(rewritten.contains("server: '93.184.216.34'"))
        #expect(rewritten.contains("server: 93.184.216.34 # pre-resolved at startup"))
        #expect(rewritten.contains("servername: example.com"))
        #expect(!rewritten.contains("93.184.216.34.hk"))
    }

    @Test("Leaves unknown server values unchanged")
    func leavesUnknownServerValuesUnchanged() {
        let yaml = """
        proxies:
          - name: untouched
            server: other.example
        """

        let rewritten = ConfigManager.rewriteProxyServerHostnames(
            in: yaml,
            hostToIP: ["example.com": "93.184.216.34"]
        )

        #expect(rewritten == yaml)
    }
}

@Suite("Rule serialization")
struct RuleSerializationTests {

    @Test("Quotes rule strings containing comment characters")
    func quotesRuleStringsContainingCommentCharacters() throws {
        let rules = [
            EditableRule(
                type: "MATCH",
                value: "",
                target: "Group #1",
                noResolve: false
            ),
            EditableRule(
                type: "DOMAIN-SUFFIX",
                value: "example.com",
                target: "Proxy #2",
                noResolve: false
            ),
        ]

        let yaml = ConfigManager.shared.updateRules(rules, in: "proxies: []")

        #expect(yaml.contains("  - \"MATCH,Group #1\""))
        #expect(yaml.contains("  - \"DOMAIN-SUFFIX,example.com,Proxy #2\""))

        let parsed = ConfigManager.shared.parseRules(from: yaml)
        #expect(parsed.count == 2)
        #expect(parsed[0].target == "Group #1")
        #expect(parsed[1].target == "Proxy #2")
    }

    @Test("Preserves no-resolve marker when quoting rules")
    func preservesNoResolveMarkerWhenQuotingRules() {
        let rules = [
            EditableRule(
                type: "IP-CIDR",
                value: "10.0.0.0/8",
                target: "DIRECT",
                noResolve: true
            )
        ]

        let yaml = ConfigManager.shared.updateRules(rules, in: "proxies: []")
        let parsed = ConfigManager.shared.parseRules(from: yaml)

        #expect(yaml.contains("  - \"IP-CIDR,10.0.0.0/8,DIRECT,no-resolve\""))
        #expect(parsed.first?.noResolve == true)
    }
}

// MARK: - Sanitize Config

@Suite("sanitizeConfigString")
struct SanitizeConfigStringTests {

    @Test("Disables geo-auto-update")
    func disablesGeoAutoUpdate() {
        var config = """
        geo-auto-update: true
        dns:
          enable: true
        """
        ConfigManager.sanitizeConfigString(&config)
        #expect(config.contains("geo-auto-update: false"))
        #expect(!config.contains("geo-auto-update: true"))
    }

    @Test("Disables TUN mode")
    func disablesTUN() {
        var config = """
        tun:
          enable: true
          stack: system
        dns:
          enable: true
        """
        ConfigManager.sanitizeConfigString(&config)
        #expect(config.contains("enable: false"))
    }

    @Test("TUN disable does not affect DNS enable")
    func tunDisableDoesNotAffectDNS() {
        var config = """
        tun:
          enable: true
        dns:
          enable: true
        """
        ConfigManager.sanitizeConfigString(&config)
        let lines = config.components(separatedBy: "\n")
        // Find the dns section and check its enable is still true
        var inDNS = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasPrefix("dns:") {
                inDNS = true
                continue
            }
            if inDNS && !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                break
            }
            if inDNS && trimmed.hasPrefix("enable:") {
                #expect(trimmed.contains("true"))
            }
        }
    }

    @Test("Strips subscriptions section")
    func stripsSubscriptions() {
        var config = """
        port: 7890
        subscriptions:
          - url: https://example.com
            interval: 3600
        dns:
          enable: true
        """
        ConfigManager.sanitizeConfigString(&config)
        #expect(!config.contains("subscriptions:"))
        #expect(!config.contains("example.com"))
        #expect(config.contains("dns:"))
    }

    @Test("Config without TUN or geo-update is unchanged")
    func noopWhenNothingToSanitize() {
        var config = """
        port: 7890
        dns:
          enable: true
        """
        let original = config
        ConfigManager.sanitizeConfigString(&config)
        #expect(config == original)
    }
}

// MARK: - Provider sanitization (untrusted subscription input)

@Suite("sanitizeProviders")
struct SanitizeProvidersTests {

    @Test("Preserves a valid https provider with a safe relative path")
    func preservesValidProvider() {
        let section = """
        proxy-providers:
          provider1:
            type: http
            url: https://example.com/sub.yaml
            path: ./providers/provider1.yaml
            interval: 3600
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(result.contains("provider1:"))
        #expect(result.contains("url: https://example.com/sub.yaml"))
        // A safe relative path (no `..`, not absolute/home) is left untouched.
        #expect(result.contains("path: ./providers/provider1.yaml"))
        #expect(result.contains("interval: 3600"))
    }

    @Test("Drops a provider whose url scheme isn't https")
    func dropsNonHttpsUrl() {
        let section = """
        proxy-providers:
          bad:
            type: http
            url: http://evil.com/sub.yaml
            path: ./providers/bad.yaml
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(!result.contains("evil.com"))
        #expect(!result.contains("bad:"))
        // Only the (now childless) section header remains.
        #expect(result.contains("proxy-providers:"))
    }

    @Test("Drops a provider with a file:// url")
    func dropsFileUrl() {
        let section = """
        proxy-providers:
          exfil:
            url: file:///etc/passwd
            path: ./providers/exfil.yaml
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(!result.contains("file://"))
        #expect(!result.contains("exfil"))
    }

    @Test("Rewrites a path-traversal path to a safe basename")
    func rewritesPathTraversal() {
        let section = """
        proxy-providers:
          trav:
            url: https://example.com/sub.yaml
            path: ../../Library/LaunchAgents/evil.plist
        """
        let result = ConfigManager.sanitizeProviders(section)
        // Provider survives (url is https) but the escaping path is neutralized.
        #expect(result.contains("trav:"))
        #expect(result.contains("url: https://example.com/sub.yaml"))
        #expect(!result.contains(".."))
        #expect(!result.contains("LaunchAgents"))
        #expect(result.contains("path: \"evil.plist\""))
    }

    @Test("Rewrites an absolute path to a safe basename")
    func rewritesAbsolutePath() {
        let section = """
        proxy-providers:
          abs:
            url: https://example.com/sub.yaml
            path: /Library/LaunchAgents/x.plist
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(result.contains("abs:"))
        #expect(!result.contains("/Library/LaunchAgents"))
        #expect(result.contains("path: \"x.plist\""))
    }

    @Test("Keeps the good provider and drops the malicious one")
    func keepsGoodDropsBad() {
        let section = """
        proxy-providers:
          good:
            url: https://example.com/good.yaml
            path: ./providers/good.yaml
          bad:
            url: http://attacker/steal
            path: ./providers/bad.yaml
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(result.contains("good:"))
        #expect(result.contains("https://example.com/good.yaml"))
        #expect(!result.contains("attacker"))
        #expect(!result.contains("bad:"))
    }

    @Test("Applies to rule-providers sections too")
    func sanitizesRuleProviders() {
        let section = """
        rule-providers:
          rules1:
            type: http
            url: http://insecure/rules.yaml
            path: ./ruleset/rules1.yaml
        """
        let result = ConfigManager.sanitizeProviders(section)
        #expect(!result.contains("insecure"))
        #expect(!result.contains("rules1:"))
        #expect(result.contains("rule-providers:"))
    }
}

// MARK: - Config Scalar Updates

@Suite("Config top-level scalar replacement")
struct ConfigTopLevelScalarReplacementTests {

    @Test("Updates only the top-level mode key")
    func updatesOnlyTopLevelMode() {
        let yaml = """
        mode: rule
        dns:
          enhanced-mode: redir-host
        proxies:
          - name: obfs-node
            type: ss
            server: 1.2.3.4
            port: 8388
            plugin: obfs
            plugin-opts:
              mode: websocket
        """

        let updated = ConfigManager.replacingTopLevelScalar(
            in: yaml, key: "mode", value: "global"
        )

        #expect(updated.contains("mode: global"))
        #expect(updated.contains("enhanced-mode: redir-host"))
        #expect(updated.contains("mode: websocket"))
        #expect(!updated.contains("mode: rule"))
    }

    @Test("Updates only the top-level log-level key")
    func updatesOnlyTopLevelLogLevel() {
        let yaml = """
        log-level: info
        proxy-providers:
          demo:
            type: http
            log-level: debug
            url: https://example.com/sub.yaml
        """

        let updated = ConfigManager.replacingTopLevelScalar(
            in: yaml, key: "log-level", value: "error"
        )

        #expect(updated.hasPrefix("log-level: error"))
        #expect(updated.contains("    log-level: debug"))
        #expect(!updated.contains("log-level: info"))
    }
}

// MARK: - Subscription Parser (URI Lists)

@Suite("Subscription Fetch Response")
struct SubscriptionFetchResponseTests {

    @Test("Rejects non-success HTTP status")
    func rejectsNonSuccessHTTPStatus() throws {
        let url = try #require(URL(string: "https://example.com/sub"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        ))

        do {
            _ = try HomeView.parseFetchedSubscription(data: Data("forbidden".utf8), response: response)
            #expect(Bool(false), "Expected badServerResponse")
        } catch let error as URLError {
            #expect(error.code == .badServerResponse)
        } catch {
            #expect(Bool(false), "Expected URLError, got \(error)")
        }
    }

    @Test("Parses successful URI response")
    func parsesSuccessfulURIResponse() throws {
        let url = try #require(URL(string: "https://example.com/sub"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Node1"

        let result = try HomeView.parseFetchedSubscription(data: Data(uri.utf8), response: response)

        #expect(result.nodes.count == 1)
        #expect(result.nodes.first?.name == "Node1")
        #expect(result.raw.contains("proxies:"))
    }
}

@Suite("SubscriptionParser URI list")
struct SubscriptionParserURITests {

    @Test("Parses base64-encoded vless URI list")
    func parsesBase64VlessList() {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws&host=example.com&sni=example.com&path=/proxy#TestNode"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].name == "TestNode")
        #expect(result.nodes[0].type == "vless")
        #expect(result.nodes[0].server == "1.2.3.4")
        #expect(result.generatedYAML != nil)
    }

    @Test("Generated YAML has top-level proxies and proxy-groups")
    func generatedYAMLHasTopLevelSections() {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Node1"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        let yaml = result.generatedYAML!

        // Verify sections are at column 0 (no leading whitespace)
        let lines = yaml.components(separatedBy: "\n")
        let proxiesLine = lines.first { $0.hasPrefix("proxies:") }
        let groupsLine = lines.first { $0.hasPrefix("proxy-groups:") }
        #expect(proxiesLine != nil)
        #expect(groupsLine != nil)
    }

    @Test("Generated YAML contains PROXY select group")
    func generatedYAMLHasPROXYGroup() {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Node1"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        let yaml = result.generatedYAML!

        #expect(yaml.contains("name: PROXY"))
        #expect(yaml.contains("type: select"))
    }

    @Test("Generated YAML sections extractable by extractYAMLSections")
    func generatedYAMLExtractable() {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Node1"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        let yaml = result.generatedYAML!

        let sections = ConfigManager.extractYAMLSections(
            from: yaml, named: ["proxies", "proxy-groups"]
        )
        #expect(sections["proxies"] != nil)
        #expect(sections["proxy-groups"] != nil)
        #expect(sections["proxy-groups"]!.contains("PROXY"))
    }

    @Test("Parses multiple URIs with deduplication")
    func parsesMultipleURIs() {
        let uris = [
            "vless://uuid@1.2.3.4:443?security=tls&type=ws#SameName",
            "vless://uuid@5.6.7.8:443?security=tls&type=ws#SameName",
            "trojan://password@9.10.11.12:443?security=tls#DifferentName",
        ].joined(separator: "\n")
        let base64 = Data(uris.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        #expect(result.nodes.count == 3)
        // Deduplicated names
        let names = result.nodes.map(\.name)
        #expect(names[0] == "SameName")
        #expect(names[1] == "SameName (2)")
        #expect(names[2] == "DifferentName")
    }

    @Test("Parses raw (non-base64) URI list")
    func parsesRawURIList() {
        let uris = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Node1\nvless://uuid@5.6.7.8:443?security=tls&type=ws#Node2"
        let result = SubscriptionParser.parseWithYAML(uris)
        #expect(result.nodes.count == 2)
        #expect(result.generatedYAML != nil)
    }

    @Test("URI query values are decoded and YAML-quoted")
    func queryValuesDecodedAndQuoted() throws {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws&host=edge.example%20%23comment&path=%2Fproxy%3Fx%3Da%3Db%25#Node1"

        let result = SubscriptionParser.parseWithYAML(uri)
        let yaml = try #require(result.generatedYAML)

        #expect(yaml.contains("server: \"1.2.3.4\""))
        #expect(yaml.contains("uuid: \"uuid\""))
        #expect(yaml.contains("path: \"/proxy?x=a=b%\""))
        #expect(yaml.contains("Host: \"edge.example #comment\""))
    }

    @Test("URI query values may contain question marks")
    func queryValuesMayContainQuestionMarks() throws {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws&host=edge.example&path=/proxy?x=a=b#Node1"

        let result = SubscriptionParser.parseWithYAML(uri)
        let yaml = try #require(result.generatedYAML)

        #expect(yaml.contains("path: \"/proxy?x=a=b\""))
        #expect(yaml.contains("Host: \"edge.example\""))
    }

    @Test("Unsupported network query does not inject YAML")
    func unsupportedNetworkQueryDoesNotInjectYAML() throws {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws%0A%20%20%20%20injected:%20true#Node1"

        let result = SubscriptionParser.parseWithYAML(uri)
        let yaml = try #require(result.generatedYAML)

        #expect(yaml.contains("network: tcp"))
        #expect(!yaml.contains("injected: true"))
    }

    @Test("Raw shadowsocks user info splits at final at-sign")
    func rawShadowsocksUserInfoSplitsAtFinalAtSign() throws {
        let uri = "ss://aes-128-gcm:pa@ss@1.2.3.4:8388#Node1"

        let result = SubscriptionParser.parseWithYAML(uri)
        let yaml = try #require(result.generatedYAML)

        #expect(result.nodes.count == 1)
        #expect(yaml.contains("cipher: \"aes-128-gcm\""))
        #expect(yaml.contains("password: \"pa@ss\""))
    }

    @Test("Parses URL-safe unpadded vmess payload")
    func parsesURLSafeUnpaddedVmessPayload() throws {
        let json = """
        {"v":"2","ps":"VMess Node","add":"1.2.3.4","port":"443","id":"uuid","aid":"0","net":"ws","type":"none","host":"edge.example","path":"/ws","tls":"tls","sni":"edge.example"}
        """
        let payload = Self.urlSafeUnpaddedBase64(json)
        let result = SubscriptionParser.parseWithYAML("vmess://\(payload)")
        let yaml = try #require(result.generatedYAML)

        #expect(result.nodes.count == 1)
        #expect(result.nodes.first?.name == "VMess Node")
        #expect(yaml.contains("network: ws"))
        #expect(yaml.contains("Host: \"edge.example\""))
    }

    @Test("Parses unpadded shadowsocks user info")
    func parsesUnpaddedShadowsocksUserInfo() throws {
        let userInfo = Self.urlSafeUnpaddedBase64("aes-128-gcm:password")
        let result = SubscriptionParser.parseWithYAML("ss://\(userInfo)@1.2.3.4:8388#SSNode")
        let yaml = try #require(result.generatedYAML)

        #expect(result.nodes.count == 1)
        #expect(yaml.contains("cipher: \"aes-128-gcm\""))
        #expect(yaml.contains("password: \"password\""))
    }

    @Test("Clash YAML subscription returns nil generatedYAML")
    func clashYAMLReturnsNilGenerated() {
        let yaml = """
        proxies:
          - {name: node1, type: vless, server: 1.2.3.4, port: 443}
        """
        let result = SubscriptionParser.parseWithYAML(yaml)
        #expect(result.nodes.count == 1)
        #expect(result.generatedYAML == nil)
    }

    @Test("Unsupported URI schemes are skipped")
    func skipsUnsupportedSchemes() {
        let uris = "vless://uuid@1.2.3.4:443?security=tls&type=ws#Good\nhysteria2://bad@5.6.7.8:443#Unsupported"
        let result = SubscriptionParser.parseWithYAML(uris)
        #expect(result.nodes.count == 1)
        #expect(result.nodes[0].name == "Good")
    }

    @Test("Empty input returns zero nodes")
    func emptyInputZeroNodes() {
        let result = SubscriptionParser.parseWithYAML("")
        #expect(result.nodes.isEmpty)
        #expect(result.generatedYAML == nil)
    }

    private static func urlSafeUnpaddedBase64(_ text: String) -> String {
        Data(text.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

// MARK: - Subscription Parser (YAML)

@Suite("SubscriptionParser YAML")
struct SubscriptionParserYAMLTests {

    @Test("Parses flow-style proxy entries")
    func parsesFlowStyle() {
        let yaml = """
        proxies:
          - {name: node1, type: vless, server: 1.2.3.4, port: 443}
          - {name: node2, type: trojan, server: 5.6.7.8, port: 443}
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 2)
        #expect(nodes[0].name == "node1")
        #expect(nodes[0].type == "vless")
        #expect(nodes[1].name == "node2")
        #expect(nodes[1].type == "trojan")
    }

    @Test("Parses block-style proxy entries")
    func parsesBlockStyle() {
        let yaml = """
        proxies:
          -
            name: mynode
            type: ss
            server: 10.0.0.1
            port: 8388
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "mynode")
        #expect(nodes[0].server == "10.0.0.1")
    }

    @Test("Stops at next top-level section")
    func stopsAtNextSection() {
        let yaml = """
        proxies:
          - {name: node1, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: PROXY
        rules:
          - MATCH,DIRECT
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)
    }

    @Test("Missing required fields skips node")
    func missingFieldsSkipsNode() {
        let yaml = """
        proxies:
          - {name: incomplete, type: vless}
          - {name: good, type: vless, server: 1.2.3.4, port: 443}
        """
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)
        #expect(nodes[0].name == "good")
    }

    @Test("Handles CRLF line endings")
    func handlesCRLF() {
        let yaml = "proxies:\r\n  - {name: node1, type: vless, server: 1.2.3.4, port: 443}\r\nrules:\r\n  - MATCH,DIRECT"
        let nodes = SubscriptionParser.parse(yaml)
        #expect(nodes.count == 1)
    }
}

// MARK: - End-to-End: URI List -> Merge -> Validate

@Suite("URI subscription end-to-end merge")
struct URISubscriptionE2ETests {

    @Test("URI list merged config has PROXY group matching rules")
    func uriListMergedConfigConsistent() {
        let uri = "vless://uuid@1.2.3.4:443?security=tls&type=ws#TestNode"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        let generatedYAML = result.generatedYAML!

        let defaultCfg = ConfigManager.shared.defaultConfig()
        let merged = ConfigManager.mergeSubscription(
            generatedYAML, baseConfig: defaultCfg, defaultConfig: defaultCfg
        )

        // The merged config should have the PROXY group from generated YAML
        let sections = ConfigManager.extractYAMLSections(
            from: merged, named: ["proxy-groups", "rules"]
        )
        #expect(sections["proxy-groups"]!.contains("PROXY"))
        // Rules reference PROXY and the group exists — config is self-consistent
        #expect(sections["rules"]!.contains("PROXY"))
    }

    @Test("Clash YAML subscription with custom group names merges correctly")
    func clashYAMLCustomGroupNames() {
        let sub = """
        proxies:
          - {name: node1, type: vless, server: 1.2.3.4, port: 443, uuid: test}
        proxy-groups:
          - name: Proxies
            type: select
            proxies:
              - node1
        rules:
          - DOMAIN-SUFFIX,example.com,Proxies
          - MATCH,DIRECT
        """
        let defaultCfg = ConfigManager.shared.defaultConfig()
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: defaultCfg, defaultConfig: defaultCfg
        )

        // Should use subscription's rules (referencing "Proxies"), not default rules (referencing "PROXY")
        #expect(merged.contains("example.com,Proxies"))
        #expect(!merged.contains("MATCH,PROXY"))
    }
}

// MARK: - Bundled Geodata

@Suite("Bundled geodata")
struct BundledGeodataTests {

    @Test("Copies embedded provider geodata without network fallback")
    func copiesEmbeddedProviderGeodata() throws {
        let tempDir = NSTemporaryDirectory() + "bld-geodata-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        for file in ConfigManager.geodataFiles {
            let bundled = try #require(
                ConfigManager.bundledGeodataURL(name: file.name, ext: file.ext),
                "Expected bundled \(file.name).\(file.ext) to be discoverable"
            )
            #expect(FileManager.default.fileExists(atPath: bundled.path))
        }

        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)

        for file in ConfigManager.geodataFiles {
            let copied = URL(fileURLWithPath: tempDir)
                .appendingPathComponent("\(file.name).\(file.ext)")
            #expect(FileManager.default.fileExists(atPath: copied.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: copied.path)
            let size = try #require(attributes[.size] as? NSNumber)
            #expect(size.intValue > 0)
        }
    }
}
