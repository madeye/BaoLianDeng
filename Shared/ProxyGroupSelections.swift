// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation

/// Per-group proxy selections, scoped to the subscription they were made under.
///
/// The app used to keep two competing pieces of selection state:
///
/// * `selectedNode` — ONE global node name that the main app pushed into
///   *every* non-bypass `Selector` group at tunnel start, and that
///   `ConfigManager.applySelectedNode()` also promoted to index 0 of every
///   such group in the effective YAML. Nothing has written that key since node
///   selection moved to the REST API (#23), so the only values still in the
///   wild are leftovers from older builds — a node name from a subscription
///   the user may no longer even have. When that stale name happened to also
///   exist in the current subscription it passed the membership check and got
///   pinned into every group, routing all traffic through a node the user
///   never picked; if that node was dead, everything black-holed.
///
/// * `proxyGroupSelections` — the real per-group choices, but keyed by group
///   name alone. Two subscriptions that share a group name and a node name
///   leaked selections into each other (issue #75 item 6).
///
/// Selections now live here, keyed by subscription scope first and group name
/// second, so a choice made under one subscription can never be replayed into
/// another. `selectedNode` is retired: `migrateLegacyStorageIfNeeded` removes
/// it so it can never be pushed into a group again.
///
/// Stored as a plain plist dictionary (not JSON `Data`) so the value stays
/// readable and writable with `defaults`, which the E2E scripts rely on.
enum ProxyGroupSelections {
    /// UserDefaults key holding `[subscriptionScope: [groupName: proxyName]]`.
    static let storageKey = "proxyGroupSelectionsBySubscription"

    /// Legacy unscoped `[groupName: proxyName]` JSON blob. Migrated into the
    /// active subscription's scope on first access, then removed.
    static let legacyStorageKey = "proxyGroupSelections"

    /// Legacy single global node name. Read-only leftover from builds before
    /// #23; removed on first access.
    static let legacySelectedNodeKey = "selectedNode"

    /// UserDefaults key holding the active subscription's UUID string.
    static let selectedSubscriptionIDKey = "selectedSubscriptionID"

    /// Scope used when no subscription is selected (hand-edited config).
    static let noSubscriptionScope = "__none__"

    /// Scope key for the currently selected subscription.
    static func currentScope(in defaults: UserDefaults = AppConstants.sharedDefaults) -> String {
        let id = defaults.string(forKey: selectedSubscriptionIDKey) ?? ""
        return id.isEmpty ? noSubscriptionScope : id
    }

    /// Saved selections for the active subscription, `[groupName: proxyName]`.
    static func load(from defaults: UserDefaults = AppConstants.sharedDefaults) -> [String: String] {
        migrateLegacyStorageIfNeeded(in: defaults)
        return allScopes(in: defaults)[currentScope(in: defaults)] ?? [:]
    }

    /// Replace the active subscription's selections. Other scopes are kept.
    static func save(
        _ selections: [String: String],
        to defaults: UserDefaults = AppConstants.sharedDefaults
    ) {
        migrateLegacyStorageIfNeeded(in: defaults)
        var scopes = allScopes(in: defaults)
        scopes[currentScope(in: defaults)] = selections.isEmpty ? nil : selections
        write(scopes, to: defaults)
    }

    /// Forget a deleted subscription's selections so re-adding the same
    /// subscription later starts from the config's own defaults.
    static func removeScope(
        _ subscriptionID: String,
        from defaults: UserDefaults = AppConstants.sharedDefaults
    ) {
        var scopes = allScopes(in: defaults)
        guard scopes.removeValue(forKey: subscriptionID) != nil else { return }
        write(scopes, to: defaults)
    }

    /// Every scope's selections. Entries that aren't `[String: String]` (hand
    /// edits, corrupt writes) are dropped rather than failing the whole read.
    static func allScopes(
        in defaults: UserDefaults = AppConstants.sharedDefaults
    ) -> [String: [String: String]] {
        guard let raw = defaults.dictionary(forKey: storageKey) else { return [:] }
        var result: [String: [String: String]] = [:]
        for (scope, value) in raw {
            guard let entries = value as? [String: String] else { continue }
            result[scope] = entries
        }
        return result
    }

    private static func write(_ scopes: [String: [String: String]], to defaults: UserDefaults) {
        if scopes.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(scopes, forKey: storageKey)
        }
    }

    /// Fold the pre-scoping storage into the current scope and drop the two
    /// legacy keys. Idempotent: once `selectedNode` and the unscoped blob are
    /// gone this is a no-op, so it is safe to call on every access.
    ///
    /// The legacy blob is attributed to the active subscription because that
    /// is the one it was last used with. It is only adopted when the active
    /// scope has no selections yet, so a migration can never overwrite choices
    /// the user already made under the new storage.
    static func migrateLegacyStorageIfNeeded(in defaults: UserDefaults = AppConstants.sharedDefaults) {
        // The stale global node is never migrated — it is exactly the value
        // that silently overrode real per-group choices.
        if defaults.object(forKey: legacySelectedNodeKey) != nil {
            defaults.removeObject(forKey: legacySelectedNodeKey)
        }

        guard let data = defaults.data(forKey: legacyStorageKey) else { return }
        defaults.removeObject(forKey: legacyStorageKey)

        guard let legacy = try? JSONDecoder().decode([String: String].self, from: data),
              !legacy.isEmpty else { return }
        var scopes = allScopes(in: defaults)
        let scope = currentScope(in: defaults)
        guard scopes[scope] == nil else { return }
        scopes[scope] = legacy
        write(scopes, to: defaults)
    }
}
