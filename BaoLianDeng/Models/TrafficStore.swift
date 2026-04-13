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
import Combine

struct DailyTraffic: Codable, Identifiable {
    let date: String // yyyy-MM-dd
    var proxyUpload: Int64
    var proxyDownload: Int64

    var id: String { date }
    var total: Int64 { proxyUpload + proxyDownload }
}

struct SubscriptionUsage: Codable, Identifiable {
    var id: String       // UUID string of the subscription
    var name: String     // Display name, kept fresh on each attribution
    var upload: Int64
    var download: Int64
    var total: Int64 { upload + download }
}

@MainActor
final class TrafficStore: ObservableObject {
    static let shared = TrafficStore()

    @Published var sessionProxyUpload: Int64 = 0
    @Published var sessionProxyDownload: Int64 = 0
    @Published var dailyRecords: [DailyTraffic] = []
    @Published var activeProxyCount: Int = 0
    @Published var activeTotalCount: Int = 0
    @Published var subscriptionUsages: [SubscriptionUsage] = []

    var sessionTotal: Int64 { sessionProxyUpload + sessionProxyDownload }

    var currentMonthRecords: [DailyTraffic] {
        let prefix = currentMonthPrefix()
        return dailyRecords.filter { $0.date.hasPrefix(prefix) }
    }

    var currentMonthUpload: Int64 { currentMonthRecords.reduce(0) { $0 + $1.proxyUpload } }
    var currentMonthDownload: Int64 { currentMonthRecords.reduce(0) { $0 + $1.proxyDownload } }
    var currentMonthTotal: Int64 { currentMonthUpload + currentMonthDownload }

