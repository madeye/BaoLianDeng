// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Testing
import Foundation
@testable import BaoLianDeng

/// Serialized: these tests mutate the shared defaults keys the store owns.
@Suite("ProxyGroupSelections", .serialized)
struct ProxyGroupSelectionsTests {

    /// Run `body` against a scratch `UserDefaults` suite, wiping it afterwards
    /// so nothing leaks into the app's real defaults or the next test.
    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let name = "ProxyGroupSelectionsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not create scratch UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    private func setSubscription(_ id: String?, in defaults: UserDefaults) {
        if let id {
            defaults.set(id, forKey: ProxyGroupSelections.selectedSubscriptionIDKey)
        } else {
            defaults.removeObject(forKey: ProxyGroupSelections.selectedSubscriptionIDKey)
        }
    }

    @Test("Selections round-trip within a subscription scope")
    func roundTrip() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            ProxyGroupSelections.save(["PROXY": "HK-01"], to: defaults)
            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "HK-01"])
        }
    }

    @Test("Selections do not leak between subscriptions")
    func scopedPerSubscription() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            ProxyGroupSelections.save(["PROXY": "Taiwan 05"], to: defaults)

            // Same group name, same node name available in the other
            // subscription: the old unscoped storage would replay "Taiwan 05"
            // here even though the user never picked it under sub-b.
            setSubscription("sub-b", in: defaults)
            #expect(ProxyGroupSelections.load(from: defaults).isEmpty)

            ProxyGroupSelections.save(["PROXY": "JP-02"], to: defaults)
            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "JP-02"])

            setSubscription("sub-a", in: defaults)
            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "Taiwan 05"])
        }
    }

    @Test("No selected subscription gets its own scope")
    func noSubscriptionScope() {
        withScratchDefaults { defaults in
            setSubscription(nil, in: defaults)
            ProxyGroupSelections.save(["PROXY": "local"], to: defaults)
            #expect(ProxyGroupSelections.allScopes(in: defaults).keys
                .contains(ProxyGroupSelections.noSubscriptionScope))

            setSubscription("sub-a", in: defaults)
            #expect(ProxyGroupSelections.load(from: defaults).isEmpty)
        }
    }

    @Test("Empty selections clear the scope instead of storing an empty map")
    func emptyClearsScope() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            ProxyGroupSelections.save(["PROXY": "HK-01"], to: defaults)
            ProxyGroupSelections.save([:], to: defaults)
            #expect(ProxyGroupSelections.allScopes(in: defaults)["sub-a"] == nil)
        }
    }

    @Test("Removing a scope forgets only that subscription")
    func removeScope() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            ProxyGroupSelections.save(["PROXY": "HK-01"], to: defaults)
            setSubscription("sub-b", in: defaults)
            ProxyGroupSelections.save(["PROXY": "JP-02"], to: defaults)

            ProxyGroupSelections.removeScope("sub-a", from: defaults)

            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "JP-02"])
            setSubscription("sub-a", in: defaults)
            #expect(ProxyGroupSelections.load(from: defaults).isEmpty)
        }
    }

    @Test("Legacy selectedNode is dropped, never migrated into a group")
    func legacySelectedNodeIsDropped() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            defaults.set("🇨🇳 Taiwan 05", forKey: ProxyGroupSelections.legacySelectedNodeKey)

            #expect(ProxyGroupSelections.load(from: defaults).isEmpty)
            #expect(defaults.object(forKey: ProxyGroupSelections.legacySelectedNodeKey) == nil)
        }
    }

    @Test("Legacy unscoped selections migrate into the active subscription")
    func legacyBlobMigrates() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            let legacy = try? JSONEncoder().encode(["PROXY": "HK-01"])
            defaults.set(legacy, forKey: ProxyGroupSelections.legacyStorageKey)

            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "HK-01"])
            #expect(defaults.object(forKey: ProxyGroupSelections.legacyStorageKey) == nil)

            // Migrated into sub-a only.
            setSubscription("sub-b", in: defaults)
            #expect(ProxyGroupSelections.load(from: defaults).isEmpty)
        }
    }

    @Test("Migration never overwrites selections already saved for the scope")
    func legacyBlobDoesNotOverwrite() {
        withScratchDefaults { defaults in
            setSubscription("sub-a", in: defaults)
            ProxyGroupSelections.save(["PROXY": "JP-02"], to: defaults)
            let legacy = try? JSONEncoder().encode(["PROXY": "HK-01"])
            defaults.set(legacy, forKey: ProxyGroupSelections.legacyStorageKey)

            #expect(ProxyGroupSelections.load(from: defaults) == ["PROXY": "JP-02"])
        }
    }

    @Test("Malformed scope entries are skipped, not fatal")
    func malformedEntriesSkipped() {
        withScratchDefaults { defaults in
            defaults.set(["sub-a": "not-a-dictionary", "sub-b": ["PROXY": "JP-02"]],
                         forKey: ProxyGroupSelections.storageKey)
            let scopes = ProxyGroupSelections.allScopes(in: defaults)
            #expect(scopes["sub-a"] == nil)
            #expect(scopes["sub-b"] == ["PROXY": "JP-02"])
        }
    }
}
