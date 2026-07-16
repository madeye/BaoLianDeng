// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import Testing
@testable import BaoLianDeng

@Suite("BypassGroupDetection")
struct BypassGroupDetectionTests {

    @Test("Literal DIRECT is bypass")
    func literalDirect() {
        #expect(isBypassGroup(firstMember: "DIRECT", groupMembers: [:]))
    }

    @Test("Literal REJECT is bypass")
    func literalReject() {
        #expect(isBypassGroup(firstMember: "REJECT", groupMembers: [:]))
    }

    @Test("Real proxy node name is not bypass")
    func realNode() {
        #expect(!isBypassGroup(firstMember: "🇭🇰 HK-01", groupMembers: [:]))
    }

    @Test("Nested group with only DIRECT is bypass")
    func nestedDirectOnly() {
        let groups: [String: [String]] = ["Bypass": ["DIRECT"]]
        #expect(isBypassGroup(firstMember: "Bypass", groupMembers: groups))
    }

    @Test("Nested group with only REJECT is bypass")
    func nestedRejectOnly() {
        let groups: [String: [String]] = ["AdBlock": ["REJECT"]]
        #expect(isBypassGroup(firstMember: "AdBlock", groupMembers: groups))
    }

    @Test("Nested group mixing DIRECT with a real node is not bypass")
    func nestedMixed() {
        let groups: [String: [String]] = ["Mixed": ["DIRECT", "🇭🇰 HK-01"]]
        #expect(!isBypassGroup(firstMember: "Mixed", groupMembers: groups))
    }

    @Test("Two-level nested bypass is bypass")
    func twoLevelNested() {
        let groups: [String: [String]] = [
            "A": ["B"],
            "B": ["DIRECT"],
        ]
        #expect(isBypassGroup(firstMember: "A", groupMembers: groups))
    }

    @Test("Two-level nested with mixed members is not bypass")
    func twoLevelNestedMixed() {
        let groups: [String: [String]] = [
            "A": ["B"],
            "B": ["DIRECT", "🇭🇰 HK-01"],
        ]
        #expect(!isBypassGroup(firstMember: "A", groupMembers: groups))
    }

    @Test("Cycle in group references does not hang and resolves to non-bypass")
    func cycleSafety() {
        let groups: [String: [String]] = [
            "A": ["B"],
            "B": ["A"],
        ]
        // Neither group has a terminal bypass member, so the cycle guard
        // must short-circuit to false rather than recursing forever.
        #expect(!isBypassGroup(firstMember: "A", groupMembers: groups))
    }

    @Test("Empty nested group is not bypass")
    func emptyGroup() {
        let groups: [String: [String]] = ["Empty": []]
        #expect(!isBypassGroup(firstMember: "Empty", groupMembers: groups))
    }

    @Test("Mixed-bypass group containing DIRECT and REJECT is bypass")
    func directAndReject() {
        let groups: [String: [String]] = ["Both": ["DIRECT", "REJECT"]]
        #expect(isBypassGroup(firstMember: "Both", groupMembers: groups))
    }
}

@Suite("FirstBypassMember")
struct FirstBypassMemberTests {

    @Test("Returns nil when no members are bypass")
    func noneBypass() {
        #expect(firstBypassMember(in: ["🇭🇰 HK-01", "🇺🇸 US-01"], groupMembers: [:]) == nil)
    }

    @Test("Returns literal DIRECT when present later in the list")
    func directNotFirst() {
        let members = ["🇺🇸 USA Seattle 01", "DIRECT", "🇭🇰 HK-01"]
        #expect(firstBypassMember(in: members, groupMembers: [:]) == "DIRECT")
    }

    @Test("Returns a nested direct-only group when present")
    func nestedDirectGroup() {
        let groups: [String: [String]] = ["🎯Direct": ["DIRECT"]]
        let members = ["🇺🇸 USA Seattle 01", "🎯Direct", "Proxies"]
        #expect(firstBypassMember(in: members, groupMembers: groups) == "🎯Direct")
    }

    @Test("Returns a mixed nested group whose first member is DIRECT")
    func mixedNestedDirectFirst() {
        // Real-world layout: `🎯Direct` is itself a select group whose
        // members are `[DIRECT, Proxies]`. Mihomo defaults to the first
        // member, so this group routes to DIRECT until the user picks
        // otherwise — `firstBypassMember` should treat it as a bypass.
        let groups: [String: [String]] = [
            "🎯Direct": ["DIRECT", "Proxies"],
        ]
        let members = ["🇺🇸 USA Seattle 01", "🎯Direct", "Proxies"]
        #expect(firstBypassMember(in: members, groupMembers: groups) == "🎯Direct")
    }

    @Test("Skips a nested group whose first member is a real proxy")
    func skipsNestedRealFirst() {
        // `Mixed` lists a real node first, then DIRECT. Mihomo defaults to
        // the real node, so this is NOT a bypass option.
        let groups: [String: [String]] = [
            "Mixed": ["🇺🇸 US-02", "DIRECT"],
            "PureDirect": ["DIRECT"],
        ]
        let members = ["🇺🇸 USA Seattle 01", "Mixed", "PureDirect", "🇭🇰 HK-01"]
        #expect(firstBypassMember(in: members, groupMembers: groups) == "PureDirect")
    }

    @Test("Returns REJECT when the only bypass is REJECT")
    func rejectOnly() {
        let members = ["🇭🇰 HK-01", "REJECT"]
        #expect(firstBypassMember(in: members, groupMembers: [:]) == "REJECT")
    }

    @Test("Returns first bypass when multiple are present")
    func firstBypassWins() {
        // Encodes the real-world Bilibili-group layout: first real proxy,
        // then "🎯Direct" as a nested direct-only group.
        let groups: [String: [String]] = ["🎯Direct": ["DIRECT"]]
        let members = [
            "🇺🇸 USA Seattle 01",
            "🎯Direct",
            "Proxies",
            "🇭🇰 Hong Kong 01",
            "DIRECT"
        ]
        #expect(firstBypassMember(in: members, groupMembers: groups) == "🎯Direct")
    }

    @Test("Empty member list returns nil")
    func emptyList() {
        #expect(firstBypassMember(in: [], groupMembers: [:]) == nil)
    }
}
