// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

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
    private var dayCounterBaselineUpload: Int64 = 0
    private var dayCounterBaselineDownload: Int64 = 0
    private var awaitingInitialCounterSample = false
    private var didResetForCurrentStart = false
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
    // Serializes all UserDefaults writes for dailyTrafficKey /
    // subscriptionUsageKey so an older tick's write can never land after a
    // newer one, and so resetSubscriptionUsages() can't be overtaken by an
    // already-queued save that would resurrect the cleared data.
    private let persistQueue = DispatchQueue(label: "io.github.baoliandeng.trafficstore.persist")
    // Bumped on every fetchConnections() call; a completion handler discards
    // its response if a newer request has since been issued, so a reordered
    // stale response can't be misread as an engine counter reset.
    private var fetchGeneration: Int = 0

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
        prepareForPollingStart()
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
        dayCounterBaselineUpload = 0
        dayCounterBaselineDownload = 0
        awaitingInitialCounterSample = false
        didResetForCurrentStart = true

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

    private func prepareForPollingStart() {
        currentDate = Self.dateFormatter.string(from: Date())
        syncTodayBaseFromRecords()
        awaitingInitialCounterSample =
            !didResetForCurrentStart && sessionProxyUpload == 0 && sessionProxyDownload == 0
        didResetForCurrentStart = false
    }

    private func syncTodayBaseFromRecords() {
        let countedUpload = max(0, sessionProxyUpload - dayCounterBaselineUpload)
        let countedDownload = max(0, sessionProxyDownload - dayCounterBaselineDownload)

        if let todayRecord = dailyRecords.first(where: { $0.date == currentDate }) {
            todayBaseUpload = max(0, todayRecord.proxyUpload - countedUpload)
            todayBaseDownload = max(0, todayRecord.proxyDownload - countedDownload)
        } else {
            todayBaseUpload = 0
            todayBaseDownload = 0
        }
    }

    private func fetchConnections() {
        guard let url = AppConstants.externalControllerURL(pathSegments: ["connections"]) else { return }
        fetchGeneration += 1
        let gen = fetchGeneration
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = json["connections"] as? [[String: Any]] else {
                return
            }
            // The tunnel tracks total upload/download across all connections.
            // Per-connection stats are only finalized when connections close,
            // so use the tunnel totals for accurate real-time tracking.
            let uploadTotal = Self.int64Value(json["upload_total"] ?? json["uploadTotal"])
            let downloadTotal = Self.int64Value(json["download_total"] ?? json["downloadTotal"])
            Task { @MainActor [weak self] in
                guard let self, gen == self.fetchGeneration else { return }
                self.processConnections(connections, uploadTotal: uploadTotal, downloadTotal: downloadTotal)
            }
        }.resume()
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let string = value as? String { return Int64(string) ?? 0 }
        return 0
    }

    private func processConnections(_ connections: [[String: Any]], uploadTotal: Int64, downloadTotal: Int64) {
        let today = Self.dateFormatter.string(from: Date())
        if today != currentDate {
            persistToday()
            currentDate = today
            todayBaseUpload = 0
            todayBaseDownload = 0
            dayCounterBaselineUpload = sessionProxyUpload
            dayCounterBaselineDownload = sessionProxyDownload
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

        if awaitingInitialCounterSample {
            dayCounterBaselineUpload = uploadTotal
            dayCounterBaselineDownload = downloadTotal
            lastAttributedUpload = uploadTotal
            lastAttributedDownload = downloadTotal
            awaitingInitialCounterSample = false
        }

        reconcileCounterResets(uploadTotal: uploadTotal, downloadTotal: downloadTotal)

        // Use tunnel-level totals for session traffic. The tunnel counts all
        // traffic through the proxy engine; since tun2socks routes everything
        // via SOCKS5, this is effectively all proxy traffic.
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

    private func reconcileCounterResets(uploadTotal: Int64, downloadTotal: Int64) {
        if uploadTotal < sessionProxyUpload {
            todayBaseUpload += max(0, sessionProxyUpload - dayCounterBaselineUpload)
            dayCounterBaselineUpload = 0
            lastAttributedUpload = 0
        }
        if downloadTotal < sessionProxyDownload {
            todayBaseDownload += max(0, sessionProxyDownload - dayCounterBaselineDownload)
            dayCounterBaselineDownload = 0
            lastAttributedDownload = 0
        }
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
        let todayUp = todayBaseUpload + max(0, sessionProxyUpload - dayCounterBaselineUpload)
        let todayDown = todayBaseDownload + max(0, sessionProxyDownload - dayCounterBaselineDownload)

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
        // Keep at least 62 days (two months) so day 1 of a 31-day month is
        // never dropped from the current-month rollup.
        let retentionDays = 62
        guard dailyRecords.count > retentionDays else { return }
        let sorted = dailyRecords.sorted { $0.date > $1.date }
        dailyRecords = Array(sorted.prefix(retentionDays))
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
        persistQueue.async {
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
        persistQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: AppConstants.subscriptionUsageKey)
        }
    }

    func resetSubscriptionUsages() {
        subscriptionUsages.removeAll()
        // Clear on persistQueue (not synchronously here) so this ordering is
        // enforced relative to any save already queued: the clear runs after
        // saves enqueued before this call, and before any enqueued after.
        persistQueue.async {
            AppConstants.sharedDefaults.removeObject(forKey: AppConstants.subscriptionUsageKey)
        }
        refreshSubscriptionCache()
    }

    #if DEBUG
    func preparePollingForTesting() {
        prepareForPollingStart()
    }

    func resetTrafficStateForTesting(
        dailyRecords: [DailyTraffic] = [],
        subscriptionUsages: [SubscriptionUsage] = [],
        sessionUpload: Int64 = 0,
        sessionDownload: Int64 = 0,
        todayBaseUpload: Int64 = 0,
        todayBaseDownload: Int64 = 0,
        dayCounterBaselineUpload: Int64 = 0,
        dayCounterBaselineDownload: Int64 = 0,
        lastAttributedUpload: Int64 = 0,
        lastAttributedDownload: Int64 = 0,
        didResetForCurrentStart: Bool = false
    ) {
        stopPolling()
        self.dailyRecords = dailyRecords
        self.subscriptionUsages = subscriptionUsages
        sessionProxyUpload = sessionUpload
        sessionProxyDownload = sessionDownload
        activeProxyCount = 0
        activeTotalCount = 0
        self.todayBaseUpload = todayBaseUpload
        self.todayBaseDownload = todayBaseDownload
        self.dayCounterBaselineUpload = dayCounterBaselineUpload
        self.dayCounterBaselineDownload = dayCounterBaselineDownload
        self.lastAttributedUpload = lastAttributedUpload
        self.lastAttributedDownload = lastAttributedDownload
        awaitingInitialCounterSample = false
        self.didResetForCurrentStart = didResetForCurrentStart
        currentDate = Self.dateFormatter.string(from: Date())
        defaults.removeObject(forKey: AppConstants.dailyTrafficKey)
        defaults.removeObject(forKey: AppConstants.subscriptionUsageKey)
        defaults.removeObject(forKey: "selectedSubscriptionID")
    }

    func processConnectionsForTesting(uploadTotal: Int64, downloadTotal: Int64) {
        processConnections([], uploadTotal: uploadTotal, downloadTotal: downloadTotal)
    }
    #endif
}
