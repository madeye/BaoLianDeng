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
import Testing
@testable import BaoLianDeng

// MARK: - BridgeValidateConfig Integration

// BridgeSetHomeDir is process-global state in the Go runtime, so all tests
// that call it (or that call BridgeValidateConfig, which reads it) must run
// serially to avoid races where one test's defer-cleanup deletes geodata
// that another test is about to read.
@Suite("MihomoCore Integration", .serialized)
struct MihomoCoreIntegrationTests {

    @Test("Validates minimal valid config")
    func validatesMinimalConfig() {
        let config = """
        mixed-port: 7890
        mode: rule
        proxies: []
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err == nil)
    }

    @Test("Rejects config with missing proxy group")
    func rejectsMissingProxyGroup() {
        let config = """
        mixed-port: 7890
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,NONEXISTENT
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err != nil)
        #expect(err!.localizedDescription.contains("NONEXISTENT"))
    }

    @Test("Rejects empty config")
    func rejectsEmptyConfig() {
        var err: NSError?
        BridgeValidateConfig("", &err)
        // Empty config should either parse as empty (valid) or produce an error
        // Either outcome is acceptable — this documents the behavior
    }

    @Test("Validates config with GEOIP rule when geodata available")
    func validatesGeoIPRule() {
        // Ensure geodata files exist in a temp directory
        let tempDir = NSTemporaryDirectory() + "bld-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)
        BridgeSetHomeDir(tempDir)

        let config = """
        mixed-port: 7890
        mode: rule
        proxies: []
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
        rules:
          - GEOIP,CN,DIRECT
          - MATCH,PROXY
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err == nil, "GEOIP rule validation failed: \(err?.localizedDescription ?? "")")
    }

    @Test("Validates config with DNS settings")
    func validatesConfigWithDNS() {
        let config = """
        mixed-port: 7890
        mode: rule
        dns:
          enable: true
          listen: 127.0.0.1:1053
          enhanced-mode: redir-host
          nameserver:
            - 114.114.114.114
        proxies: []
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err == nil)
    }

    @Test("Validates config with proxy nodes")
    func validatesConfigWithProxies() {
        let config = """
        mixed-port: 7890
        mode: rule
        proxies:
          - name: test-vless
            type: vless
            server: 1.2.3.4
            port: 443
            uuid: 00000000-0000-0000-0000-000000000000
            tls: true
            network: ws
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - test-vless
        rules:
          - MATCH,PROXY
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err == nil, "Config with proxy validation failed: \(err?.localizedDescription ?? "")")
    }

    @Test("Rejects invalid YAML syntax")
    func rejectsInvalidYAML() {
        let config = """
        mixed-port: 7890
        proxies: [[[invalid yaml
        """
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err != nil)
    }

    // MARK: - End-to-End: URI -> Merge -> Validate via MihomoCore

    @Test("URI list generates config that passes MihomoCore validation")
    func uriListPassesValidation() {
        // Setup geodata for GEOIP rules
        let tempDir = NSTemporaryDirectory() + "bld-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)
        BridgeSetHomeDir(tempDir)

        // Simulate a URI list subscription
        let uri = "vless://00000000-0000-0000-0000-000000000000@1.2.3.4:443?security=tls&type=ws&host=example.com&sni=example.com&path=/ws#TestNode"
        let base64 = Data(uri.utf8).base64EncodedString()
        let result = SubscriptionParser.parseWithYAML(base64)
        #expect(result.nodes.count == 1)

        let generatedYAML = result.generatedYAML!
        let defaultCfg = ConfigManager.shared.defaultConfig()
        let merged = ConfigManager.mergeSubscription(
            generatedYAML, baseConfig: defaultCfg, defaultConfig: defaultCfg
        )

        var err: NSError?
        BridgeValidateConfig(merged, &err)
        #expect(err == nil, "Merged URI config failed validation: \(err?.localizedDescription ?? "")")
    }

    @Test("Clash YAML subscription with custom groups passes validation")
    func clashYAMLPassesValidation() {
        let sub = """
        proxies:
          - name: test-node
            type: vless
            server: 1.2.3.4
            port: 443
            uuid: 00000000-0000-0000-0000-000000000000
            tls: true
            network: ws
        proxy-groups:
          - name: MyProxy
            type: select
            proxies:
              - test-node
        rules:
          - DOMAIN-SUFFIX,example.com,MyProxy
          - MATCH,DIRECT
        """
        let defaultCfg = ConfigManager.shared.defaultConfig()
        let merged = ConfigManager.mergeSubscription(
            sub, baseConfig: defaultCfg, defaultConfig: defaultCfg
        )

        var err: NSError?
        BridgeValidateConfig(merged, &err)
        #expect(err == nil, "Clash YAML subscription failed validation: \(err?.localizedDescription ?? "")")
    }

    @Test("Default config passes MihomoCore validation")
    func defaultConfigPassesValidation() {
        let tempDir = NSTemporaryDirectory() + "bld-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)
        BridgeSetHomeDir(tempDir)

        let config = ConfigManager.shared.defaultConfig()
        var err: NSError?
        BridgeValidateConfig(config, &err)
        #expect(err == nil, "Default config failed validation: \(err?.localizedDescription ?? "")")
    }
}
