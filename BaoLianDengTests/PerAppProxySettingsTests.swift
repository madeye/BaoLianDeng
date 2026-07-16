// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
@testable import BaoLianDeng

// MARK: - Data Model Tests

@Suite("PerAppProxySettings Data Model")
struct PerAppProxySettingsModelTests {

    @Test("Default settings have correct values")
    func defaultSettings() {
        let settings = PerAppProxySettings()
        #expect(settings.enabled == false)
        #expect(settings.mode == .blocklist)
        #expect(settings.apps.isEmpty)
    }

    @Test("JSON round-trip preserves all fields")
    func jsonRoundTrip() throws {
        var settings = PerAppProxySettings()
        settings.enabled = true
        settings.mode = .allowlist
        settings.apps = [
            PerAppEntry(
                bundleID: "com.apple.Safari",
                displayName: "Safari",
                bundlePath: "/Applications/Safari.app"
            ),
            PerAppEntry(
                bundleID: "com.google.Chrome",
                displayName: "Google Chrome",
                bundlePath: "/Applications/Google Chrome.app"
            )
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(
            PerAppProxySettings.self, from: data
        )

        #expect(decoded.enabled == true)
        #expect(decoded.mode == .allowlist)
        #expect(decoded.apps.count == 2)
        #expect(decoded.apps[0].bundleID == "com.apple.Safari")
        #expect(decoded.apps[0].displayName == "Safari")
        #expect(decoded.apps[0].bundlePath == "/Applications/Safari.app")
        #expect(decoded.apps[1].bundleID == "com.google.Chrome")
    }

    @Test("Empty apps list round-trips correctly")
    func emptyAppsRoundTrip() throws {
        let settings = PerAppProxySettings(
            enabled: true, mode: .blocklist, apps: []
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(
            PerAppProxySettings.self, from: data
        )

        #expect(decoded.enabled == true)
        #expect(decoded.mode == .blocklist)
        #expect(decoded.apps.isEmpty)
    }
}

// MARK: - PerAppEntry Tests

@Suite("PerAppEntry")
struct PerAppEntryTests {

    @Test("id is derived from bundleID")
    func idIsBundleID() {
        let entry = PerAppEntry(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            bundlePath: "/Applications/Safari.app"
        )
        #expect(entry.id == "com.apple.Safari")
    }

    @Test("Equatable compares all stored fields")
    func equatable() {
        let entry1 = PerAppEntry(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            bundlePath: "/Applications/Safari.app"
        )
        let entry2 = PerAppEntry(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            bundlePath: "/Applications/Safari.app"
        )
        let entry3 = PerAppEntry(
            bundleID: "com.apple.Safari",
            displayName: "Different",
            bundlePath: "/Applications/Safari.app"
        )
        #expect(entry1 == entry2)
        #expect(entry1 != entry3)
    }
}

// MARK: - Filtering Logic Tests

@Suite("Per-App Proxy Filtering")
struct PerAppProxyFilteringTests {

    static let safari = PerAppEntry(
        bundleID: "com.apple.Safari",
        displayName: "Safari",
        bundlePath: "/Applications/Safari.app"
    )
    static let chrome = PerAppEntry(
        bundleID: "com.google.Chrome",
        displayName: "Chrome",
        bundlePath: "/Applications/Google Chrome.app"
    )

    private func makeSettings(
        enabled: Bool, mode: PerAppProxyMode, apps: [PerAppEntry]
    ) -> (PerAppProxySettings, Set<String>) {
        let settings = PerAppProxySettings(
            enabled: enabled, mode: mode, apps: apps
        )
        let idSet = Set(apps.map(\.bundleID))
        return (settings, idSet)
    }

    // MARK: Disabled

    @Test("When disabled, all apps are proxied")
    func disabledProxiesAll() {
        let (settings, idSet) = makeSettings(
            enabled: false, mode: .blocklist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "com.unknown.App", knownBundleIDs: idSet
        ) == true)
    }

    // MARK: Blocklist Mode

    @Test("Blocklist: listed apps bypass proxy")
    func blocklistBypassesListed() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == false)
    }

    @Test("Blocklist: unlisted apps are proxied")
    func blocklistProxiesUnlisted() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == true)
    }

    @Test("Blocklist: empty list proxies everything")
    func blocklistEmptyProxiesAll() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist, apps: []
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == true)
    }

    @Test("Blocklist: multiple apps all bypass")
    func blocklistMultipleApps() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist,
            apps: [Self.safari, Self.chrome]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == false)
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == false)
        #expect(settings.shouldProxy(
            bundleID: "com.other.App", knownBundleIDs: idSet
        ) == true)
    }

    // MARK: Allowlist Mode

    @Test("Allowlist: listed apps are proxied")
    func allowlistProxiesListed() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .allowlist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == true)
    }

    @Test("Allowlist: unlisted apps bypass proxy")
    func allowlistBypassesUnlisted() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .allowlist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == false)
    }

    @Test("Allowlist: empty list bypasses everything")
    func allowlistEmptyBypassesAll() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .allowlist, apps: []
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == false)
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == false)
    }

    @Test("Allowlist: multiple apps all proxied")
    func allowlistMultipleApps() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .allowlist,
            apps: [Self.safari, Self.chrome]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "com.google.Chrome", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "com.other.App", knownBundleIDs: idSet
        ) == false)
    }

    // MARK: Edge Cases

    @Test("Bundle ID matching is case-sensitive")
    func caseSensitive() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "com.apple.Safari", knownBundleIDs: idSet
        ) == false)
        #expect(settings.shouldProxy(
            bundleID: "com.apple.safari", knownBundleIDs: idSet
        ) == true)
        #expect(settings.shouldProxy(
            bundleID: "COM.APPLE.SAFARI", knownBundleIDs: idSet
        ) == true)
    }

    @Test("Empty bundle ID is handled")
    func emptyBundleID() {
        let (settings, idSet) = makeSettings(
            enabled: true, mode: .blocklist, apps: [Self.safari]
        )
        #expect(settings.shouldProxy(
            bundleID: "", knownBundleIDs: idSet
        ) == true)
    }
}

// MARK: - Mode Enum Tests

@Suite("PerAppProxyMode")
struct PerAppProxyModeTests {

    @Test("Raw values match expected strings")
    func rawValues() {
        #expect(PerAppProxyMode.allowlist.rawValue == "allowlist")
        #expect(PerAppProxyMode.blocklist.rawValue == "blocklist")
    }

    @Test("CaseIterable contains both modes")
    func allCases() {
        #expect(PerAppProxyMode.allCases.count == 2)
        #expect(PerAppProxyMode.allCases.contains(.allowlist))
        #expect(PerAppProxyMode.allCases.contains(.blocklist))
    }
}
