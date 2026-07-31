// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import XCTest
@testable import BaoLianDeng

final class LANSharingSettingsTests: XCTestCase {

    func testDefaults() {
        let settings = LANSharingSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.proxyPort, 7890)
    }

    func testRoundTrip() throws {
        var settings = LANSharingSettings()
        settings.enabled = true
        settings.proxyPort = 8899

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LANSharingSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testPartialJSONFallsBackToDefaults() throws {
        let json = Data(#"{"enabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(LANSharingSettings.self, from: json)
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.proxyPort, 7890)
    }

    func testEffectivePortClampsInvalidValues() {
        var settings = LANSharingSettings()
        settings.proxyPort = 0
        XCTAssertEqual(settings.effectiveProxyPort, 7890)

        settings.proxyPort = 70000
        XCTAssertEqual(settings.effectiveProxyPort, 7890)

        settings.proxyPort = 1080
        XCTAssertEqual(settings.effectiveProxyPort, 1080)
    }

    func testLoadSaveRoundTripThroughDefaults() {
        let suiteName = "LANSharingSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // No stored value → defaults.
        XCTAssertEqual(LANSharingSettings.load(from: defaults), LANSharingSettings())

        var settings = LANSharingSettings()
        settings.enabled = true
        settings.proxyPort = 1080
        settings.save(to: defaults)
        XCTAssertEqual(LANSharingSettings.load(from: defaults), settings)

        // Corrupt data → defaults, not a crash.
        defaults.set(Data("not json".utf8), forKey: AppConstants.lanSharingSettingsKey)
        XCTAssertEqual(LANSharingSettings.load(from: defaults), LANSharingSettings())
    }
}
