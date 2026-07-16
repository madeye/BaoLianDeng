// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation

enum PerAppProxyMode: String, Codable, CaseIterable {
    case allowlist
    case blocklist
}

struct PerAppEntry: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let bundlePath: String
}

struct PerAppProxySettings: Codable {
    var enabled: Bool = false
    var mode: PerAppProxyMode = .blocklist
    var apps: [PerAppEntry] = []

    /// Returns true if traffic from the given bundle ID should be proxied.
    func shouldProxy(bundleID: String, knownBundleIDs: Set<String>) -> Bool {
        guard enabled else { return true }
        let isInList = knownBundleIDs.contains(bundleID)
        switch mode {
        case .allowlist:
            return isInList
        case .blocklist:
            return !isInList
        }
    }
}
