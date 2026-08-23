// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import MihomoCore
@testable import BaoLianDeng

/// Helper that manages mihomo engine lifecycle for integration tests.
/// Creates a temp directory, writes config, starts engine, and cleans up.
enum ProxyEngineHelper {

    struct EngineContext {
        let tempDir: String
        let socksPort: UInt16
        let controllerAddr: String
    }

    /// Start the mihomo engine with the given YAML config.
    /// Returns a context for cleanup. Call `stop(context:)` when done.
    static func start(config: String) throws -> EngineContext {
        // Always stop any previously running engine and wait for full shutdown
        BridgeStopProxy()
        Thread.sleep(forTimeInterval: 1.0)

        let tempDir = NSTemporaryDirectory() + "bld-engine-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        // Copy geodata files
        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)

        // Write config
        let configPath = tempDir + "/config.yaml"
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Set home dir and start
        BridgeSetHomeDir(tempDir)

        // Pick test ports up-front so we can pass them to the bridge
        // and assert against them. Mirrors the production flow.
        guard let socksPort = EphemeralPort.pickTCP(),
              let dnsPort = EphemeralPort.pickDNS(),
              let ctrl = EphemeralPort.pickTCP() else {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw NSError(domain: "ProxyEngineHelper", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "could not pick test ports"])
        }
        let controllerAddr = "127.0.0.1:\(ctrl)"

        var startError: NSError?
        BridgeStartWithPorts(
            Int32(socksPort), Int32(dnsPort), controllerAddr, "", &startError
        )
        if let err = startError {
            try? FileManager.default.removeItem(atPath: tempDir)
            throw err
        }

        // Wait for external controller to be ready
        Thread.sleep(forTimeInterval: 1.0)

        return EngineContext(
            tempDir: tempDir,
            socksPort: socksPort,
            controllerAddr: controllerAddr
        )
    }

    /// Stop the engine and clean up temp files.
    static func stop(context: EngineContext) {
        BridgeStopProxy()
        Thread.sleep(forTimeInterval: 0.5)
        try? FileManager.default.removeItem(atPath: context.tempDir)
    }

    /// Run curl through the SOCKS5 proxy and return (stdout, exitCode).
    static func curlThroughProxy(
        url: String,
        socksPort: UInt16,
        timeout: Int = 10
    ) -> (output: String, exitCode: Int32) {
        // socks5h: send the hostname to the engine. `--socks5` resolves
        // locally first, which fails when system DNS is still holding a
        // leftover fake-ip (or a hanging AAAA) from a previous tunnel.
        curl(url: url, proxyArgs: ["--socks5-hostname", "127.0.0.1:\(socksPort)"], timeout: timeout)
    }

    /// Run curl through the HTTP side of the mixed listener — the path
    /// local-proxy-mode clients configured with an HTTP proxy take.
    static func curlThroughHTTPProxy(
        url: String,
        proxyPort: UInt16,
        timeout: Int = 10
    ) -> (output: String, exitCode: Int32) {
        curl(url: url, proxyArgs: ["--proxy", "http://127.0.0.1:\(proxyPort)"], timeout: timeout)
    }

    private static func curl(
        url: String,
        proxyArgs: [String],
        timeout: Int
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = proxyArgs + [
            "--silent",
            "--max-time", "\(timeout)",
            "--write-out", "%{http_code}",
            "--output", "/dev/null",
            url
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ("", -1)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }
}
