// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import MihomoCore

/// Hosts the meow-rs engine inside the calling process as a plain local
/// proxy: a mixed HTTP/SOCKS5 listener on `127.0.0.1:<localProxyPort>`.
/// Nothing is intercepted — apps must be pointed at the listener manually.
/// This is the non-transparent-proxy counterpart to
/// `TransparentProxyProvider`, sharing the same engine and REST controller
/// conventions (controller address + secret published via
/// `AppConstants.sharedDefaults`) so the existing proxy-group, connection,
/// and traffic UIs work unchanged.
final class LocalProxyController {
    static let shared = LocalProxyController()

    private(set) var isRunning = false
    /// Port of the mixed HTTP/SOCKS5 listener while running, else 0.
    private(set) var mixedPort: UInt16 = 0

    private init() {}

    enum LocalProxyError: LocalizedError {
        case configDirectoryUnavailable
        case portInUse(UInt16)
        case ephemeralPortsUnavailable

        var errorDescription: String? {
            switch self {
            case .configDirectoryUnavailable:
                return String(localized: "Could not resolve the configuration directory.")
            case .portInUse(let port):
                return String(
                    format: String(localized: "Local proxy port %@ is already in use."),
                    String(port)
                )
            case .ephemeralPortsUnavailable:
                return String(localized: "Could not allocate internal ports for the proxy engine.")
            }
        }
    }

    /// Write `configYAML` to the config directory and start the engine.
    /// Blocking (engine startup + geodata check) — call off the main thread.
    func start(configYAML: String) throws {
        guard !isRunning else { return }

        guard let configDirURL = ConfigManager.shared.configDirectoryURL else {
            throw LocalProxyError.configDirectoryUnavailable
        }
        let configDir = configDirURL.path
        try FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )
        try configYAML.write(
            toFile: configDir + "/" + AppConstants.configFileName,
            atomically: true, encoding: .utf8
        )
        ConfigManager.shared.sanitizeConfig()

        let defaults = AppConstants.sharedDefaults
        let port = AppConstants.localProxyPort
        guard EphemeralPort.isTCPPortFree(port) else {
            throw LocalProxyError.portInUse(port)
        }
        // The engine still needs its DNS resolver and REST controller;
        // neither is user-facing here, so ephemeral ports as in VPN mode.
        guard let dnsPort = EphemeralPort.pickDNS(),
              let ctrlPort = EphemeralPort.pickTCP() else {
            throw LocalProxyError.ephemeralPortsUnavailable
        }

        let logDir = configDirURL.deletingLastPathComponent()
        BridgeSetLogFile(logDir.appendingPathComponent("rust_bridge.log").path)
        ConfigManager.shared.ensureGeodataFiles(configDir: configDir)
        BridgeSetHomeDir(configDir)

        let controllerAddr = "127.0.0.1:\(ctrlPort)"
        let secret = AppConstants.generateControllerSecret() ?? ""

        var startError: NSError?
        BridgeStartWithPorts(
            Int32(port), Int32(dnsPort), controllerAddr, secret, &startError
        )
        if let startError = startError {
            throw startError
        }

        // Publish the controller endpoint exactly like the VPN path does so
        // every existing REST client picks it up.
        defaults.set(controllerAddr, forKey: AppConstants.externalControllerAddrKey)
        defaults.set(secret, forKey: AppConstants.externalControllerSecretKey)

        BridgeUpdateLogLevel(defaults.string(forKey: "logLevel") ?? "info")

        mixedPort = port
        isRunning = true
        AppLogger.vpn.notice(
            "Local proxy started: mixed=\(port) dns=\(dnsPort) controller=\(controllerAddr, privacy: .public)"
        )
    }

    func stop() {
        guard isRunning else { return }
        BridgeStopProxy()
        isRunning = false
        mixedPort = 0
        AppLogger.vpn.notice("Local proxy stopped")
    }

    /// In-process equivalent of `TransparentProxyProvider.handleAppMessage`
    /// so `VPNManager.sendMessage` callers work identically in both modes.
    func handleMessage(_ message: [String: Any]) -> Data? {
        guard let action = message["action"] as? String else { return nil }
        switch action {
        case "get_traffic":
            return responseData([
                "upload": BridgeGetUploadTraffic(),
                "download": BridgeGetDownloadTraffic()
            ])
        case "get_version":
            return responseData(["version": BridgeVersion()])
        case "get_log":
            return readLog().data(using: .utf8)
        default:
            return nil
        }
    }

    private func responseData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }

    /// Engine log for the log viewer — the in-process equivalent of the
    /// provider's `get_log` IPC response.
    func readLog() -> String {
        guard let dir = ConfigManager.shared.configDirectoryURL?
            .deletingLastPathComponent() else { return "" }
        let url = dir.appendingPathComponent("rust_bridge.log")
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let maxResponseBytes = 256 * 1024
        if content.utf8.count > maxResponseBytes,
           let tail = String(content.utf8.suffix(maxResponseBytes)) {
            content = "… (truncated)\n" + tail
        }
        return content
    }
}
