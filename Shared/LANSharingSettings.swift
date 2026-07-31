// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation

/// Side-router (LAN sharing) settings. When enabled, the engine additionally
/// binds a mixed SOCKS5/HTTP listener and (optionally) a DNS server on
/// `0.0.0.0`, so other devices on the local network can use this Mac as
/// their proxy server and DNS resolver. Stored as JSON in shared
/// UserDefaults and forwarded to the extension via providerConfiguration.
struct LANSharingSettings: Codable, Equatable {
    static let defaultProxyPort = 7890
    static let defaultDNSPort = 53

    var enabled: Bool = false
    var proxyPort: Int = LANSharingSettings.defaultProxyPort
    var dnsEnabled: Bool = true
    var dnsPort: Int = LANSharingSettings.defaultDNSPort

    init() {}

    /// Tolerant decoding: missing keys (older saves, forward compatibility)
    /// fall back to defaults instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort)
            ?? Self.defaultProxyPort
        dnsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dnsEnabled) ?? true
        dnsPort = try container.decodeIfPresent(Int.self, forKey: .dnsPort)
            ?? Self.defaultDNSPort
    }

    /// Port actually used for the LAN proxy listener — out-of-range values
    /// (e.g. a half-typed field) fall back to the default.
    var effectiveProxyPort: Int {
        (1...65535).contains(proxyPort) ? proxyPort : Self.defaultProxyPort
    }

    /// Port actually used for the LAN DNS server, with the same clamping.
    var effectiveDNSPort: Int {
        (1...65535).contains(dnsPort) ? dnsPort : Self.defaultDNSPort
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
