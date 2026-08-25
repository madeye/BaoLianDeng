// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

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
    /// How the engine is hosted: transparent-proxy extension (`.vpn`) or an
    /// in-process local HTTP/SOCKS5 listener (`.localProxy`). Persisted in
    /// UserDefaults; change via `setEngineMode`.
    @Published private(set) var engineMode: EngineMode = .vpn
    private var activationRequestInFlight = false
    private var isLoadingManager = false
    private var didAttemptAutoStartAtLogin = false
    private func dbg(_ msg: String) {
        AppLogger.vpn.notice("\(msg, privacy: .public)")
    }

    private var manager: NETransparentProxyManager?
    private var statusObserver: NSObjectProtocol?

    /// True when the provider ships as an app extension in PlugIns (Mac App
    /// Store packaging) instead of a system extension. Appexes need no
    /// OSSystemExtensionRequest activation or System Settings approval —
    /// the system launches them directly from the app bundle.
    static let providerIsAppExtension: Bool = {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(atPath: plugins.path) else {
            return false
        }
        return items.contains { $0.hasSuffix(".appex") }
    }()

    private override init() {
        super.init()
        engineMode = EngineMode.load(from: AppConstants.sharedDefaults)
        // Don't touch the system extension or the user's real NE preferences
        // when the app is only hosting unit tests.
        if AppConstants.isRunningUnitTests {
            return
        }
        // Local proxy mode never touches the system extension or NE
        // preferences — a local-only user should see no approval prompts
        // or "add VPN configurations" dialogs.
        if engineMode == .localProxy {
            DispatchQueue.main.async { [weak self] in
                self?.startAtLoginIfNeeded()
            }
            return
        }
        #if canImport(SystemExtensions)
        if Self.providerIsAppExtension {
            updateInstallState(.active)
            loadManager()
        } else {
            activateSystemExtension()
        }
        #else
        loadManager()
        #endif
    }

    /// Switch how the engine is hosted. Stops the currently running proxy
    /// (either kind) first; the user reconnects explicitly in the new mode.
    func setEngineMode(_ mode: EngineMode) {
        guard mode != engineMode else { return }
        if isConnected || isProcessing {
            stop()
        }
        engineMode = mode
        errorMessage = nil
        AppConstants.sharedDefaults.set(mode.rawValue, forKey: AppConstants.engineModeKey)
        dbg("setEngineMode: \(mode.rawValue)")
        if mode == .vpn {
            // Entering VPN mode may need extension activation + NE config.
            checkExtensionStatus()
        }
    }

    // MARK: - System Extension Activation

    #if canImport(SystemExtensions)
    func activateSystemExtension(force: Bool = false) {
        if Self.providerIsAppExtension {
            dbg("activateSystemExtension skipped: provider is an app extension")
            return
        }
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
        guard !AppConstants.isRunningUnitTests else { return }
        guard engineMode == .vpn else { return }
        #if canImport(SystemExtensions)
        if Self.providerIsAppExtension {
            updateInstallState(.active)
            if manager == nil { loadManager() }
            return
        }
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
        guard !AppConstants.isRunningUnitTests else { return }
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
                        self.startAtLoginIfNeeded()
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

    private func startAtLoginIfNeeded() {
        guard !didAttemptAutoStartAtLogin else { return }
        didAttemptAutoStartAtLogin = true

        guard AppConstants.sharedDefaults.bool(forKey: AppConstants.autoStartVPNAtLoginKey),
              status == .disconnected else { return }

        dbg("startAtLoginIfNeeded: starting VPN")
        start()
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
                self?.replaySavedGroupSelections()
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

        if engineMode == .localProxy {
            startLocalProxy()
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
        // Local engine stops synchronously; also handles the defensive case
        // of a lingering in-process engine after a mode switch.
        if LocalProxyController.shared.isRunning {
            LocalProxyController.shared.stop()
            status = .disconnected
            isProcessing = false
            return
        }
        if engineMode == .localProxy {
            return
        }
        isProcessing = true
        manager?.connection.stopVPNTunnel()
    }

    // MARK: - Local Proxy Mode

    /// Start the engine in-process as a plain HTTP/SOCKS5 listener.
    /// The non-transparent-proxy counterpart to the tunnel start path.
    private func startLocalProxy() {
        isProcessing = true
        errorMessage = nil

        // Ensure config exists before starting (same as the tunnel path)
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

        let yaml = buildEffectiveConfigYAML()
        status = .connecting
        dbg("startLocalProxy: port=\(AppConstants.localProxyPort)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try LocalProxyController.shared.start(configYAML: yaml)
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    self?.status = .connected
                    self?.replaySavedGroupSelections()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isProcessing = false
                    self?.status = .disconnected
                    self?.errorMessage = String(
                        format: String(localized: "Failed to start local proxy: %@"),
                        error.localizedDescription
                    )
                }
            }
        }
    }

    /// Stop + start the in-process engine so config changes take effect.
    private func restartLocalProxy() {
        LocalProxyController.shared.stop()
        status = .disconnected
        startLocalProxy()
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
        // Local mode: the engine lives in this process — answer directly
        // instead of round-tripping through provider IPC.
        if engineMode == .localProxy {
            completion(LocalProxyController.shared.handleMessage(message))
            return
        }

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
        if engineMode == .localProxy {
            restartLocalProxy()
            return
        }
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
        // A local proxy doesn't intercept this process's traffic — fetches
        // already bypass it, so there is nothing to disconnect.
        if engineMode == .localProxy { return false }
        manager?.connection.stopVPNTunnel()
        // Poll for disconnected state (up to 5s)
        for _ in 0..<50 {
            if manager?.connection.status == .disconnected { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    /// Replay the user's saved per-group selections to the engine via the REST
    /// API. The engine resets every `Selector` group to its config default on
    /// each start, so without this the user's choices are lost on reconnect.
    ///
    /// Only groups the user actually chose in are touched, and only with a
    /// value the group still lists — selections are scoped per subscription
    /// (`ProxyGroupSelections`), so nothing from another subscription can be
    /// pushed here. This replaces the old `selectedNode` path, which pushed a
    /// single global node name into *every* non-bypass Selector group.
    private func replaySavedGroupSelections() {
        let saved = ProxyGroupSelections.load()
        guard !saved.isEmpty else {
            dbg("replayGroupSelections: nothing saved for this subscription")
            return
        }
        // Delay to let Mihomo's external controller finish initializing
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.replayGroupSelectionsViaRestAPI(saved, retriesLeft: 5)
        }
    }

    private func replayGroupSelectionsViaRestAPI(
        _ saved: [String: String],
        retriesLeft: Int = 0
    ) {
        guard let url = AppConstants.externalControllerURL(pathSegments: ["proxies"]) else {
            // Controller addr not yet published by the extension; retry.
            if retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.replayGroupSelectionsViaRestAPI(saved, retriesLeft: retriesLeft - 1)
                }
            }
            return
        }
        URLSession.shared.dataTask(with: AppConstants.authorizedControllerRequest(url: url)) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any] else {
                self?.dbg("replayGroupSelections: failed to fetch proxy list: \(error?.localizedDescription ?? "unknown") (retries=\(retriesLeft))")
                if retriesLeft > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.replayGroupSelectionsViaRestAPI(saved, retriesLeft: retriesLeft - 1)
                    }
                }
                return
            }
            // Push a saved choice only into a Selector group that still exists
            // and still lists it. Engine-managed groups (URLTest, Fallback, …)
            // pick their own member and are never pinned.
            var targets: [(group: String, selection: String)] = []
            for (group, selection) in saved {
                guard let info = proxies[group] as? [String: Any],
                      (info["type"] as? String) == "Selector",
                      let all = info["all"] as? [String],
                      all.contains(selection) else { continue }
                targets.append((group, selection))
            }
            self?.dbg("replayGroupSelections: \(targets.map { "\($0.group)=\($0.selection)" })")
            for (groupName, selection) in targets {
                guard let putURL = AppConstants.externalControllerURL(pathSegments: ["proxies", groupName]),
                      let body = try? JSONSerialization.data(withJSONObject: ["name": selection]) else { continue }
                var request = AppConstants.authorizedControllerRequest(url: putURL, method: "PUT")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                URLSession.shared.dataTask(with: request) { [weak self] _, response, putError in
                    if let putError = putError {
                        self?.dbg("replayGroupSelections \(groupName): \(putError.localizedDescription)")
                    } else if let http = response as? HTTPURLResponse {
                        self?.dbg("replayGroupSelections \(groupName): \(http.statusCode)")
                    }
                }.resume()
            }
        }.resume()
    }

    /// Point the engine's GLOBAL selector at a real target so global mode
    /// routes through the proxy instead of GLOBAL's default (DIRECT, the
    /// first entry of its sorted member list). Prefers the user's own GLOBAL
    /// selection for this subscription, but that name can be stale after a
    /// subscription refresh renames nodes — then falls back to the largest
    /// non-bypass selector group (the subscription's node-choice group),
    /// which tracks future node changes.
    func syncGlobalSelector() {
        guard let url = AppConstants.externalControllerURL(pathSegments: ["proxies"]) else { return }
        URLSession.shared.dataTask(with: AppConstants.authorizedControllerRequest(url: url)) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any],
                  let global = proxies["GLOBAL"] as? [String: Any],
                  let globalMembers = global["all"] as? [String] else { return }

            let groupTypes: Set<String> = ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"]
            var groupMembers: [String: [String]] = [:]
            for (name, value) in proxies {
                guard let info = value as? [String: Any],
                      let type = info["type"] as? String,
                      groupTypes.contains(type),
                      let all = info["all"] as? [String] else { continue }
                groupMembers[name] = all
            }

            var target: String?
            let saved = ProxyGroupSelections.load()["GLOBAL"]
            if let saved = saved, !saved.isEmpty, globalMembers.contains(saved) {
                target = saved
            } else {
                // A selector group whose current selection chain ends at a
                // real proxy node reflects what the user routes through today.
                // Prefer the largest such group (the subscription's node-choice
                // group); the bypass heuristic is useless here because many
                // subscriptions list DIRECT first in every group.
                func resolvesToProxy(_ name: String, depth: Int = 0) -> Bool {
                    if depth > 8 || name == "DIRECT" || name.hasPrefix("REJECT") { return false }
                    guard let info = proxies[name] as? [String: Any] else { return false }
                    if let now = info["now"] as? String, !now.isEmpty {
                        return resolvesToProxy(now, depth: depth + 1)
                    }
                    return groupMembers[name] == nil
                }
                target = proxies
                    .compactMap { name, value -> (name: String, size: Int)? in
                        guard name != "GLOBAL",
                              let info = value as? [String: Any],
                              (info["type"] as? String) == "Selector",
                              let all = info["all"] as? [String],
                              globalMembers.contains(name),
                              resolvesToProxy(name) else { return nil }
                        return (name, all.count)
                    }
                    .sorted { $0.size == $1.size ? $0.name < $1.name : $0.size > $1.size }
                    .first?.name
            }

            guard let selection = target else {
                self.dbg("syncGlobalSelector: no valid target for GLOBAL")
                return
            }
            self.dbg("syncGlobalSelector: GLOBAL=\(selection)")
            guard let putURL = AppConstants.externalControllerURL(pathSegments: ["proxies", "GLOBAL"]),
                  let body = try? JSONSerialization.data(withJSONObject: ["name": selection]) else { return }
            var request = AppConstants.authorizedControllerRequest(url: putURL, method: "PUT")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            URLSession.shared.dataTask(with: request) { [weak self] _, response, putError in
                if let putError = putError {
                    self?.dbg("syncGlobalSelector: \(putError.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    self?.dbg("syncGlobalSelector: PUT \(http.statusCode)")
                }
            }.resume()
        }.resume()
    }

    /// Build the full effective YAML config: base + selected subscription +
    /// selected node + user settings (log level, routing mode, GLOBAL group).
    /// Shared by the tunnel path (compressed into providerConfiguration) and
    /// the local proxy path (written straight to disk).
    private func buildEffectiveConfigYAML() -> String {
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
                yaml = ConfigManager.mergeSubscription(
                    raw, baseConfig: yaml, defaultConfig: yaml, engineMode: engineMode
                )
            }
        }

        // No group rewriting here. The engine starts each Selector group on
        // the config's own first member and `replaySavedGroupSelections()`
        // pushes the user's per-group choices once the controller is up. The
        // old `applySelectedNode()` rewrite was both wrong (one global node
        // forced into every group) and lossy: it round-tripped proxy-groups
        // through the editable parser, which drops `use:`, `filter:`, `lazy:`
        // and friends, emptying provider-backed groups.

        // Apply user settings
        if let logLevel = defaults.string(forKey: "logLevel") {
            yaml = ConfigManager.replacingTopLevelScalar(
                in: yaml, key: "log-level", value: logLevel
            )
        }
        let mode = defaults.string(forKey: "proxyMode") ?? "rule"
        yaml = ConfigManager.replacingTopLevelScalar(
            in: yaml, key: "mode", value: mode
        )
        // Global mode routes everything through the GLOBAL selector. Define it
        // with the selected node first — otherwise the engine auto-creates one
        // whose sorted member list puts DIRECT first, so global mode would
        // silently send all traffic direct.
        yaml = ConfigManager.shared.updateGlobalProxyGroup(yaml, enabled: mode == "global")

        // Clash-compatible allow-lan: engine reads these from YAML (no FFI arg).
        // When enabled, mixed-port is the LAN-facing listener; in local-proxy
        // mode it usually equals the user-facing mixed port and merges into
        // one 0.0.0.0 bind. DNS + external-controller stay loopback either way.
        let lan = LANSharingSettings.load(from: defaults)
        yaml = ConfigManager.replacingTopLevelScalar(
            in: yaml, key: "allow-lan", value: lan.enabled ? "true" : "false"
        )
        if lan.enabled {
            yaml = ConfigManager.replacingTopLevelScalar(
                in: yaml, key: "bind-address", value: "0.0.0.0"
            )
            yaml = ConfigManager.replacingTopLevelScalar(
                in: yaml, key: "mixed-port", value: String(lan.effectiveProxyPort)
            )
        } else if engineMode == .localProxy {
            // Document the local mixed port even without LAN; the bridge still
            // forces the actual bind from the socks_port argument.
            yaml = ConfigManager.replacingTopLevelScalar(
                in: yaml, key: "mixed-port", value: String(AppConstants.localProxyPort)
            )
        }

        return yaml
    }

    /// Build the full YAML config (base + subscription + user settings),
    /// zlib-compress it, and pass via providerConfiguration to overcome the 512 KB IPC limit.
    private func passSettingsToProvider() {
        guard let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol else { return }
        let defaults = AppConstants.sharedDefaults
        let yaml = buildEffectiveConfigYAML()

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

        // Pick ephemeral 127.0.0.1 ports for the SOCKS5, DNS, and REST
        // controller listeners and forward them to the extension. We
        // pick in this process (not the extension) so the app's REST
        // clients learn the controller port without an IPC round-trip
        // — both targets use a separate UserDefaults.standard, so a
        // value the extension wrote wouldn't be visible here. The
        // extension passes these straight to BridgeStartWithPorts.
        if let socks = EphemeralPort.pickTCP(),
           let dns = EphemeralPort.pickDNS(),
           let ctrl = EphemeralPort.pickTCP() {
            let ctrlAddr = "127.0.0.1:\(ctrl)"
            providerConfig["socksPort"] = Int(socks)
            providerConfig["dnsPort"] = Int(dns)
            providerConfig["controllerAddr"] = ctrlAddr
            defaults.set(ctrlAddr, forKey: AppConstants.externalControllerAddrKey)
            if let secret = AppConstants.generateControllerSecret() {
                providerConfig["secret"] = secret
                defaults.set(secret, forKey: AppConstants.externalControllerSecretKey)
            } else {
                dbg("passSettings: WARN failed to generate controller secret")
            }
            dbg("passSettings: ports socks=\(socks) dns=\(dns) ctrl=\(ctrl)")
        } else {
            dbg("passSettings: WARN failed to pick ephemeral ports")
        }

        proto.providerConfiguration = providerConfig
        manager?.protocolConfiguration = proto
    }

    /// Restart the tunnel if currently connected so new settings take effect.
    func restartIfConnected() {
        guard isConnected else { return }
        if engineMode == .localProxy {
            restartLocalProxy()
            return
        }
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
