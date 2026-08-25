// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

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
