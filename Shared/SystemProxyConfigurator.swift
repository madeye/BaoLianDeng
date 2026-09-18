// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation

/// Points macOS's HTTP, HTTPS and SOCKS proxy settings at the in-process
/// local proxy while it runs, and switches them off again when it stops.
///
/// Changes go through `/usr/sbin/networksetup` rather than the
/// SCPreferences API: the tool carries the private authorization
/// entitlement for `system.services.systemconfiguration.network`, so an
/// admin user gets no password prompt, whereas a direct
/// `SCPreferencesCreateWithAuthorization` from this process would prompt on
/// every change (the right's rule is `authenticate-admin-nonshared`). The
/// App Sandbox permits exec of `/usr/sbin`, and the Network Extension
/// entitlement unlocks the SystemConfiguration helper lookup the tool needs.
///
/// A persisted "applied" flag survives crashes so a stale proxy left behind
/// by a killed app is cleared on the next launch (`clearIfStale`).
final class SystemProxyConfigurator {
    static let shared = SystemProxyConfigurator()

    static let networksetupPath = "/usr/sbin/networksetup"
    static let loopbackHost = "127.0.0.1"

    enum SystemProxyError: LocalizedError {
        case toolUnavailable
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .toolUnavailable:
                return String(localized: "Could not run networksetup.")
            case .commandFailed(let detail):
                return String(
                    format: String(localized: "System proxy command failed: %@"), detail
                )
            }
        }
    }

    typealias CommandRunner = ([String]) throws -> String

    private let defaults: UserDefaults
    private let runner: CommandRunner
    private let lock = NSLock()

    init(
        defaults: UserDefaults = AppConstants.sharedDefaults,
        runner: @escaping CommandRunner = SystemProxyConfigurator.runNetworksetup
    ) {
        self.defaults = defaults
        self.runner = runner
    }

    /// True while this app has pointed the system proxy at itself and not
    /// yet cleared it. Persisted so a crash can be cleaned up on relaunch.
    var isApplied: Bool {
        defaults.bool(forKey: AppConstants.systemProxyAppliedKey)
    }

    /// Point every enabled network service's HTTP/HTTPS/SOCKS proxy at
    /// `host:port`. Blocking (one `networksetup` run per setting per
    /// service) — call off the main thread.
    func apply(host: String = SystemProxyConfigurator.loopbackHost, port: UInt16) throws {
        lock.lock()
        defer { lock.unlock() }
        let services = try enabledServices()
        // Mark before writing so a partial failure still gets cleaned up.
        defaults.set(true, forKey: AppConstants.systemProxyAppliedKey)
        for args in Self.applyArguments(services: services, host: host, port: port) {
            try run(args)
        }
        AppLogger.vpn.notice(
            "System proxy set to \(host, privacy: .public):\(port) on \(services.count) service(s)"
        )
    }

    /// Switch the HTTP/HTTPS/SOCKS proxy off on every enabled network
    /// service. Blocking — call off the main thread unless the app is
    /// quitting.
    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        let services = try enabledServices()
        var firstError: Error?
        for args in Self.clearArguments(services: services) {
            do {
                try run(args)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError {
            throw firstError
        }
        defaults.set(false, forKey: AppConstants.systemProxyAppliedKey)
        AppLogger.vpn.notice("System proxy cleared on \(services.count) service(s)")
    }

    /// Clear a proxy left behind by a previous instance that never got to
    /// `clear()` (crash, force quit). No-op when nothing was applied.
    func clearIfStale() {
        guard isApplied else { return }
        AppLogger.vpn.notice("Clearing stale system proxy from a previous run")
        do {
            try clear()
        } catch {
            AppLogger.vpn.error(
                "Stale system proxy cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Command construction (pure, unit-tested)

    /// Service names from `networksetup -listallnetworkservices` output.
    /// The first line is a legend; services prefixed with `*` are disabled
    /// and skipped, since networksetup refuses to configure them.
    static func parseServiceNames(from output: String) -> [String] {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("An asterisk") }
            .filter { !$0.hasPrefix("*") }
    }

    static func applyArguments(services: [String], host: String, port: UInt16) -> [[String]] {
        let portString = String(port)
        return services.flatMap { service in
            [
                ["-setwebproxy", service, host, portString],
                ["-setsecurewebproxy", service, host, portString],
                ["-setsocksfirewallproxy", service, host, portString]
            ]
        }
    }

    static func clearArguments(services: [String]) -> [[String]] {
        services.flatMap { service in
            [
                ["-setwebproxystate", service, "off"],
                ["-setsecurewebproxystate", service, "off"],
                ["-setsocksfirewallproxystate", service, "off"]
            ]
        }
    }

    // MARK: - Execution

    private func enabledServices() throws -> [String] {
        Self.parseServiceNames(from: try run(["-listallnetworkservices"]))
    }

    @discardableResult
    private func run(_ arguments: [String]) throws -> String {
        let output = try runner(arguments)
        // networksetup reports some failures on stdout with exit status 0.
        if output.contains("** Error") {
            throw SystemProxyError.commandFailed(
                "\(arguments.joined(separator: " ")): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return output
    }

    /// Default runner: spawn `networksetup` and capture stdout + stderr.
    static func runNetworksetup(_ arguments: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: networksetupPath) else {
            throw SystemProxyError.toolUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: networksetupPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw SystemProxyError.toolUnavailable
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SystemProxyError.commandFailed(
                "\(arguments.joined(separator: " ")) exited \(process.terminationStatus): "
                    + output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output
    }
}
