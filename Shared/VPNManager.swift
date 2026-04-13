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

#if canImport(AppKit)
import AppKit
#endif
import Foundation
import NetworkExtension
#if canImport(SystemExtensions)
import SystemExtensions
#endif

final class VPNManager: NSObject, ObservableObject {
    enum SystemExtensionInstallState: Equatable {
        case notInstalled
        case activating
        case awaitingUserApproval
        case active
        case rebootRequired
        case failed(String)
    }

    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .disconnected
    @Published var isProcessing = false
    @Published var errorMessage: String?
    @Published var extensionEnabled = false
    @Published private(set) var systemExtensionInstallState: SystemExtensionInstallState = .notInstalled
    private var activationRequestInFlight = false
    private var isLoadingManager = false
    private func dbg(_ msg: String) {
        AppLogger.vpn.notice("\(msg, privacy: .public)")
    }

    private var manager: NETransparentProxyManager?
    private var statusObserver: NSObjectProtocol?

    private override init() {
        super.init()
        #if canImport(SystemExtensions)
        activateSystemExtension()
        #else
        loadManager()
        #endif
    }

    // MARK: - System Extension Activation

    #if canImport(SystemExtensions)
    func activateSystemExtension(force: Bool = false) {
        if activationRequestInFlight {
            dbg("activateSystemExtension skipped: request already in flight")
            return
        }
        if !force,
           (systemExtensionInstallState == .awaitingUserApproval || systemExtensionInstallState == .rebootRequired) {
            dbg("activateSystemExtension skipped: waiting for approval or reboot")
            return
        }

        dbg("activateSystemExtension called (force=\(force))")
        activationRequestInFlight = true
        updateInstallState(.activating)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: AppConstants.tunnelBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivateSystemExtension() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: AppConstants.tunnelBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    #endif

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    /// Check if the system extension is enabled by re-probing activation status.
    func checkExtensionStatus(forceRetry: Bool = false) {
        #if canImport(SystemExtensions)
        dbg("checkExtensionStatus(forceRetry=\(forceRetry)) state=\(String(describing: systemExtensionInstallState))")
        refreshSystemExtensionStatus(forceRetry: forceRetry)
        #else
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                let enabled = managers?.first?.isEnabled ?? false
                self?.extensionEnabled = enabled
                self?.dbg("checkExtensionStatus: enabled=\(enabled)")
            }
        }
        #endif
    }

    #if canImport(SystemExtensions)
    private func refreshSystemExtensionStatus(forceRetry: Bool) {
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error {
                self.dbg("refreshSystemExtensionStatus load error: \(error.localizedDescription)")
            }

            let hasConfig = !(managers ?? []).isEmpty
            DispatchQueue.main.async {
                if hasConfig {
                    self.updateInstallState(.active)
                    self.loadManager()
                    return
                }

                switch self.systemExtensionInstallState {
                case .awaitingUserApproval where !forceRetry,
                     .rebootRequired where !forceRetry:
                    self.extensionEnabled = false
                case .failed, .awaitingUserApproval, .rebootRequired:
                    self.activateSystemExtension(force: true)
                case .activating where self.activationRequestInFlight:
                    self.extensionEnabled = false
                default:
                    self.activateSystemExtension()
                }
            }
        }
    }

    private func updateInstallState(_ state: SystemExtensionInstallState) {
        systemExtensionInstallState = state
        switch state {
        case .active:
            extensionEnabled = true
            errorMessage = nil
        case .notInstalled, .activating, .awaitingUserApproval:
            extensionEnabled = false
            if errorMessage == "System extension is not installed yet." {
                errorMessage = nil
            }
        case .rebootRequired:
            extensionEnabled = false
            errorMessage = "System extension will activate after reboot"
        case .failed(let message):
            extensionEnabled = false
            errorMessage = message
        }
    }
    #endif

    // MARK: - Manager Lifecycle

    func loadManager() {
        guard !isLoadingManager else { return }
        isLoadingManager = true
        dbg("loadManager called")
        NETransparentProxyManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.dbg("loadManager load error: \(error.localizedDescription)")
            }
            let allManagers = (managers ?? []).compactMap { $0 as? NETransparentProxyManager }
            // Reuse existing manager if one exists, otherwise create new
            let mgr: NETransparentProxyManager
            if let existing = allManagers.first {
                self.dbg("loadManager: reusing existing config")
                mgr = existing
                // Remove duplicate configs
                for duplicate in allManagers.dropFirst() {
                    self.dbg("loadManager: removing duplicate config")
                    duplicate.removeFromPreferences(completionHandler: nil)
                }
            } else {
                self.dbg("loadManager: creating new config")
                mgr = self.createManager()
            }
            mgr.isEnabled = true
            mgr.saveToPreferences { error in
                if let error = error {
                    self.dbg("loadManager save error: \(error.localizedDescription)")
                }
                mgr.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        self.isLoadingManager = false
                        if let error = error {
                            self.dbg("loadManager reload error: \(error.localizedDescription)")
                        }
                        self.dbg("loadManager: manager ready")
                        self.manager = mgr
                        self.observeStatus()
                        // Auto-connect: if /tmp/.bld-autoconnect exists, start VPN
                        // Used by E2E tests to trigger connection without UI automation
                        let sentinelPath = "/tmp/.bld-autoconnect"
                        if FileManager.default.fileExists(atPath: sentinelPath),
                           self.status == .disconnected {
                            self.dbg("autoConnect: starting VPN")
                            try? FileManager.default.removeItem(atPath: sentinelPath)
                            self.start()
                        }
                    }
                }
            }
        }
    }

    private func createManager() -> NETransparentProxyManager {
        let manager = NETransparentProxyManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleIdentifier
        proto.serverAddress = "BaoLianDeng"
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "BaoLianDeng"
        manager.isEnabled = true

        return manager
    }

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let connection = manager?.connection else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            self?.status = connection.status
            if connection.status != .connecting && connection.status != .disconnecting {
                self?.isProcessing = false
            }
            if connection.status == .connected {
                self?.extensionEnabled = true
                self?.selectSavedProxyNode()
            }
            if connection.status == .disconnected {
                VPNManager.clearTunnelLog()
            }
        }

        status = connection.status
    }

    // MARK: - Connect / Disconnect

    func start() {
        dbg("start() called, isProcessing=\(isProcessing), manager=\(manager != nil), connStatus=\(manager?.connection.status.rawValue ?? -1)")
        guard !isProcessing else {
            dbg("start() blocked by isProcessing")
            return
        }

        isProcessing = true
        errorMessage = nil

        #if canImport(SystemExtensions)
        if !extensionEnabled {
            isProcessing = false
            errorMessage = "System extension is not installed yet."
            checkExtensionStatus(forceRetry: true)
            return
        }
        #endif

        // If the tunnel is stuck in .connecting from a previous failed attempt,
        // stop it first — calling startTunnel while .connecting is a no-op.
        if let connection = manager?.connection,
           connection.status == .connecting || connection.status == .reasserting {
            dbg("start() detected stuck .connecting, stopping first")
            connection.stopVPNTunnel()
            DispatchQueue.global().async { [weak self] in
                for i in 0..<30 {
                    let s = self?.manager?.connection.status
                    if s == .disconnected { break }
                    if i == 29 { self?.dbg("start() timeout waiting for disconnect, status=\(s?.rawValue ?? -1)") }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                DispatchQueue.main.async {
                    self?.dbg("start() retrying after stop")
                    self?.isProcessing = false
                    self?.start()
                }
            }
            return
        }

        let saveAndStart = { [weak self] in
            guard let self = self, let manager = self.manager else {
                DispatchQueue.main.async {
                    self?.dbg("start() manager is nil!")
                    self?.isProcessing = false
                    self?.errorMessage = "VPN manager not loaded"
                }
                return
            }

            self.dbg("saveAndStart: saving preferences")
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    self.dbg("saveToPrefs error: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.errorMessage = "Failed to save VPN config: \(error.localizedDescription)"
                    }
                    return
                }

                manager.loadFromPreferences { error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to reload VPN config: \(error.localizedDescription)"
                        }
                        return
                    }

                    // Re-observe status after loadFromPreferences
                    // (the connection object may have changed)
                    DispatchQueue.main.async {
                        self.observeStatus()
                    }

                    self.dbg("saveAndStart: calling startTunnel")
                    do {
                        try (manager.connection as? NETunnelProviderSession)?.startTunnel()
                        self.dbg("saveAndStart: startTunnel called OK")
                    } catch {
                        self.dbg("startTunnel error: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to start tunnel: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        // Ensure config exists before starting
        if !ConfigManager.shared.configExists() {
            do {
                let defaultConfig = ConfigManager.shared.defaultConfig()
                try ConfigManager.shared.saveConfig(defaultConfig)
            } catch {
                isProcessing = false
                errorMessage = "Failed to create default config: \(error.localizedDescription)"
                return
            }
        }

        // Pass subscription URL and settings to the extension via providerConfiguration
        // (avoids App Group which triggers Sequoia "access data from other apps" dialog)
        passSettingsToProvider()

        saveAndStart()
    }

    func stop() {
        isProcessing = true
        manager?.connection.stopVPNTunnel()
    }

    func toggle() {
        if isConnected {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Send Message to Tunnel

    func sendMessage(_ message: [String: Any], completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(nil)
            return
        }

        do {
            try session.sendProviderMessage(data) { response in
                completion(response)
            }
        } catch {
            completion(nil)
        }
    }

    func switchMode(_ mode: ProxyMode) {
        // Update config on disk, then restart the tunnel so it picks up the change
        ConfigManager.shared.setMode(mode.rawValue)
        guard isConnected else { return }
        isProcessing = true
        manager?.connection.stopVPNTunnel()

        // Wait for disconnect, then restart
        DispatchQueue.global().async { [weak self] in
            // Poll for disconnected state (up to 5s)
            for _ in 0..<50 {
                if self?.manager?.connection.status == .disconnected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.start()
            }
        }
    }

    /// Disconnect the VPN so subscription fetches bypass the tunnel.
    /// Returns true if the VPN was connected (caller should reconnect after fetching).
    func disconnectForFetch() async -> Bool {
        guard isConnected else { return false }
        manager?.connection.stopVPNTunnel()
        // Poll for disconnected state (up to 5s)
        for _ in 0..<50 {
            if manager?.connection.status == .disconnected { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// Select a specific proxy node via Mihomo's REST API.
    func selectNode(_ nodeName: String) {
        selectNodeViaRestAPI(nodeName)
    }

    /// Select the user's saved proxy node via Mihomo's REST API.
    private func selectSavedProxyNode() {
        let defaults = AppConstants.sharedDefaults
        guard let nodeName = defaults.string(forKey: "selectedNode"), !nodeName.isEmpty else {
            dbg("selectSavedProxyNode: no saved node")
            return
        }
        // Delay to let Mihomo's external controller finish initializing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.selectNodeViaRestAPI(nodeName, retriesLeft: 5)
        }
    }

    private func selectNodeViaRestAPI(_ nodeName: String, retriesLeft: Int = 0) {
        guard let url = URL(string: "http://\(AppConstants.externalControllerAddr)/proxies") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any] else {
                self?.dbg("selectNode: failed to fetch proxy list: \(error?.localizedDescription ?? "unknown") (retries=\(retriesLeft))")
                if retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.selectNodeViaRestAPI(nodeName, retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }
            // Build a name → members map across every group-like type that
            // exposes an `all` array. We need this to recursively resolve
            // bypass groups whose first member is itself another group.
            let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
            var groupMembers: [String: [String]] = [:]
            for (name, value) in proxies {
                guard let info = value as? [String: Any],
                      let type = info["type"] as? String,
                      groupTypes.contains(type),
                      let all = info["all"] as? [String] else { continue }
                groupMembers[name] = all
            }
            // For every non-bypass Selector group, decide what to push:
            //   - if the group lists the user's selected node → push the node
            //   - else if the group contains a Direct/REJECT member → push
            //     that bypass member (matches applySelectedNode's config-time
            //     rewrite: subscription authors list Direct in a group to
            //     indicate it should bypass the proxy).
            //   - else → leave alone
            var targets: [(group: String, selection: String)] = []
            for (name, value) in proxies {
                guard let info = value as? [String: Any],
                      (info["type"] as? String) == "Selector",
                      let all = info["all"] as? [String],
                      let first = all.first,
                      !isBypassGroup(firstMember: first, groupMembers: groupMembers) else { continue }
                if all.contains(nodeName) {
                    targets.append((name, nodeName))
                } else if let bypass = firstBypassMember(in: all, groupMembers: groupMembers) {
                    targets.append((name, bypass))
                }
            }
            self?.dbg("selectNode: \(nodeName) -> \(targets.map { "\($0.group)=\($0.selection)" })")
            for (groupName, selection) in targets {
                guard let encoded = groupName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let putURL = URL(string: "http://\(AppConstants.externalControllerAddr)/proxies/\(encoded)"),
                      let body = try? JSONSerialization.data(withJSONObject: ["name": selection]) else { continue }
                var request = URLRequest(url: putURL)
                request.httpMethod = "PUT"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                URLSession.shared.dataTask(with: request) { [weak self] _, response, putError in
                    if let putError = putError {
                        self?.dbg("selectNode \(groupName): \(putError.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self?.dbg("selectNode \(groupName): \(http.statusCode)")
                    }
                }.resume()
            }
        }.resume()
    }

    /// Build the full YAML config (base + subscription + user settings),
    /// zlib-compress it, and pass via providerConfiguration to overcome the 512 KB IPC limit.
    private func passSettingsToProvider() {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let defaults = AppConstants.sharedDefaults

        // Start with the base config
        var yaml = ConfigManager.shared.defaultConfig()

        // Merge selected subscription if available
        if let idString = defaults.string(forKey: "selectedSubscriptionID"),
           let data = defaults.data(forKey: "subscriptions") {
            struct Sub: Decodable { var id: UUID; var rawContent: String? }
            if let subs = try? JSONDecoder().decode([Sub].self, from: data),
               let selectedID = UUID(uuidString: idString),
               let selected = subs.first(where: { $0.id == selectedID }),
               let raw = selected.rawContent {
                yaml = ConfigManager.mergeSubscription(raw, baseConfig: yaml, defaultConfig: yaml)
            }
        }

        // Apply selected proxy node: save to disk, rewrite groups, read back
        if let selectedNode = defaults.string(forKey: "selectedNode"), !selectedNode.isEmpty {
            try? ConfigManager.shared.saveConfig(yaml)
            ConfigManager.shared.applySelectedNode()
            if let updated = try? ConfigManager.shared.loadConfig() {
                yaml = updated
            }
        }

        // Apply user settings
        if let logLevel = defaults.string(forKey: "logLevel") {
            yaml = yaml.replacingOccurrences(
                of: #"log-level:\s*\w+"#, with: "log-level: \(logLevel)",
                options: .regularExpression)
        }
        if let mode = defaults.string(forKey: "proxyMode") {
            // Anchor to a word boundary so we don't rewrite `enhanced-mode:`
            // (mihomo's DNS parser rejects `enhanced-mode: rule` with
            // "hub.Parse: invalid mode").
            yaml = yaml.replacingOccurrences(
                of: #"(?<![\w-])mode:\s*\w+"#, with: "mode: \(mode)",
                options: .regularExpression)
        }

        // Compress with zlib and store in providerConfiguration
        var providerConfig: [String: Any] = [:]
        if let yamlData = yaml.data(using: .utf8),
           let compressed = try? (yamlData as NSData).compressed(using: .zlib) as Data {
            providerConfig["configData"] = compressed
            dbg("passSettings: \(yamlData.count) -> \(compressed.count) bytes (zlib)")
        }

        // Pass per-app proxy settings as a separate JSON blob
        if let perAppData = defaults.data(forKey: AppConstants.perAppProxySettingsKey) {
            providerConfig["perAppProxy"] = perAppData
        }

        proto.providerConfiguration = providerConfig
        manager?.protocolConfiguration = proto
    }

    /// Restart the tunnel if currently connected so new settings take effect.
    func restartIfConnected() {
        guard isConnected else { return }
        isProcessing = true
        manager?.connection.stopVPNTunnel()
        DispatchQueue.global().async { [weak self] in
            for _ in 0..<50 {
                if self?.manager?.connection.status == .disconnected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.start()
            }
        }
    }

    private func openNetworkExtensionSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private static func clearTunnelLog() {
        // Log is now in the extension's sandbox — cleared on next startTunnel
    }
}

#if canImport(SystemExtensions)
// MARK: - OSSystemExtensionRequestDelegate

extension VPNManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        dbg("didFinish: result=\(result.rawValue)")
        activationRequestInFlight = false
        switch result {
        case .completed:
            DispatchQueue.main.async { self.updateInstallState(.active) }
            loadManager()
        case .willCompleteAfterReboot:
            DispatchQueue.main.async {
                self.updateInstallState(.rebootRequired)
            }
        @unknown default:
            loadManager()
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        dbg("didFail: \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)")
        activationRequestInFlight = false
        // requestSuperseded (code 4) means extension is already active
        if nsError.domain == "OSSystemExtensionErrorDomain" && nsError.code == 4 {
            DispatchQueue.main.async { self.updateInstallState(.active) }
            loadManager()
        } else {
            DispatchQueue.main.async {
                self.updateInstallState(.failed("System extension error: \(error.localizedDescription)"))
            }
        }
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        dbg("needsUserApproval")
        activationRequestInFlight = false
        DispatchQueue.main.async { self.updateInstallState(.awaitingUserApproval) }
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        dbg("replacing \(existing.bundleShortVersion) with \(ext.bundleShortVersion)")
        return .replace
    }
}
#endif
