// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
import Yams
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

    @Test("Merged config forces fake-ip invariants on the base dns block")
    func mergedHasManagedDNS() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("enhanced-mode: fake-ip"))
        #expect(merged.contains("fake-ip-range: 28.0.0.0/8"))
    }

    @Test("Subscription dns nameservers survive merge")
    func subscriptionDNSPreserved() {
        let sub = """
        dns:
          enable: true
          enhanced-mode: redir-host
          nameserver:
            - https://doh.pub/dns-query
          fallback:
            - https://1.1.1.1/dns-query
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("https://doh.pub/dns-query"))
        #expect(merged.contains("https://1.1.1.1/dns-query"))
        #expect(merged.contains("enhanced-mode: fake-ip"))
        #expect(merged.contains("fake-ip-range: 28.0.0.0/8"))
        #expect(!merged.contains("redir-host"))
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

    @Test("Proxies-only subscription gets a PROXY group defaulting to DIRECT")
    func missingPROXYFallsBackToDIRECT() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        let proxy = groups.first { $0.name == "PROXY" }
        #expect(proxy != nil)
        #expect(proxy?.type == "select")
        #expect(proxy?.proxies.first == "DIRECT")
        #expect(proxy?.proxies.contains("node") == true)
        #expect(merged.contains("MATCH,PROXY"))
    }

    @Test("Existing PROXY group is left unchanged")
    func existingPROXYPreserved() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - node
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        let proxyGroups = groups.filter { $0.name == "PROXY" }
        #expect(proxyGroups.count == 1)
        #expect(proxyGroups[0].proxies == ["node"])
    }

    @Test("Custom groups without PROXY keep their extra fields when fallback is injected")
    func injectsPROXYWithoutRewritingOtherGroups() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Proxies
            type: select
            icon: https://example.com/icon.png
            proxies:
              - node
        rules:
          - DOMAIN-SUFFIX,example.com,Proxies
          - MATCH,PROXY
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        #expect(merged.contains("icon: https://example.com/icon.png"))
        #expect(merged.contains("example.com,Proxies"))
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        #expect(groups.contains { $0.name == "Proxies" })
        let proxy = groups.first { $0.name == "PROXY" }
        #expect(proxy?.proxies.first == "DIRECT")
    }

    @Test("Subscription shipping its own rules and groups gets no decoy PROXY")
    func noPROXYInjectedWhenNothingReferencesIt() {
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
          - GEOIP,CN,DIRECT
          - MATCH,Proxies
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        #expect(groups.contains { $0.name == "Proxies" })
        #expect(!groups.contains { $0.name == "PROXY" })
    }

    @Test("A rule target of PROXY still triggers the fallback")
    func ruleTargetTriggersFallback() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Proxies
            type: select
            proxies:
              - node
        rules:
          - IP-CIDR,91.108.0.0/16,PROXY,no-resolve
          - MATCH,Proxies
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        #expect(groups.first { $0.name == "PROXY" }?.proxies.first == "DIRECT")
    }

    @Test("A group listing PROXY as a member still triggers the fallback")
    func groupMemberTriggersFallback() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: Proxies
            type: select
            proxies:
              - PROXY
              - node
        rules:
          - MATCH,Proxies
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        #expect(groups.first { $0.name == "PROXY" }?.proxies.first == "DIRECT")
    }

    @Test("no-resolve is not mistaken for a rule target")
    func noResolveIsNotATarget() {
        let sub = """
        proxies:
          - {name: node, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - name: no-resolve
            type: select
            proxies:
              - node
        rules:
          - IP-CIDR,1.2.3.0/24,Proxies,no-resolve
          - MATCH,Proxies
        """
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: Self.baseConfig, defaultConfig: Self.defaultConfig
        )
        // `no-resolve` is a modifier on the rule above, not a target, so the
        // group of that name is not what keeps PROXY from being injected.
        let groups = ConfigManager.shared.parseProxyGroups(from: merged)
        #expect(!groups.contains { $0.name == "PROXY" })
    }
}

// MARK: - Managed DNS

@Suite("forceManagedDNS")
struct ForceManagedDNSTests {

    @Test("Forces fake-ip invariants but keeps the original nameservers")
    func forcesFakeIpButKeepsNameservers() {
        var config = """
        mixed-port: 7890
        mode: rule
        dns:
          enable: true
          listen: 127.0.0.1:1053
          enhanced-mode: redir-host
          nameserver:
            - 'tcp://1.1.1.1:53#PROXY'
        proxies: []
        rules:
          - MATCH,DIRECT
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(config.contains("enhanced-mode: fake-ip"))
        #expect(config.contains("fake-ip-range: 28.0.0.0/8"))
        #expect(config.contains("listen: 127.0.0.1:0"))
        #expect(!config.contains("redir-host"))
        #expect(config.contains("tcp://1.1.1.1:53#PROXY"))
        let dnsIdx = config.range(of: "dns:")!.lowerBound
        let proxiesIdx = config.range(of: "proxies: []")!.lowerBound
        #expect(dnsIdx < proxiesIdx)
    }

    @Test("Inserts a dns block when the config has none")
    func insertsWhenMissing() {
        var config = "mode: rule\nproxies: []\nrules:\n  - MATCH,DIRECT"
        ConfigManager.forceManagedDNS(&config)
        #expect(config.contains("enhanced-mode: fake-ip"))
    }

    @Test("Drops proxy-server-nameserver entries that point at the old listen address")
    func dropsSelfReferentialProxyServerNameserver() {
        // Nexitally-style export: proxy server hostnames resolve through the
        // client's own DNS listener. The engine moves that listener to an
        // ephemeral port, so the self-reference must go or every node
        // hostname lookup dies against a dead loopback port.
        var config = """
        mixed-port: 7890
        dns:
          enable: true
          listen: 127.0.0.1:7874
          proxy-server-nameserver:
            - udp://127.0.0.1:7874
          default-nameserver:
            - 223.5.5.5
          nameserver:
            - https://doh.example/dns-query
        proxies: []
        rules:
          - MATCH,DIRECT
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(!config.contains("proxy-server-nameserver"))
        #expect(!config.contains("7874"))
        #expect(config.contains("listen: 127.0.0.1:0"))
        #expect(config.contains("https://doh.example/dns-query"))
        #expect(config.contains("223.5.5.5"))
    }

    @Test("Keeps proxy-server-nameserver entries pointing at a real resolver")
    func keepsExternalProxyServerNameserver() {
        var config = """
        dns:
          enable: true
          listen: 127.0.0.1:7874
          proxy-server-nameserver:
            - 223.5.5.5
            - udp://127.0.0.1:7874
          nameserver:
            - 1.1.1.1
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(config.contains("proxy-server-nameserver:"))
        #expect(config.contains("- 223.5.5.5"))
        #expect(!config.contains("7874"))
    }

    @Test("Drops an inline self-referential proxy-server-nameserver list")
    func dropsInlineSelfReferentialList() {
        var config = """
        dns:
          enable: true
          listen: 127.0.0.1:7874
          proxy-server-nameserver: [udp://127.0.0.1:7874]
          nameserver:
            - 1.1.1.1
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(!config.contains("proxy-server-nameserver"))
    }

    @Test("Self-reference drop is idempotent")
    func selfReferenceDropIdempotent() {
        var config = """
        dns:
          enable: true
          listen: 127.0.0.1:7874
          proxy-server-nameserver:
            - udp://127.0.0.1:7874
          nameserver:
            - 1.1.1.1
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        let once = config
        ConfigManager.forceManagedDNS(&config)
        #expect(config == once)
    }

    @Test("Drops a stale loopback proxy-server-nameserver after listen was already rewritten")
    func dropsStaleLoopbackAfterListenRewrite() {
        // Saved by a build that had already forced listen to an ephemeral
        // port: no original port left to match against, yet the loopback
        // pointer is still dead and must go.
        var config = """
        dns:
          enable: true
          listen: 127.0.0.1:0
          proxy-server-nameserver:
            - udp://127.0.0.1:7874
          default-nameserver:
            - 223.5.5.5
          nameserver:
            - https://doh.example/dns-query
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(!config.contains("proxy-server-nameserver"))
        #expect(!config.contains("7874"))
        #expect(config.contains("223.5.5.5"))
    }

    @Test("Idempotent on an already-managed config")
    func idempotent() {
        var config = "mixed-port: 7890\n\(ConfigManager.managedDNSSection)\nproxies: []\n"
        ConfigManager.forceManagedDNS(&config)
        let once = config
        ConfigManager.forceManagedDNS(&config)
        #expect(config == once)
        #expect(config.components(separatedBy: "dns:").count - 1 == 1)
    }

    @Test("Comments inside the dns section are kept")
    func preservesCommentsInSection() {
        var config = """
        dns:
          enable: true
        # stray comment inside the section
          enhanced-mode: redir-host
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(!config.contains("redir-host"))
        #expect(config.contains("stray comment"))
        #expect(config.contains("enhanced-mode: fake-ip"))
    }

    @Test("Local proxy mode replaces fake-ip with redir-host")
    func localProxyUsesRedirHost() {
        var config = """
        mixed-port: 7890
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.0/15
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config, engineMode: .localProxy)
        #expect(config.contains("enhanced-mode: redir-host"))
        #expect(!config.contains("enhanced-mode: fake-ip"))
        #expect(!config.contains("fake-ip-range"))
    }

    @Test("Keeps fallback and nameserver-policy from the original block")
    func keepsFallbackAndPolicy() {
        var config = """
        dns:
          enable: false
          nameserver:
            - https://doh.pub/dns-query
          fallback:
            - https://1.1.1.1/dns-query
          nameserver-policy:
            'geosite:cn': 223.5.5.5
          fake-ip-filter:
            - '*.lan'
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config)
        #expect(config.contains("enable: true"))
        #expect(config.contains("https://doh.pub/dns-query"))
        #expect(config.contains("https://1.1.1.1/dns-query"))
        #expect(config.contains("geosite:cn"))
        #expect(config.contains("*.lan"))
        #expect(config.contains("enhanced-mode: fake-ip"))
        #expect(config.contains("fake-ip-range: 28.0.0.0/8"))
    }

    @Test("Inserting listen does not steal nameserver list items")
    func listenInsertDoesNotSplitNameserver() {
        var config = """
        dns:
          enable: true
          nameserver:
            - https://doh.pub/dns-query
            - https://dns.alidns.com/dns-query
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config, engineMode: .localProxy)
        #expect(config.contains("listen: 127.0.0.1:0"))
        #expect(config.contains("https://doh.pub/dns-query"))
        #expect(config.contains("https://dns.alidns.com/dns-query"))
        #expect(!config.contains("127.0.0.1:0 - https://"))
        let nameserverIdx = config.range(of: "nameserver:")!.lowerBound
        let listenIdx = config.range(of: "listen:")!.lowerBound
        let dohIdx = config.range(of: "https://doh.pub/dns-query")!.lowerBound
        #expect(listenIdx < nameserverIdx)
        #expect(nameserverIdx < dohIdx)
    }

    @Test("Heals a listen line that split nameserver from its list")
    func healsSplitNameserverList() {
        var config = """
        dns:
          enable: true
          nameserver:
          listen: 127.0.0.1:0
            - https://doh.pub/dns-query
            - https://dns.alidns.com/dns-query
        proxies: []
        """
        ConfigManager.forceManagedDNS(&config, engineMode: .localProxy)
        #expect(config.contains("listen: 127.0.0.1:0"))
        #expect(!config.contains("127.0.0.1:0 - https://"))
        let nameserverIdx = config.range(of: "nameserver:")!.lowerBound
        let dohIdx = config.range(of: "https://doh.pub/dns-query")!.lowerBound
        let listenIdx = config.range(of: "listen:")!.lowerBound
        #expect(nameserverIdx < dohIdx)
        // listen must not sit between nameserver: and its list items
        #expect(!(nameserverIdx < listenIdx && listenIdx < dohIdx))
    }

    @Test("Idempotent in local proxy mode")
    func idempotentLocalProxy() {
        var config = "mixed-port: 7890\n\(ConfigManager.managedLocalProxyDNSSection)\nproxies: []\n"
        ConfigManager.forceManagedDNS(&config, engineMode: .localProxy)
        let once = config
        ConfigManager.forceManagedDNS(&config, engineMode: .localProxy)
        #expect(config == once)
        #expect(config.components(separatedBy: "dns:").count - 1 == 1)
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

    @Test("Sanitizing an already-sanitized config is a no-op")
    func noopWhenNothingToSanitize() {
        var config = "port: 7890\n\(ConfigManager.managedDNSSection)\n"
        ConfigManager.sanitizeConfigString(&config)
        let sanitized = config
        ConfigManager.sanitizeConfigString(&config)
        #expect(config == sanitized)
    }

    @Test("Local proxy mode disables fake-ip DNS and TUN")
    func localProxyDisablesFakeIPAndTUN() {
        var config = "tun:\n  enable: true\n  stack: system\n"
            + ConfigManager.managedDNSSection + "\nproxies: []\n"
        ConfigManager.sanitizeConfigString(&config, engineMode: .localProxy)
        #expect(config.contains("enhanced-mode: redir-host"))
        #expect(!config.contains("enhanced-mode: fake-ip"))
        #expect(!config.contains("fake-ip-range"))
        #expect(config.contains("tun:\n  enable: false"))
        #expect(!config.contains("enable: true\n  stack"))
    }

    @Test("Injects an explicit disabled tun block when absent")
    func injectsDisabledTunBlock() {
        var config = "mode: rule\nproxies: []\nrules:\n  - MATCH,DIRECT"
        ConfigManager.sanitizeConfigString(&config, engineMode: .localProxy)
        #expect(config.contains("tun:\n  enable: false"))
        // Idempotent: a second pass doesn't add another block.
        let once = config
        ConfigManager.sanitizeConfigString(&config, engineMode: .localProxy)
        #expect(config == once)
        #expect(config.components(separatedBy: "tun:").count - 1 == 1)
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
          enhanced-mode: fake-ip
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
        #expect(updated.contains("enhanced-mode: fake-ip"))
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

// MARK: - Effective config (issue #113)

/// Regression coverage for madeye/BaoLianDeng#113: startup must run the
/// user's saved `config.yaml`, not a rebuilt default / subscription merge.
@Suite("buildEffectiveConfig")
struct BuildEffectiveConfigTests {

    /// A base the Config Editor could have saved: custom proxy, custom rule,
    /// and a user-chosen DNS nameserver list.
    static let editedBase = """
    mixed-port: 0
    mode: rule
    log-level: info
    allow-lan: false
    bind-address: 127.0.0.1
    external-controller: 127.0.0.1:0

    geo-auto-update: false

    dns:
      enable: true
      listen: 127.0.0.1:0
      enhanced-mode: fake-ip
      fake-ip-range: 28.0.0.0/8
      nameserver:
        - https://my.custom.dns/dns-query

    proxies:
      - {name: my-ss, type: ss, server: 10.9.8.7, port: 8388, cipher: aes-128-gcm, password: pw}

    proxy-groups:
      - name: PROXY
        type: select
        proxies:
          - my-ss
          - DIRECT

    rules:
      - DOMAIN-SUFFIX,my-custom-domain.example,PROXY
      - MATCH,DIRECT
    """

    private func build(
        _ base: String,
        engineMode: EngineMode = .vpn,
        logLevel: String? = nil,
        proxyMode: String = "rule",
        lan: LANSharingSettings = LANSharingSettings(),
        localProxyPort: UInt16 = 7890
    ) -> String {
        ConfigManager.buildEffectiveConfig(
            base: base, engineMode: engineMode,
            settings: EngineRuntimeSettings(
                logLevel: logLevel, proxyMode: proxyMode,
                lanSharing: lan, localProxyPort: localProxyPort
            )
        )
    }

    @Test("Custom proxies, rules and DNS from the saved base survive (no subscription)")
    func keepsUserEditsWithoutSubscription() {
        let effective = build(Self.editedBase)
        #expect(effective.contains("name: my-ss"))
        #expect(effective.contains("DOMAIN-SUFFIX,my-custom-domain.example,PROXY"))
        #expect(effective.contains("https://my.custom.dns/dns-query"))
        // The built-in default rule set must not have been substituted in.
        #expect(!effective.contains("DOMAIN-SUFFIX,google.com,PROXY"))
        #expect(!effective.contains("MATCH,PROXY"))
    }

    @Test("Edits made on top of a merged subscription survive reconnect")
    func keepsUserEditsOnTopOfSubscription() {
        let sub = """
        proxies:
          - {name: sub-node, type: vless, server: 1.2.3.4, port: 443, uuid: u}
        proxy-groups:
          - name: Proxies
            type: select
            proxies:
              - sub-node
        rules:
          - DOMAIN-SUFFIX,example.com,Proxies
          - MATCH,DIRECT
        """
        let defaultCfg = ConfigManager.shared.defaultConfig()
        // Selecting the subscription merges it INTO config.yaml …
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: defaultCfg, defaultConfig: defaultCfg
        )
        // … and the user then adds a rule and a nameserver in the editor.
        var edited = merged.replacingOccurrences(
            of: "  - DOMAIN-SUFFIX,example.com,Proxies",
            with: "  - DOMAIN-KEYWORD,user-added,Proxies\n  - DOMAIN-SUFFIX,example.com,Proxies"
        )
        edited = edited.replacingOccurrences(
            of: "  nameserver:\n",
            with: "  nameserver:\n    - tls://user.dns.example\n"
        )
        #expect(edited.contains("DOMAIN-KEYWORD,user-added,Proxies"))
        #expect(edited.contains("tls://user.dns.example"))

        let effective = build(edited)
        #expect(effective.contains("name: sub-node"))
        #expect(effective.contains("DOMAIN-KEYWORD,user-added,Proxies"))
        #expect(effective.contains("DOMAIN-SUFFIX,example.com,Proxies"))
        #expect(effective.contains("tls://user.dns.example"))
    }

    @Test("Runtime settings are layered on without touching user sections")
    func appliesRuntimeSettings() {
        let lan = LANSharingSettings()
        let effective = build(
            Self.editedBase, logLevel: "debug", proxyMode: "global", lan: lan
        )
        #expect(effective.contains("log-level: debug"))
        #expect(effective.contains("mode: global"))
        #expect(effective.contains("allow-lan: false"))
        #expect(effective.contains("name: my-ss"))

        var lanOn = LANSharingSettings()
        lanOn.enabled = true
        lanOn.proxyPort = 17890
        let shared = build(Self.editedBase, lan: lanOn)
        #expect(shared.contains("allow-lan: true"))
        #expect(shared.contains("bind-address: 0.0.0.0"))
        #expect(shared.contains("mixed-port: 17890"))

        let local = build(Self.editedBase, engineMode: .localProxy, localProxyPort: 7891)
        #expect(local.contains("mixed-port: 7891"))
    }

    @Test("Engine-mode DNS invariants are re-applied to a base saved in the other mode")
    func reappliesDNSInvariantsForCurrentMode() {
        // editedBase was saved while in VPN mode (fake-ip).
        let local = build(Self.editedBase, engineMode: .localProxy)
        #expect(local.contains("enhanced-mode: redir-host"))
        #expect(!local.contains("fake-ip-range"))
        #expect(local.contains("https://my.custom.dns/dns-query"))

        let vpn = build(Self.editedBase, engineMode: .vpn)
        #expect(vpn.contains("enhanced-mode: fake-ip"))
        #expect(vpn.contains("fake-ip-range: 28.0.0.0/8"))
    }

    @Test("Sanitizer invariants hold on the effective config")
    func sanitizerInvariants() throws {
        let base = """
        mode: rule
        tun:
          enable: true
        geo-auto-update: true
        subscriptions:
          - url: https://example.com/sub
        proxies: []
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,PROXY
        """
        let effective = build(base)
        let parsed = try #require(try Yams.load(yaml: effective) as? [String: Any])
        let tun = try #require(parsed["tun"] as? [String: Any])
        #expect(tun["enable"] as? Bool == false)
        #expect(effective.contains("geo-auto-update: false"))
        #expect(!effective.contains("subscriptions:"))
        // No dns: block in the base → the managed fallback is inserted.
        #expect(effective.contains("enhanced-mode: fake-ip"))
    }

    @Test("A PROXY group is injected when the base's rules dangle on it")
    func injectsProxyFallback() {
        let base = """
        mode: rule
        proxies:
          - {name: n1, type: ss, server: 1.1.1.1, port: 1, cipher: aes-128-gcm, password: p}
        rules:
          - MATCH,PROXY
        """
        let effective = build(base)
        let groups = ConfigManager.shared.parseProxyGroups(from: effective)
        #expect(groups.contains { $0.name == "PROXY" })
    }
}

@Suite("Local proxy runtime directory")
struct RuntimeDirectoryTests {

    @Test("Preparing the runtime directory never rewrites the saved config.yaml")
    func doesNotClobberSavedConfig() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bld-runtime-test-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("mihomo", isDirectory: true)
        let runtimeDir = configDir.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let saved = "# user's saved config\nmode: rule\nproxies: []\n"
        let savedURL = configDir.appendingPathComponent(AppConstants.configFileName)
        try saved.write(to: savedURL, atomically: true, encoding: .utf8)

        // A stand-in geodata file (any size) should get linked in beside the
        // derived YAML.
        let geoName = "\(ConfigManager.geodataFiles[0].name).\(ConfigManager.geodataFiles[0].ext)"
        try Data("geo".utf8).write(to: configDir.appendingPathComponent(geoName))

        let derived = "mode: global\nlog-level: debug\nproxies: []\n"
        try ConfigManager.prepareRuntimeDirectory(
            at: runtimeDir, geodataDir: configDir, runtimeYAML: derived
        )

        #expect(try String(contentsOf: savedURL, encoding: .utf8) == saved)
        let runtimeConfig = runtimeDir.appendingPathComponent(AppConstants.configFileName)
        #expect(try String(contentsOf: runtimeConfig, encoding: .utf8) == derived)
        #expect(FileManager.default.fileExists(atPath: runtimeDir.appendingPathComponent(geoName).path))

        // Re-preparing (next start) replaces the derived file and re-links
        // geodata without erroring on the existing entries.
        try Data("geo-v2".utf8).write(to: configDir.appendingPathComponent(geoName))
        try ConfigManager.prepareRuntimeDirectory(
            at: runtimeDir, geodataDir: configDir, runtimeYAML: derived + "allow-lan: true\n"
        )
        #expect(try String(contentsOf: savedURL, encoding: .utf8) == saved)
        #expect(try Data(contentsOf: runtimeDir.appendingPathComponent(geoName)) == Data("geo-v2".utf8))
    }

    @Test("Runtime directory is a child of the config directory, distinct from config.yaml")
    func runtimeDirectoryLayout() throws {
        let configDir = try #require(ConfigManager.shared.configDirectoryURL)
        let runtimeDir = try #require(ConfigManager.shared.runtimeDirectoryURL)
        #expect(runtimeDir.deletingLastPathComponent().standardizedFileURL == configDir.standardizedFileURL)
        #expect(runtimeDir.appendingPathComponent(AppConstants.configFileName) != ConfigManager.shared.configFileURL)
    }
}
