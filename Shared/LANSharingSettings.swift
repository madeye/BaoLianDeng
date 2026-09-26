// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation

/// "Allow LAN" settings. When enabled, the effective engine config gets
/// Clash-compatible `allow-lan: true`, `bind-address: 0.0.0.0`, and
/// `mixed-port: <proxyPort>` so other devices on the local network can use
/// this Mac as their SOCKS5/HTTP proxy. Stored as JSON in shared UserDefaults;
/// applied in `ConfigManager.buildEffectiveConfig` (no separate FFI path).
struct LANSharingSettings: Codable, Equatable {
    static let defaultProxyPort = 7890

    var enabled: Bool = false
    var proxyPort: Int = LANSharingSettings.defaultProxyPort

    init() {}

    /// Tolerant decoding: missing keys (older saves, forward compatibility)
    /// fall back to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort)
            ?? Self.defaultProxyPort
    }

    /// Port actually used for the LAN proxy listener — out-of-range values
    /// (e.g. a half-typed field) fall back to the default.
    var effectiveProxyPort: Int {
        (1...65535).contains(proxyPort) ? proxyPort : Self.defaultProxyPort
    }

    static func load(from defaults: UserDefaults = AppConstants.sharedDefaults) -> LANSharingSettings {
        guard let data = defaults.data(forKey: AppConstants.lanSharingSettingsKey),
              let decoded = try? JSONDecoder().decode(LANSharingSettings.self, from: data)
        else { return LANSharingSettings() }
        return decoded
    }

    func save(to defaults: UserDefaults = AppConstants.sharedDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: AppConstants.lanSharingSettingsKey)
    }
}
