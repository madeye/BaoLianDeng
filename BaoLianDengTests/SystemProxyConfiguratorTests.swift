// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import XCTest
@testable import BaoLianDeng

final class SystemProxyConfiguratorTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "SystemProxyConfiguratorTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private let listOutput = """
        An asterisk (*) denotes that a network service is disabled.
        Ethernet
        *Thunderbolt Bridge
        Wi-Fi
        Tailscale

        """

    // MARK: - Pure helpers

    func testParseServiceNamesSkipsLegendAndDisabledServices() {
        XCTAssertEqual(
            SystemProxyConfigurator.parseServiceNames(from: listOutput),
            ["Ethernet", "Wi-Fi", "Tailscale"]
        )
    }

    func testApplyArgumentsCoverHTTPHTTPSAndSOCKSPerService() {
        let args = SystemProxyConfigurator.applyArguments(
            services: ["Wi-Fi", "Ethernet"], host: "127.0.0.1", port: 7890
        )
        XCTAssertEqual(args, [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "7890"],
            ["-setwebproxy", "Ethernet", "127.0.0.1", "7890"],
            ["-setsecurewebproxy", "Ethernet", "127.0.0.1", "7890"],
            ["-setsocksfirewallproxy", "Ethernet", "127.0.0.1", "7890"]
        ])
    }

    func testClearArgumentsSwitchEverythingOff() {
        XCTAssertEqual(SystemProxyConfigurator.clearArguments(services: ["Wi-Fi"]), [
            ["-setwebproxystate", "Wi-Fi", "off"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "off"]
        ])
    }

    // MARK: - Apply / clear flow with a fake networksetup

    private func makeConfigurator(
        failing: Set<String> = [],
        calls: @escaping ([String]) -> Void
    ) -> SystemProxyConfigurator {
        SystemProxyConfigurator(defaults: defaults) { [listOutput] args in
            calls(args)
            if args == ["-listallnetworkservices"] { return listOutput }
            if failing.contains(args[0]) { return "** Error: The parameters were not valid." }
            return ""
        }
    }

    func testApplyRunsCommandsForEnabledServicesAndMarksApplied() throws {
        var calls: [[String]] = []
        let configurator = makeConfigurator { calls.append($0) }

        try configurator.apply(port: 7890)

        XCTAssertTrue(configurator.isApplied)
        XCTAssertEqual(calls.first, ["-listallnetworkservices"])
        let proxyCalls = calls.dropFirst()
        XCTAssertEqual(proxyCalls.count, 3 * 3)
        XCTAssertTrue(proxyCalls.contains(["-setsocksfirewallproxy", "Tailscale", "127.0.0.1", "7890"]))
        XCTAssertFalse(proxyCalls.contains { $0.contains("Thunderbolt Bridge") })
    }

    func testClearSwitchesOffAndResetsApplied() throws {
        var calls: [[String]] = []
        let configurator = makeConfigurator { calls.append($0) }
        try configurator.apply(port: 7890)
        calls.removeAll()

        try configurator.clear()

        XCTAssertFalse(configurator.isApplied)
        XCTAssertEqual(calls.dropFirst().count, 3 * 3)
        XCTAssertTrue(calls.contains(["-setwebproxystate", "Wi-Fi", "off"]))
    }

    func testErrorOutputFailsApplyButKeepsAppliedFlagForCleanup() {
        let configurator = makeConfigurator(failing: ["-setsecurewebproxy"]) { _ in }

        XCTAssertThrowsError(try configurator.apply(port: 7890))
        XCTAssertTrue(configurator.isApplied, "partial writes must still be cleaned up later")
    }

    func testClearKeepsAppliedFlagWhenAnyCommandFails() throws {
        let configurator = makeConfigurator(failing: ["-setsocksfirewallproxystate"]) { _ in }
        try configurator.apply(port: 7890)

        XCTAssertThrowsError(try configurator.clear())
        XCTAssertTrue(configurator.isApplied)
    }

    func testClearIfStaleIsNoOpWhenNothingApplied() {
        var calls: [[String]] = []
        let configurator = makeConfigurator { calls.append($0) }

        configurator.clearIfStale()

        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: - Real networksetup (opt-in)

    /// Drives the real `networksetup` from the test host. Changes the host's
    /// proxy settings for a moment, so it only runs with
    /// `TEST_RUNNER_BLD_SYSTEM_PROXY_INTEGRATION=1`. Note the CI-style
    /// unsigned test host is not sandboxed; the in-sandbox behaviour was
    /// verified by hand from a signed Debug build.
    func testRealNetworksetupAppliesAndClearsSystemProxy() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["BLD_SYSTEM_PROXY_INTEGRATION"] == "1",
            "set TEST_RUNNER_BLD_SYSTEM_PROXY_INTEGRATION=1 to run against the real networksetup"
        )
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        print("SystemProxy integration: test host sandboxed=\(sandboxed)")

        let services = SystemProxyConfigurator.parseServiceNames(
            from: try SystemProxyConfigurator.runNetworksetup(["-listallnetworkservices"])
        )
        let service = try XCTUnwrap(services.first)
        let configurator = SystemProxyConfigurator(defaults: defaults)

        try configurator.apply(port: 7890)
        let during = try SystemProxyConfigurator.runNetworksetup(["-getsocksfirewallproxy", service])
        XCTAssertTrue(during.contains("Enabled: Yes"), during)
        XCTAssertTrue(during.contains("Port: 7890"), during)

        try configurator.clear()
        let after = try SystemProxyConfigurator.runNetworksetup(["-getwebproxy", service])
        XCTAssertTrue(after.contains("Enabled: No"), after)
        XCTAssertFalse(configurator.isApplied)
    }

    func testClearIfStaleClearsLeftoverFromPreviousRun() {
        defaults.set(true, forKey: AppConstants.systemProxyAppliedKey)
        var calls: [[String]] = []
        let configurator = makeConfigurator { calls.append($0) }

        configurator.clearIfStale()

        XCTAssertFalse(configurator.isApplied)
        XCTAssertTrue(calls.contains(["-setwebproxystate", "Ethernet", "off"]))
    }
}
