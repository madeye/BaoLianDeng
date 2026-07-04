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
    static func makeURL(pathSegments: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard let addr = AppConstants.externalControllerAddr, !addr.isEmpty else {
            throw MihomoAPIError.notConnected
        }
        guard let url = AppConstants.externalControllerURL(
            controllerAddr: addr,
            pathSegments: pathSegments,
            queryItems: queryItems
        ) else {
            throw MihomoAPIError.invalidURL
        }
        return url
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
        return try parseConnectionsResponse(data)
    }

    static func parseConnectionsResponse(_ data: Data) throws -> MihomoConnectionsResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let connections = json["connections"] as? [[String: Any]] else {
            throw MihomoAPIError.decodingFailed
        }

        let uploadTotal = int64Value(json["uploadTotal"] ?? json["upload_total"])
        let downloadTotal = int64Value(json["downloadTotal"] ?? json["download_total"])

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let parsed = connections.compactMap { conn -> MihomoConnection? in
            let id = conn["id"] as? String ?? UUID().uuidString
            let metadata = conn["metadata"] as? [String: Any] ?? [:]
            let host = metadata["host"] as? String ?? ""
            let destIP = metadata["destinationIP"] as? String ?? ""
            let destPort = intValue(metadata["destinationPort"])
            let network = metadata["network"] as? String ?? ""
            let type = metadata["type"] as? String ?? ""

            let rule = conn["rule"] as? String ?? ""
            let rulePayload = conn["rulePayload"] as? String ?? ""
            let chains = conn["chains"] as? [String] ?? []
            let upload = int64Value(conn["upload"])
            let download = int64Value(conn["download"])
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
        try await delete(pathSegments: ["connections", id])
    }

    static func closeAllConnections() async throws {
        try await delete(pathSegments: ["connections"])
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
        let url = try makeURL(pathSegments: ["proxies", group])
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

    static func testGroupDelay(group: String, url testURL: String = "https://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> [MihomoDelayResult] {
        let url = try makeURL(
            pathSegments: ["group", group, "delay"],
            queryItems: [
                URLQueryItem(name: "url", value: testURL),
                URLQueryItem(name: "timeout", value: String(timeout)),
            ]
        )

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

    static func testProxyDelay(proxy: String, url testURL: String = "https://www.gstatic.com/generate_204", timeout: Int = 5000) async throws -> Int {
        let url = try makeURL(
            pathSegments: ["proxies", proxy, "delay"],
            queryItems: [
                URLQueryItem(name: "url", value: testURL),
                URLQueryItem(name: "timeout", value: String(timeout)),
            ]
        )

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
        let url = try makeURL(pathSegments: ["configs"])
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: config)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("Failed to update config")
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
        let url = try makeURL(
            pathSegments: ["dns", "query"],
            queryItems: [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "type", value: type),
            ]
        )
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
        let url = try makeURL(pathSegments: pathSegments(from: path))
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("GET \(path) failed")
        }
        return data
    }

    private static func delete(_ path: String) async throws {
        try await delete(pathSegments: pathSegments(from: path), errorPath: path)
    }

    private static func delete(pathSegments: [String]) async throws {
        try await delete(pathSegments: pathSegments, errorPath: "/" + pathSegments.joined(separator: "/"))
    }

    private static func delete(pathSegments: [String], errorPath: String) async throws {
        let url = try makeURL(pathSegments: pathSegments)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MihomoAPIError.requestFailed("DELETE \(errorPath) failed")
        }
    }

    private static func pathSegments(from path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }
}
