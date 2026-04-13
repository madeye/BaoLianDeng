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

import Foundation
import MihomoCore
@testable import BaoLianDeng

/// Helper that manages mihomo engine lifecycle for integration tests.
/// Creates a temp directory, writes config, starts engine, and cleans up.
enum ProxyEngineHelper {

    struct EngineContext {
        let tempDir: String
        let configPath: String
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

        var startError: NSError?
        BridgeStartWithExternalController("127.0.0.1:9090", "", &startError)
        if let err = startError {
            // Clean up on failure
            try? FileManager.default.removeItem(atPath: tempDir)
            throw err
        }

        // Wait for external controller to be ready
        Thread.sleep(forTimeInterval: 1.0)

        return EngineContext(tempDir: tempDir, configPath: configPath)
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
        timeout: Int = 10
    ) -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--socks5", "127.0.0.1:7890",
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
