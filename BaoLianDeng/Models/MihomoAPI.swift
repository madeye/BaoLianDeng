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

// MARK: - Response Models

struct MihomoRule: Identifiable {
    let id: Int
    let type: String
    let payload: String
    let proxy: String
}

struct MihomoConnection: Identifiable {
    let id: String
    let host: String
    let destinationIP: String
    let destinationPort: Int
    let network: String
    let type: String
    let rule: String
    let rulePayload: String
    let chains: [String]
    let upload: Int64
    let download: Int64
    let start: Date
}

struct MihomoConnectionsResponse {
    let connections: [MihomoConnection]
    let uploadTotal: Int64
    let downloadTotal: Int64
}

struct MihomoProxyGroup: Identifiable {
    let name: String
    let type: String
    let now: String
    let all: [String]

    var id: String { name }
}

struct MihomoMemory {
    let inuse: Int64
    let oslimit: Int64
}

struct MihomoDelayResult {
    let name: String
    let delay: Int?
    let error: String?
}

// MARK: - API Service

enum MihomoAPIError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case requestFailed(String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .notConnected: return "VPN is not connected"
        case .requestFailed(let msg): return msg
        case .decodingFailed: return "Failed to decode response"
        }
    }
}

enum MihomoAPI {
    private static var baseURL: String {
        "http://\(AppConstants.externalControllerAddr)"
    }

    // MARK: - Rules

    static func fetchRules() async throws -> [MihomoRule] {
        let data = try await get("/rules")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rulesArray = json["rules"] as? [[String: Any]] else {
            throw MihomoAPIError.decodingFailed
        }
        return rulesArray.enumerated().map { index, dict in
            MihomoRule(
                id: index,
                type: dict["type"] as? String ?? "",
                payload: dict["payload"] as? String ?? "",
                proxy: dict["proxy"] as? String ?? ""
            )
        }
    }

    // MARK: - Connections

    static func fetchConnections() async throws -> MihomoConnectionsResponse {
        let data = try await get("/connections")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = json["connections"] as? [[String: Any]] else {
            throw MihomoAPIError.decodingFailed
        }

        let uploadTotal = (json["upload_total"] as? NSNumber)?.int64Value ?? 0
        let downloadTotal = (json["download_total"] as? NSNumber)?.int64Value ?? 0

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let parsed = connections.compactMap { conn -> MihomoConnection? in
            let id = conn["id"] as? String ?? UUID().uuidString
            let metadata = conn["metadata"] as? [String: Any] ?? [:]
            let host = metadata["host"] as? String ?? ""
            let destIP = metadata["destinationIP"] as? String ?? ""
            let destPort = (metadata["destinationPort"] as? String).flatMap(Int.init) ?? 0
            let network = metadata["network"] as? String ?? ""
            let type = metadata["type"] as? String ?? ""

            let rule = conn["rule"] as? String ?? ""
            let rulePayload = conn["rulePayload"] as? String ?? ""
            let chains = conn["chains"] as? [String] ?? []
            let upload = (conn["upload"] as? NSNumber)?.int64Value ?? 0
            let download = (conn["download"] as? NSNumber)?.int64Value ?? 0
            let startStr = conn["start"] as? String ?? ""
            let start = isoFormatter.date(from: startStr) ?? Date()

            return MihomoConnection(
                id: id,
                host: host,
                destinationIP: destIP,
                destinationPort: destPort,
                network: network,
                type: type,
                rule: rule,
                rulePayload: rulePayload,
                chains: chains,
                upload: upload,
                download: download,
                start: start
            )
        }

        return MihomoConnectionsResponse(
            connections: parsed,
            uploadTotal: uploadTotal,
            downloadTotal: downloadTotal
        )
    }

    static func closeConnection(_ id: String) async throws {
        try await delete("/connections/\(id)")
    }

    static func closeAllConnections() async throws {
        try await delete("/connections")
    }

    // MARK: - Proxy Groups & Providers

