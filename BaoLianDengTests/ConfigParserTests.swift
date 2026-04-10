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

// MARK: - Subscription Parser (URI Lists)

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
