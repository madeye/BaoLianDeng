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

/// Integration tests that start/stop the mihomo engine directly via bridge
/// functions — no VPN tunnel, no system extension, CI-compatible.
///
/// All engine tests must be serialized because BridgeSetHomeDir and the proxy
/// listener ports (7890, 9090) are process-global state.
@Suite("Proxy Engine Integration", .serialized)
struct ProxyEngineIntegrationTests {

    // MARK: - Engine Lifecycle

    @Test("Start engine with valid config")
    func startEngineWithConfig() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        #expect(BridgeIsRunning(), "Engine should be running after start")
    }

    @Test("External controller responds on :9090")
    func engineExternalController() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Hit the external controller REST API
        let url = URL(string: "http://127.0.0.1:9090/version")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200, "External controller should return 200")

        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(body.contains("version"), "Response should contain version info")
    }

    @Test("Stop engine cleans up")
    func stopEngine() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        ProxyEngineHelper.stop(context: ctx)

        #expect(!BridgeIsRunning(), "Engine should not be running after stop")

        // Temp directory should be cleaned up
        #expect(
            !FileManager.default.fileExists(atPath: ctx.tempDir),
            "Temp directory should be removed after stop"
        )
    }

    @Test("Rejects invalid config")
    func engineRejectsInvalidConfig() {
        do {
            let ctx = try ProxyEngineHelper.start(config: TestConfigs.invalid)
            ProxyEngineHelper.stop(context: ctx)
            Issue.record("Expected start to throw for invalid config")
        } catch {
            // Expected — invalid YAML should produce an error
            #expect(
                !error.localizedDescription.isEmpty,
                "Error should have a description"
            )
        }
    }

    @Test("Traffic metrics return values")
    func trafficMetrics() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Traffic counters should be accessible (may be zero with no actual traffic)
        let upload = BridgeGetUploadTraffic()
        let download = BridgeGetDownloadTraffic()
        #expect(upload >= 0, "Upload traffic should be non-negative")
        #expect(download >= 0, "Download traffic should be non-negative")
    }

    // MARK: - Proxy Chain

    @Test("HTTP request through SOCKS5 proxy")
    func httpRequestThroughSOCKS5() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // curl through the SOCKS5 proxy to a reliable endpoint
        let result = ProxyEngineHelper.curlThroughProxy(
            url: "http://www.gstatic.com/generate_204",
            timeout: 10
        )

        // The HTTP status code is written to stdout via --write-out
        #expect(result.exitCode == 0, "curl should exit successfully")
        #expect(result.output == "204", "Should receive HTTP 204 from gstatic")
    }

    @Test("Connection tracking via external controller")
    func connectionTracking() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Generate some traffic first
        _ = ProxyEngineHelper.curlThroughProxy(
            url: "http://www.gstatic.com/generate_204",
            timeout: 10
        )

        // Query connections endpoint
        let url = URL(string: "http://127.0.0.1:9090/connections")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200, "Connections endpoint should return 200")

        let body = String(data: data, encoding: .utf8) ?? ""
        // Response should be valid JSON with connections array
        #expect(body.contains("connections"), "Response should contain connections key")
    }

    @Test("Rules loaded from config")
    func rulesLoaded() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Query rules endpoint
        let url = URL(string: "http://127.0.0.1:9090/rules")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200, "Rules endpoint should return 200")

        // Verify response is valid JSON with a rules array
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let rules = try #require(json["rules"] as? [[String: Any]])
        #expect(!rules.isEmpty, "Rules array should not be empty")
    }
}