    private var lastAttributedUpload: Int64 = 0
    private var lastAttributedDownload: Int64 = 0
    private var todayBaseUpload: Int64 = 0
    private var todayBaseDownload: Int64 = 0
    private var currentDate: String = ""
    private var timer: Timer?
    private let defaults = AppConstants.sharedDefaults
    private var subscriptionNameCache: [String: String] = [:]
    // Cached map of proxy-group name → member list, parsed from config.yaml.
    // Used to classify mihomo connection chains: the /connections endpoint
    // returns only group display names (e.g. "Apple", "🎯Direct") and the
    // Rust mihomo fork's /proxies endpoint does not expose `all`/`now`, so
    // we resolve group membership directly from the on-disk config.
    private var groupMembersCache: [String: [String]] = [:]
    private var lastGroupRefresh: Date = .distantPast

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        loadRecords()
        loadSubscriptionUsages()
        refreshSubscriptionCache()
    }

    func startPolling() {
        stopPolling()
        currentDate = Self.dateFormatter.string(from: Date())
        refreshSubscriptionCache()
        refreshGroupMembers()
        fetchConnections()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchConnections()
            }
        }
    }

    /// Reload the group→members map from the on-disk config. Refreshed at
    /// startPolling time and lazily when stale — the user can edit the
    /// config mid-session via ConfigEditor, so we don't pin it to just the
    /// startup parse.
    private func refreshGroupMembers() {
        guard let yaml = try? ConfigManager.shared.loadConfig() else { return }
        let groups = ConfigManager.shared.parseProxyGroups(from: yaml)
        groupMembersCache = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0.proxies) })
        lastGroupRefresh = Date()
    }

    private func refreshSubscriptionCache() {
        Task.detached(priority: .utility) { [weak self] in
            let defaults = AppConstants.sharedDefaults
            var cache: [String: String] = [:]
            if let data = defaults.data(forKey: "subscriptions"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for sub in arr {
                    if let sid = sub["id"] as? String, let n = sub["name"] as? String, !n.isEmpty {
                        cache[sid] = n
                    }
                }
            }
            await MainActor.run { [cache] in self?.subscriptionNameCache = cache }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func resetSession() {
        stopPolling()
        sessionProxyUpload = 0
        sessionProxyDownload = 0
        activeProxyCount = 0
        activeTotalCount = 0
        lastAttributedUpload = 0
        lastAttributedDownload = 0

        loadRecords()
        currentDate = Self.dateFormatter.string(from: Date())
        if let todayRecord = dailyRecords.first(where: { $0.date == currentDate }) {
            todayBaseUpload = todayRecord.proxyUpload
            todayBaseDownload = todayRecord.proxyDownload
        } else {
            todayBaseUpload = 0
            todayBaseDownload = 0
        }
    }

    private func fetchConnections() {
        let url = URL(string: "http://\(AppConstants.externalControllerAddr)/connections")!
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = json["connections"] as? [[String: Any]] else {
                return
            }
            // The tunnel tracks total upload/download across all connections.
            // Per-connection stats are only finalized when connections close,
            // so use the tunnel totals for accurate real-time tracking.
            let uploadTotal = (json["upload_total"] as? NSNumber)?.int64Value ?? 0
            let downloadTotal = (json["download_total"] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor [weak self] in
                self?.processConnections(connections, uploadTotal: uploadTotal, downloadTotal: downloadTotal)
            }
        }.resume()
    }

    private func processConnections(_ connections: [[String: Any]], uploadTotal: Int64, downloadTotal: Int64) {
        let today = Self.dateFormatter.string(from: Date())
        if today != currentDate {
            persistToday()
            currentDate = today
            todayBaseUpload = 0
            todayBaseDownload = 0
        }

        // Refresh the group map at most every 30s so mid-session config
        // edits (via ConfigEditor) are eventually reflected.
        if Date().timeIntervalSince(lastGroupRefresh) > 30 {
            refreshGroupMembers()
        }

        var proxyCount = 0
        for conn in connections {
            let chains = conn["chains"] as? [String] ?? []
            if !isDirect(chains: chains) { proxyCount += 1 }
        }

        // Use tunnel-level totals for session traffic.
        // The tunnel counts all traffic through the proxy engine; since tun2socks
        // routes everything via SOCKS5, this is effectively all proxy traffic.
        sessionProxyUpload = uploadTotal
        sessionProxyDownload = downloadTotal
        activeProxyCount = proxyCount
        activeTotalCount = connections.count

        let deltaUp = sessionProxyUpload - lastAttributedUpload
        let deltaDown = sessionProxyDownload - lastAttributedDownload
        if (deltaUp > 0 || deltaDown > 0),
           let subID = defaults.string(forKey: "selectedSubscriptionID"),
           !subID.isEmpty {
            attributeDelta(upload: deltaUp, download: deltaDown, toSubscriptionID: subID)
        }
        lastAttributedUpload = sessionProxyUpload
        lastAttributedDownload = sessionProxyDownload

        persistToday()
    }

    private func isDirect(chains: [String]) -> Bool {
        // A connection is direct if any element in its chain resolves to
        // DIRECT/REJECT. For real outbounds that's a literal match; for
        // selector groups we walk the cached config-time group map via
        // isFirstDefaultBypass — which recursively follows each group's
        // first listed member (the runtime default after applySelectedNode
        // rewrites the config to put the chosen member at index 0). Empty
        // chains are treated as direct defensively.
        if chains.isEmpty { return true }
        for element in chains {
            var seen: Set<String> = []
            if isFirstDefaultBypass(element, groupMembers: groupMembersCache, seen: &seen) {
                return true
            }
        }
        return false
    }

    private func persistToday() {
        let todayUp = todayBaseUpload + sessionProxyUpload
        let todayDown = todayBaseDownload + sessionProxyDownload

        if let idx = dailyRecords.firstIndex(where: { $0.date == currentDate }) {
            dailyRecords[idx].proxyUpload = todayUp
            dailyRecords[idx].proxyDownload = todayDown
        } else {
            dailyRecords.append(DailyTraffic(
                date: currentDate, proxyUpload: todayUp, proxyDownload: todayDown
            ))
        }

        pruneOldRecords()
        saveRecords()
    }

    private func pruneOldRecords() {
        guard dailyRecords.count > 30 else { return }
        let sorted = dailyRecords.sorted { $0.date > $1.date }
        dailyRecords = Array(sorted.prefix(30))
    }

    private func loadRecords() {
        guard let data = defaults.data(forKey: AppConstants.dailyTrafficKey),
              let records = try? JSONDecoder().decode([DailyTraffic].self, from: data) else {
            dailyRecords = []
            return
        }
        dailyRecords = records
    }

    private func saveRecords() {
        let snapshot = dailyRecords
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: AppConstants.dailyTrafficKey)
        }
    }

    private func currentMonthPrefix() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    // MARK: - Subscription Usage

    private func attributeDelta(upload: Int64, download: Int64, toSubscriptionID subID: String) {
        let displayName = subscriptionNameCache[subID] ?? subID
        if let idx = subscriptionUsages.firstIndex(where: { $0.id == subID }) {
            subscriptionUsages[idx].upload += upload
            subscriptionUsages[idx].download += download
            subscriptionUsages[idx].name = displayName
        } else {
            subscriptionUsages.append(SubscriptionUsage(
                id: subID, name: displayName, upload: upload, download: download
            ))
        }
        saveSubscriptionUsages()
    }

    private func loadSubscriptionUsages() {
        guard let data = defaults.data(forKey: AppConstants.subscriptionUsageKey),
              let usages = try? JSONDecoder().decode([SubscriptionUsage].self, from: data) else {
            subscriptionUsages = []
            return
        }
        subscriptionUsages = usages
    }

    private func saveSubscriptionUsages() {
        let snapshot = subscriptionUsages
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: AppConstants.subscriptionUsageKey)
        }
    }

    func resetSubscriptionUsages() {
        subscriptionUsages.removeAll()
        defaults.removeObject(forKey: AppConstants.subscriptionUsageKey)
        refreshSubscriptionCache()
    }
}
