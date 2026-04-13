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

            // Initialize selections from current group state
            for group in groups {
                selections[group.name] = group.now
            }
        } catch {
            // Engine unreachable (typically VPN off). Fall back to YAML parsing.
            isOffline = true

            if let yaml = fallbackYAML, !yaml.isEmpty {
                let parsed = ProxiesResult.fromYAML(yaml)
                if !parsed.groups.isEmpty {
                    groups = parsed.groups.values.sorted { $0.name < $1.name }
                    proxies = parsed.proxies
                    for group in groups {
                        selections[group.name] = group.now
                    }
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
            // Silently swallow errors (same pattern as meow-go)
        }

        testingGroups.remove(group)
    }

    // MARK: - Persistence

    private func saveSelections() {
        // Save selections to UserDefaults for replay on next VPN connect
        if let data = try? JSONEncoder().encode(selections) {
            AppConstants.sharedDefaults.set(data, forKey: "proxyGroupSelections")
        }
    }

    func loadSelections() {
        if let data = AppConstants.sharedDefaults.data(forKey: "proxyGroupSelections"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            for (group, name) in saved {
                selections[group] = name
            }
        }
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
