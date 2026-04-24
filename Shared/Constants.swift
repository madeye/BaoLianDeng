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

enum AppConstants {
    static let appGroupIdentifier: String? = nil
    static let tunnelBundleIdentifier = "io.github.baoliandeng.macos.TransparentProxy"
    static let configFileName = "config.yaml"
    static let externalControllerAddr = "127.0.0.1:9090"
    static let dailyTrafficKey = "dailyTrafficRecords"
    static let subscriptionUsageKey = "subscriptionUsageRecords"
    static let perAppProxySettingsKey = "perAppProxySettings"
    static let autoStartVPNAtLoginKey = "autoStartVPNAtLogin"

    /// Shared UserDefaults via app group suite.
    static var sharedDefaults: UserDefaults {
        if let group = appGroupIdentifier {
            return UserDefaults(suiteName: group) ?? .standard
        }
        return .standard
    }
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule = "rule"
    case global = "global"
    case direct = "direct"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rule: return String(localized: "Rule")
        case .global: return String(localized: "Global")
        case .direct: return String(localized: "Direct")
        }
    }
}
