// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import MihomoCore
import Testing
@testable import BaoLianDeng

/// Integration tests that start/stop the mihomo engine directly via bridge
/// functions — no VPN tunnel, no network extension, CI-compatible.
///
/// All engine tests must be serialized because BridgeSetHomeDir and the
/// proxy listener ports (chosen ephemerally per run, but still
/// process-global) are shared state.
@Suite("Proxy Engine Integration", .serialized)
struct ProxyEngineIntegrationTests {

    // MARK: - Engine Lifecycle

    @Test("Start engine with valid config")
    func startEngineWithConfig() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        #expect(BridgeIsRunning(), "Engine should be running after start")
    }

    @Test("External controller responds")
    func engineExternalController() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Hit the external controller REST API
        let url = URL(string: "http://\(ctx.controllerAddr)/version")!
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

    @Test("GLOBAL uses MATCH and follows group changes at startup and after a live switch",
          arguments: ["rule", "global"])
    func globalRouting(initialMode: String) async throws {
        let config = """
        mode: \(initialMode)
        log-level: silent
        proxies:
          - name: "000 quota remaining"
            type: socks5
            server: 127.0.0.1
            port: 1
        proxy-groups:
          - name: Proxies
            type: select
            proxies: [DIRECT, REJECT]
        rules:
          - IP-CIDR,127.0.0.0/8,DIRECT
          - MATCH,Proxies
        """
        let ctx = try ProxyEngineHelper.start(
            config: config, selectorCache: ["GLOBAL": "000 quota remaining", "Proxies": "REJECT"]
        )
        defer { ProxyEngineHelper.stop(context: ctx) }
        let target = try #require(LocalHTTPServer())
        defer { target.stop() }
        let targetURL = "http://127.0.0.1:\(target.port)/generate_204"

        let proxiesURL = try #require(URL(string: "http://\(ctx.controllerAddr)/proxies"))
        let (data, _) = try await URLSession.shared.data(from: proxiesURL)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let proxies = try #require(json["proxies"] as? [String: [String: Any]])
        #expect(proxies["GLOBAL"]?["now"] as? String == "Proxies")

        if initialMode == "rule" {
            let result = ProxyEngineHelper.curlThroughProxy(url: targetURL, socksPort: ctx.socksPort)
            #expect(result.exitCode == 0)
            #expect(result.output == "204")
            try await updateController(ctx, path: "configs", method: "PATCH", body: ["mode": "global"])
        }

        // Rule mode permits this loopback target. GLOBAL must instead follow
        // Proxies -> REJECT, proving requests actually bypass the ordinary rules.
        let rejected = ProxyEngineHelper.curlThroughProxy(url: targetURL, socksPort: ctx.socksPort)
        #expect(rejected.exitCode != 0)
        try await updateController(ctx, path: "proxies/Proxies", method: "PUT", body: ["name": "DIRECT"])
        let allowed = ProxyEngineHelper.curlThroughProxy(url: targetURL, socksPort: ctx.socksPort)
        #expect(allowed.exitCode == 0)
        #expect(allowed.output == "204")
    }

    @Test("An explicit GLOBAL selector survives engine startup")
    func explicitGlobalSelection() async throws {
        let config = TestConfigs.minimal.replacingOccurrences(
            of: "proxy-groups:",
            with: "proxy-groups:\n  - name: GLOBAL\n    type: select\n    proxies: [REJECT, DIRECT]"
        )
        let ctx = try ProxyEngineHelper.start(config: config)
        defer { ProxyEngineHelper.stop(context: ctx) }
        let url = try #require(URL(string: "http://\(ctx.controllerAddr)/proxies/GLOBAL"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let group = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(group["now"] as? String == "REJECT")
        #expect(group["all"] as? [String] == ["REJECT", "DIRECT"])
    }

    private func updateController(
        _ ctx: ProxyEngineHelper.EngineContext, path: String, method: String, body: [String: String]
    ) async throws {
        let url = try #require(URL(string: "http://\(ctx.controllerAddr)/\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect((200..<300).contains(http.statusCode))
    }

    // MARK: - Proxy Chain

    @Test("HTTP request through SOCKS5 proxy")
    func httpRequestThroughSOCKS5() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        let target = try #require(LocalHTTPServer(), "could not bind loopback HTTP target")
        defer { target.stop() }

        // `--socks5` (not `--socks5-hostname`) makes curl resolve the target
        // itself, so the engine receives a raw IPv4 literal over SOCKS5 —
        // exactly the shape the transparent proxy hands it for every TCP
        // flow. The target is local so the assertion measures the proxy
        // chain, not whether this network can reach some public host.
        let result = ProxyEngineHelper.curlThroughProxy(
            url: "http://127.0.0.1:\(target.port)/generate_204",
            socksPort: ctx.socksPort,
            timeout: 10
        )

        // The HTTP status code is written to stdout via --write-out
        #expect(result.exitCode == 0, "curl should exit successfully")
        #expect(result.output == "204", "Should receive HTTP 204 from the loopback target")
    }

    @Test("HTTP request through HTTP proxy (mixed listener)")
    func httpRequestThroughHTTPProxy() throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // The loopback listener is mixed SOCKS5+HTTP; local proxy mode
        // points apps at its HTTP side, so exercise that here.
        //
        // This one deliberately keeps a public hostname: an HTTP proxy is
        // handed the name, not an address, so this is the only test covering
        // the domain path — rule matching on a hostname and resolution
        // through the engine's own `dns:` section. Pointing it at the
        // loopback target would turn it into another IP-literal test.
        let result = ProxyEngineHelper.curlThroughHTTPProxy(
            url: "http://www.gstatic.com/generate_204",
            proxyPort: ctx.socksPort,
            timeout: 10
        )

        #expect(result.exitCode == 0, "curl should exit successfully")
        #expect(result.output == "204", "Should receive HTTP 204 from gstatic")
    }

    @Test("Connection tracking via external controller")
    func connectionTracking() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        let target = try #require(LocalHTTPServer(), "could not bind loopback HTTP target")
        defer { target.stop() }

        // Generate some traffic first — against the local target, so a
        // network that cannot reach the public internet still populates
        // /connections instead of burning the full curl timeout.
        _ = ProxyEngineHelper.curlThroughProxy(
            url: "http://127.0.0.1:\(target.port)/generate_204",
            socksPort: ctx.socksPort,
            timeout: 10
        )

        // Query connections endpoint
        let url = URL(string: "http://\(ctx.controllerAddr)/connections")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200, "Connections endpoint should return 200")

        let body = String(data: data, encoding: .utf8) ?? ""
        // Response should be valid JSON with connections array
        #expect(body.contains("connections"), "Response should contain connections key")
    }

    @Test("Secret-protected controller rejects unauthenticated reads")
    func controllerRequiresSecret() async throws {
        let secret = "test-secret-2f8c1d"
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal, controllerSecret: secret)
        defer { ProxyEngineHelper.stop(context: ctx) }

        let url = URL(string: "http://\(ctx.controllerAddr)/connections")!

        // A bare URL — what TrafficStore used to send — is refused. The rest
        // of this suite runs an open controller, so nothing else would catch
        // a REST client that forgets the header.
        let (_, bare) = try await URLSession.shared.data(from: url)
        #expect((bare as? HTTPURLResponse)?.statusCode == 401)
    }

    @Test("authorizedControllerRequest is accepted by a secret-protected controller")
    func authorizedRequestIsAccepted() async throws {
        let secret = "test-secret-9a41be"
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal, controllerSecret: secret)
        defer { ProxyEngineHelper.stop(context: ctx) }

        let defaults = AppConstants.sharedDefaults
        let priorAddr = defaults.string(forKey: AppConstants.externalControllerAddrKey)
        let priorSecret = defaults.string(forKey: AppConstants.externalControllerSecretKey)
        defaults.set(ctx.controllerAddr, forKey: AppConstants.externalControllerAddrKey)
        defaults.set(secret, forKey: AppConstants.externalControllerSecretKey)
        defer {
            defaults.set(priorAddr, forKey: AppConstants.externalControllerAddrKey)
            defaults.set(priorSecret, forKey: AppConstants.externalControllerSecretKey)
        }

        let url = try #require(AppConstants.externalControllerURL(pathSegments: ["connections"]))
        let request = AppConstants.authorizedControllerRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["connections"] != nil, "authorized read should yield a connections payload")
    }

    @MainActor
    @Test("TrafficStore counters populate against a secret-protected controller")
    func trafficStorePollsAuthenticatedController() async throws {
        let secret = "test-secret-b73e05"
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal, controllerSecret: secret)
        defer { ProxyEngineHelper.stop(context: ctx) }

        let target = try #require(LocalHTTPServer(), "could not bind loopback HTTP target")
        defer { target.stop() }

        let defaults = AppConstants.sharedDefaults
        let priorAddr = defaults.string(forKey: AppConstants.externalControllerAddrKey)
        let priorSecret = defaults.string(forKey: AppConstants.externalControllerSecretKey)
        defaults.set(ctx.controllerAddr, forKey: AppConstants.externalControllerAddrKey)
        defaults.set(secret, forKey: AppConstants.externalControllerSecretKey)
        defer {
            defaults.set(priorAddr, forKey: AppConstants.externalControllerAddrKey)
            defaults.set(priorSecret, forKey: AppConstants.externalControllerSecretKey)
        }

        _ = ProxyEngineHelper.curlThroughProxy(
            url: "http://127.0.0.1:\(target.port)/generate_204",
            socksPort: ctx.socksPort,
            timeout: 10
        )

        let store = TrafficStore.shared
        store.resetTrafficStateForTesting()
        store.startPolling()
        defer {
            store.stopPolling()
            store.resetTrafficStateForTesting()
        }

        // Poll until a sample lands. A REST client that omits the Bearer
        // header gets 401 here and the counters never leave zero — which is
        // exactly the bug that showed the UI "Zero KB" while the engine was
        // moving tens of megabytes.
        var downloaded: Int64 = 0
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 200_000_000)
            downloaded = store.sessionProxyDownload
            if downloaded > 0 { break }
        }
        #expect(downloaded > 0, "authenticated polling should report the engine's byte counters")
    }

    @Test("Rules loaded from config")
    func rulesLoaded() async throws {
        let ctx = try ProxyEngineHelper.start(config: TestConfigs.minimal)
        defer { ProxyEngineHelper.stop(context: ctx) }

        // Query rules endpoint
        let url = URL(string: "http://\(ctx.controllerAddr)/rules")!
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
