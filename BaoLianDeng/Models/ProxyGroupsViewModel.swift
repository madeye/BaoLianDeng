// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Observation

/// ViewModel for proxy groups section, following meow-go's ProxyGroupsSection pattern.
/// Fetches from REST API when VPN connected, falls back to YAML parsing when offline.
@Observable
final class ProxyGroupsViewModel {
    // MARK: - Published State

    var groups: [MihomoProxyGroup] = []
    var proxies: [String: ProxyLeaf] = [:]
    var delays: [String: Int] = [:]
    var selections: [String: String] = [:]
    var isLoading = false
    var isOffline = false
    var loadError: String?

    // Track which groups are currently being tested
    var testingGroups: Set<String> = []

    // MARK: - Load

    /// Load proxy groups from API (when VPN connected) or parse from YAML (offline fallback).
    @MainActor
    func load(vpnConnected: Bool, fallbackYAML: String?) async {
        guard !isLoading else { return }
        isLoading = true
        isOffline = false
        loadError = nil

        do {
            let result = try await MihomoAPI.fetchProxiesResult()
            groups = result.groups.values.sorted { $0.name < $1.name }
            proxies = result.proxies

            // Extract delays from proxy history
            for proxy in result.proxies.values {
                if let delay = proxy.latestDelay {
                    delays[proxy.name] = delay
                }
            }

            // Merge group state into selections, preserving valid saved choices
            mergeLoadedGroups(groups)
        } catch {
            // Engine unreachable (typically VPN off). Fall back to YAML parsing.
            isOffline = true

            if let yaml = fallbackYAML, !yaml.isEmpty {
                let parsed = ProxiesResult.fromYAML(yaml)
                if !parsed.groups.isEmpty {
                    groups = parsed.groups.values.sorted { $0.name < $1.name }
                    proxies = parsed.proxies
                    mergeLoadedGroups(groups)
                }
            }

            // Only show error if we couldn't parse YAML either
            if groups.isEmpty && !(error is URLError) {
                loadError = error.localizedDescription
            }
        }

        isLoading = false
    }

    // MARK: - Select Proxy

    /// Select a proxy within a group. Updates optimistically, reverts on error.
    @MainActor
    func selectProxy(group: String, name: String, vpnConnected: Bool) async {
        let previous = selections[group]
        selections[group] = name

        // When VPN is off, just persist locally - will be replayed on next connect
        guard vpnConnected else {
            saveSelections()
            return
        }

        do {
            try await MihomoAPI.selectProxy(group: group, name: name)
            saveSelections()
        } catch {
            // Rollback on failure
            selections[group] = previous
        }
    }

    // MARK: - Test Delay

    /// Test delay for all proxies in a group.
    @MainActor
    func testGroupDelay(group: String) async {
        guard !testingGroups.contains(group) else { return }
        testingGroups.insert(group)

        do {
            let results = try await MihomoAPI.testGroupDelay(group: group)
            for result in results {
                if let delay = result.delay {
                    delays[result.name] = delay
                } else {
                    // Timeout or error - set to 0 to indicate failure
                    delays[result.name] = 0
                }
            }
        } catch {
            // The whole delay-test call failed (e.g. controller unreachable).
            // Clear this group's stale per-proxy delays rather than leaving
            // old results displayed as if they were just refreshed.
            if let testedGroup = groups.first(where: { $0.name == group }) {
                for proxyName in testedGroup.all {
                    delays[proxyName] = nil
                }
            }
        }

        testingGroups.remove(group)
    }

    // MARK: - Selection Merging

    /// Merge freshly loaded group state into `selections`. A saved selection
    /// survives as long as the group still contains it — the engine resets to
    /// the config's first node on every tunnel restart, so `group.now` must
    /// not clobber a valid user choice (issue #56).
    private func mergeLoadedGroups(_ groups: [MihomoProxyGroup]) {
        let merged = Self.mergedSelections(selections, groups: groups)
        if merged != selections {
            selections = merged
            saveSelections()
        }
    }

    /// Pure core of `mergeLoadedGroups`, separated for unit testing.
    ///
    /// Only `Selector` groups carry user choices. Engine-managed groups
    /// (URLTest, Fallback, LoadBalance, Relay) are dropped from `selections`
    /// so the UI always falls back to the live `group.now` and
    /// `replaySelectionsToEngine()` never pins them. Groups absent from the
    /// loaded config (e.g. another subscription's) are left untouched.
    ///
    /// `selections` holds only the active subscription's choices — persistence
    /// is scoped by subscription ID (`ProxyGroupSelections`), so a selection
    /// made under one subscription can never leak into a same-named group in
    /// another. Call `reloadSelectionsForActiveSubscription()` after switching
    /// subscriptions to swap the in-memory map to the new scope.
    static func mergedSelections(
        _ existing: [String: String],
        groups: [MihomoProxyGroup]
    ) -> [String: String] {
        var result = existing
        for group in groups {
            guard group.type == "Selector" else {
                result[group.name] = nil
                continue
            }
            if let current = existing[group.name], group.all.contains(current) {
                continue
            }
            result[group.name] = group.now
        }
        return result
    }

    // MARK: - Persistence

    private func saveSelections() {
        // Persist under the active subscription's scope for replay on the next
        // VPN connect.
        ProxyGroupSelections.save(selections)
    }

    func loadSelections() {
        for (group, name) in ProxyGroupSelections.load() {
            selections[group] = name
        }
    }

    /// Swap the in-memory selections to the newly active subscription's scope.
    /// Unlike `loadSelections()` this discards the previous subscription's
    /// choices instead of merging them, so a group name shared by both
    /// subscriptions shows the value the user picked *here*.
    @MainActor
    func reloadSelectionsForActiveSubscription() {
        selections = ProxyGroupSelections.load()
    }

    /// Replay saved selections to the engine after VPN connects.
    @MainActor
    func replaySelectionsToEngine() async {
        for (group, name) in selections {
            try? await MihomoAPI.selectProxy(group: group, name: name)
        }
    }

    // MARK: - Helpers

    /// Get the current selection for a group, falling back to the group's `now` value.
    func currentSelection(for group: MihomoProxyGroup) -> String {
        selections[group.name] ?? group.now
    }

    /// Get delay for a proxy name, returns nil if not tested.
    func delay(for name: String) -> Int? {
        delays[name]
    }

    /// Color thresholds for latency display (matching NodeRow.delayColor).
    static func delayColor(_ delay: Int?) -> DelayLevel {
        guard let ms = delay else { return .untested }
        if ms == 0 { return .timeout }
        if ms < 150 { return .fast }
        if ms < 400 { return .medium }
        return .slow
    }

    enum DelayLevel {
        case untested
        case timeout
        case fast    // < 150ms
        case medium  // 150-400ms
        case slow    // > 400ms
    }
}
