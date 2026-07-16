// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
@testable import BaoLianDeng

@Suite("Proxy group selection merging")
struct ProxyGroupSelectionMergeTests {

    private func selector(_ name: String, now: String, all: [String]) -> MihomoProxyGroup {
        MihomoProxyGroup(name: name, type: "Selector", now: now, all: all)
    }

    @Test("Keeps a saved selection the group still contains")
    func keepsValidSavedSelection() {
        // Engine restarted and reset PROXY to the first node (HK)
        let groups = [selector("PROXY", now: "HK", all: ["HK", "US", "JP"])]
        let merged = ProxyGroupsViewModel.mergedSelections(["PROXY": "US"], groups: groups)
        #expect(merged["PROXY"] == "US")
    }

    @Test("Replaces a saved selection the group no longer contains")
    func replacesInvalidSavedSelection() {
        let groups = [selector("PROXY", now: "HK", all: ["HK", "JP"])]
        let merged = ProxyGroupsViewModel.mergedSelections(["PROXY": "US"], groups: groups)
        #expect(merged["PROXY"] == "HK")
    }

    @Test("Initializes a missing selection from the group's current node")
    func initializesMissingSelection() {
        let groups = [selector("PROXY", now: "HK", all: ["HK", "US"])]
        let merged = ProxyGroupsViewModel.mergedSelections([:], groups: groups)
        #expect(merged["PROXY"] == "HK")
    }

    @Test("Drops engine-managed groups so the UI tracks live state")
    func dropsEngineManagedGroups() {
        let groups = [
            MihomoProxyGroup(name: "AUTO", type: "URLTest", now: "JP", all: ["HK", "JP"]),
            MihomoProxyGroup(name: "FALLBACK", type: "Fallback", now: "HK", all: ["HK", "JP"])
        ]
        let merged = ProxyGroupsViewModel.mergedSelections(
            ["AUTO": "HK", "FALLBACK": "JP"],
            groups: groups
        )
        #expect(merged["AUTO"] == nil)
        #expect(merged["FALLBACK"] == nil)
    }

    @Test("Preserves selections for groups absent from the loaded config")
    func preservesSelectionsForAbsentGroups() {
        // Switching subscriptions must not erase the other profile's choices
        let groups = [selector("PROXY", now: "HK", all: ["HK", "US"])]
        let merged = ProxyGroupsViewModel.mergedSelections(
            ["OTHER-SUB-GROUP": "SG"],
            groups: groups
        )
        #expect(merged["OTHER-SUB-GROUP"] == "SG")
        #expect(merged["PROXY"] == "HK")
    }
}