    static func fetchProxyGroups() async throws -> [MihomoProxyGroup] {
        let data = try await get("/proxies")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = json["proxies"] as? [String: Any] else {
            throw MihomoAPIError.decodingFailed
        }

        let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
        var groups: [MihomoProxyGroup] = []

        for (name, value) in proxies {
            guard let info = value as? [String: Any],
                  let type = info["type"] as? String,
                  groupTypes.contains(type) else { continue }
            let now = info["now"] as? String ?? ""
            let all = info["all"] as? [String] ?? []
            groups.append(MihomoProxyGroup(name: name, type: type, now: now, all: all))
        }

        return groups.sorted { $0.name < $1.name }
    }

    /// Fetch proxies result with groups and leaf proxies from /proxies endpoint.
    /// Use this for the ProxyGroupsSection UI.
    static func fetchProxiesResult() async throws -> ProxiesResult {
        let data = try await get("/proxies")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.decodingFailed
        }
        return ProxiesResult.fromAPI(json)
    }

    /// Select a proxy node within a group via PUT /proxies/{group}
    static func selectProxy(group: String, name: String) async throws {
        guard let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/proxies/\(encoded)") else {
            throw MihomoAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, [200, 204].contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("selectProxy failed")
        }
    }

    // MARK: - Delay Testing

    static func testGroupDelay(group: String, url: String = "https://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> [MihomoDelayResult] {
        guard let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/group/\(encoded)/delay?url=\(url)&timeout=\(timeout)") else {
            throw MihomoAPIError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MihomoAPIError.requestFailed("Delay test failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.decodingFailed
        }

        return json.map { name, value in
            if let delay = value as? Int, delay > 0 {
                return MihomoDelayResult(name: name, delay: delay, error: nil)
            } else if let errorDict = value as? [String: Any], let msg = errorDict["message"] as? String {
                return MihomoDelayResult(name: name, delay: nil, error: msg)
            } else {
                return MihomoDelayResult(name: name, delay: nil, error: "timeout")
            }
        }
    }

    static func testProxyDelay(proxy: String, url: String = "https://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> Int {
        guard let encoded = proxy.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/proxies/\(encoded)/delay?url=\(url)&timeout=\(timeout)") else {
            throw MihomoAPIError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MihomoAPIError.requestFailed("Delay test failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delay = json["delay"] as? Int else {
            throw MihomoAPIError.decodingFailed
        }

        return delay
    }

    // MARK: - Config / Mode

    static func patchConfig(_ config: [String: Any]) async throws {
        guard let url = URL(string: "\(baseURL)/configs") else {
            throw MihomoAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: config)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("Failed to update config")
        }
    }

    /// Reload config from disk. Forces mihomo to re-read config.yaml and apply changes.
    /// This will close existing connections.
    static func reloadConfig() async throws {
        guard let url = URL(string: "\(baseURL)/configs?force=true") else {
            throw MihomoAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Empty path means reload current config
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": ""])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("Failed to reload config")
        }
    }

    static func switchMode(_ mode: String) async throws {
        try await patchConfig(["mode": mode])
    }

    static func fetchCurrentMode() async throws -> String {
        let data = try await get("/configs")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mode = json["mode"] as? String else {
            throw MihomoAPIError.decodingFailed
        }
        return mode
    }

    // MARK: - Memory

    static func fetchMemory() async throws -> MihomoMemory {
        let data = try await get("/memory")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.decodingFailed
        }
        let inuse = (json["inuse"] as? NSNumber)?.int64Value ?? 0
        let oslimit = (json["oslimit"] as? NSNumber)?.int64Value ?? 0
        return MihomoMemory(inuse: inuse, oslimit: oslimit)
    }

    // MARK: - DNS

    static func queryDNS(name: String, type: String = "A") async throws -> [String: Any] {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseURL)/dns/query?name=\(encoded)&type=\(type)") else {
            throw MihomoAPIError.invalidURL
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MihomoAPIError.decodingFailed
        }
        return json
    }

    // MARK: - Version

    static func fetchVersion() async throws -> String {
        let data = try await get("/version")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String else {
            throw MihomoAPIError.decodingFailed
        }
        return version
    }

    // MARK: - HTTP Helpers

    private static func get(_ path: String) async throws -> Data {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw MihomoAPIError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("GET \(path) failed")
        }
        return data
    }

    private static func delete(_ path: String) async throws {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw MihomoAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("DELETE \(path) failed")
        }
    }
}
