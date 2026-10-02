// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Combine
import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import Foundation
import NetworkExtension

/// App-only usage analytics (Firebase Analytics) plus Crashlytics context.
///
/// DAU / retention / sessions come from Analytics' automatic events; this adds
/// the app-specific ones. Lives in the app target, not `Shared/`, because
/// `VPNManager` is also compiled into the system extension, which does not
/// link Firebase — so VPN lifecycle is observed from the outside here.
///
/// Privacy: never send subscription URLs/names, node names, server hosts,
/// destinations or raw error text — only enums, counts and durations.
@MainActor
final class AnalyticsService {
    static let shared = AnalyticsService()

    static let enabledKey = "analyticsEnabled"

    private var cancellables = Set<AnyCancellable>()
    private var lastStatus: NEVPNStatus = .disconnected
    private var connectingSince: Date?
    private var connectedSince: Date?

    private var isActive: Bool {
        !AppConstants.isRunningUnitTests && FirebaseApp.app() != nil
    }

    static var isEnabled: Bool {
        AppConstants.sharedDefaults.object(forKey: enabledKey) as? Bool ?? true
    }

    private init() {}

    /// Call once, right after `FirebaseApp.configure()`.
    func start(vpnManager: VPNManager) {
        guard isActive, cancellables.isEmpty else { return }
        setCollectionEnabled(Self.isEnabled)

        vpnManager.$status
            .removeDuplicates()
            .sink { [weak self, weak vpnManager] status in
                guard let self, let vpnManager else { return }
                self.handle(status: status, engineMode: vpnManager.engineMode)
            }
            .store(in: &cancellables)

        vpnManager.$engineMode
            .removeDuplicates()
            .sink { [weak self] mode in
                self?.setProperty(mode.rawValue, forName: "engine_mode")
                Crashlytics.crashlytics().setCustomValue(mode.rawValue, forKey: "engine_mode")
            }
            .store(in: &cancellables)

        vpnManager.$errorMessage
            .compactMap { $0 }
            .sink { [weak self, weak vpnManager] message in
                self?.log("vpn_error", [
                    "engine_mode": vpnManager?.engineMode.rawValue ?? "unknown",
                    "reason": Self.sanitizedReason(message),
                ])
            }
            .store(in: &cancellables)
    }

    func setCollectionEnabled(_ enabled: Bool) {
        guard isActive else { return }
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }

    // MARK: - Events

    func log(_ name: String, _ parameters: [String: Any]? = nil) {
        guard isActive else { return }
        Analytics.logEvent(name, parameters: parameters)
        Crashlytics.crashlytics().log("event \(name)")
    }

    func logScreen(_ name: String) {
        log(AnalyticsEventScreenView, [
            AnalyticsParameterScreenName: name,
            AnalyticsParameterScreenClass: "MainContentView",
        ])
    }

    func setProperty(_ value: String?, forName name: String) {
        guard isActive else { return }
        Analytics.setUserProperty(value, forName: name)
    }

    /// Subscription fetch/refresh outcome. `result` is `success`, `invalid`
    /// (config failed validation) or `error` (download failed).
    func logSubscriptionFetch(result: String, nodeCount: Int = 0) {
        log("subscription_fetch", ["result": result, "node_count": nodeCount])
    }

    func setSubscriptionCount(_ count: Int) {
        setProperty(String(count), forName: "subscription_count")
    }

    // MARK: - VPN lifecycle

    private func handle(status: NEVPNStatus, engineMode: EngineMode) {
        let previous = lastStatus
        lastStatus = status
        Crashlytics.crashlytics().setCustomValue(Self.name(of: status), forKey: "vpn_status")

        let mode = engineMode.rawValue
        switch status {
        case .connecting:
            connectingSince = Date()
        case .connected:
            var params: [String: Any] = ["engine_mode": mode]
            if let connectingSince {
                params["connect_ms"] = Int(Date().timeIntervalSince(connectingSince) * 1000)
            }
            connectingSince = nil
            connectedSince = Date()
            log("vpn_connect", params)
        case .disconnected:
            if let connectedSince {
                log("vpn_disconnect", [
                    "engine_mode": mode,
                    "duration_sec": Int(Date().timeIntervalSince(connectedSince)),
                ])
            } else if previous == .connecting || previous == .reasserting {
                log("vpn_connect_failed", ["engine_mode": mode])
            }
            connectingSince = nil
            connectedSince = nil
        default:
            break
        }
    }

    // MARK: - Helpers

    /// Keep only the fixed, app-authored prefix of an error message
    /// ("Failed to start tunnel: <system text>" → "Failed to start tunnel"),
    /// so paths, hosts or config snippets in the tail never leave the device.
    nonisolated static func sanitizedReason(_ message: String) -> String {
        let head = message.split(whereSeparator: { $0 == ":" || $0 == "：" }).first.map(String.init) ?? message
        return String(head.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }

    private static func name(of status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }
}
