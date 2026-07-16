// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Security

enum AppConstants {
    static let appGroupIdentifier: String? = nil
    static let tunnelBundleIdentifier = "io.github.baoliandeng.macos.TransparentProxy"
    static let configFileName = "config.yaml"
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    /// UserDefaults key. The extension writes the live `host:port` of the
    /// mihomo REST controller here at startup; the main app reads it when
    /// hitting `/proxies`, `/connections`, etc. Updated each tunnel start
    /// because the port is auto-picked.
    static let externalControllerAddrKey = "externalControllerAddr"
    /// UserDefaults key. The main app generates a random per-session secret
    /// when it picks the controller port and stores it here; the extension
    /// reads it from `providerConfiguration` and starts mihomo's REST API
    /// with it, and the app's REST clients send it as `Authorization: Bearer`.
    /// Empty/absent means "no auth" (legacy behaviour) — callers should still
    /// send whatever is present.
    static let externalControllerSecretKey = "externalControllerSecret"
    static let dailyTrafficKey = "dailyTrafficRecords"
    static let subscriptionUsageKey = "subscriptionUsageRecords"
    static let perAppProxySettingsKey = "perAppProxySettings"
    static let autoStartVPNAtLoginKey = "autoStartVPNAtLogin"

    /// Live mihomo REST controller address (`host:port`). Returns nil when
    /// the tunnel hasn't run yet this install — callers should treat that
    /// as "controller unavailable" rather than poke a hardcoded fallback,
    /// which would just hit whatever foreign mihomo happens to own 9090.
    static var externalControllerAddr: String? {
        sharedDefaults.string(forKey: externalControllerAddrKey)
    }

    /// Live mihomo REST controller secret, or nil when none has been
    /// generated yet. Paired with `externalControllerAddr`.
    static var externalControllerSecret: String? {
        let secret = sharedDefaults.string(forKey: externalControllerSecretKey)
        return (secret?.isEmpty ?? true) ? nil : secret
    }

    /// Generate a fresh cryptographically-random controller secret (32 hex
    /// chars from 16 random bytes). Returns a non-empty string on success,
    /// or nil if the system RNG fails.
    static func generateControllerSecret() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a URLRequest for the controller, attaching the `Authorization:
    /// Bearer <secret>` header when a secret is available. All REST clients
    /// (`MihomoAPI`, `VPNManager`, `ProxyGroupsViewModel`) must route through
    /// this so the header is applied uniformly.
    static func authorizedControllerRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let secret = externalControllerSecret {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func externalControllerURL(pathSegments: [String], queryItems: [URLQueryItem] = []) -> URL? {
        guard let addr = externalControllerAddr, !addr.isEmpty else {
            return nil
        }
        return externalControllerURL(controllerAddr: addr, pathSegments: pathSegments, queryItems: queryItems)
    }

    static func externalControllerURL(
        controllerAddr addr: String,
        pathSegments: [String],
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard !addr.isEmpty,
              var components = URLComponents(string: "http://\(addr)") else {
            return nil
        }
        components.percentEncodedPath = "/" + pathSegments
            .map { $0.addingPercentEncoding(withAllowedCharacters: controllerPathSegmentAllowed) ?? $0 }
            .joined(separator: "/")
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    /// Shared UserDefaults via app group suite.
    static var sharedDefaults: UserDefaults {
        if let group = appGroupIdentifier {
            return UserDefaults(suiteName: group) ?? .standard
        }
        return .standard
    }

    private static let controllerPathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "%/?#[]@!$&'()*+,;=")
        return allowed
    }()
}

/// Pick a free 127.0.0.1 port by binding a SOCK_STREAM socket to port 0,
/// reading the assigned port, then closing. There's a small TOCTOU
/// window before the next consumer binds, but the ephemeral port space
/// is large enough that collisions are rare in practice.
///
/// `kind` selects whether we pick from the TCP or UDP namespace. SOCKS5
/// and the REST controller want TCP; mihomo's DNS server binds UDP +
/// TCP on the same port, so for DNS we pick UDP-first then verify TCP
/// is also free at that port.
enum EphemeralPort {
    static func pickTCP() -> UInt16? {
        pick(type: SOCK_STREAM, proto: IPPROTO_TCP)
    }

    /// Returns a port that is currently free on BOTH UDP and TCP at
    /// 127.0.0.1. Mihomo's DNS server needs both protocols on the same
    /// port; picking from only one namespace can leave us shadowed by an
    /// unrelated listener on the other.
    static func pickDNS(retries: Int = 8) -> UInt16? {
        for _ in 0..<retries {
            guard let port = pick(type: SOCK_DGRAM, proto: IPPROTO_UDP) else { return nil }
            if bindThenClose(type: SOCK_STREAM, proto: IPPROTO_TCP, port: port) {
                return port
            }
        }
        return nil
    }

    private static func pick(type: Int32, proto: Int32) -> UInt16? {
        let fd = socket(AF_INET, type, proto)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                bind(fd, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return nil }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getOK = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                getsockname(fd, saptr, &len)
            }
        }
        guard getOK == 0 else { return nil }
        return UInt16(bigEndian: bound.sin_port)
    }

    private static func bindThenClose(type: Int32, proto: Int32, port: UInt16) -> Bool {
        let fd = socket(AF_INET, type, proto)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                bind(fd, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindOK == 0
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
