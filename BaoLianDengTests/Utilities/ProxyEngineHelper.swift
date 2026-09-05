// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import MihomoCore
@testable import BaoLianDeng

/// Helper that manages mihomo engine lifecycle for integration tests.
/// Creates a temp directory, writes config, starts engine, and cleans up.
enum ProxyEngineHelper {

    // meow-rs pins its resource-cache home on first use in this process.
    // Recreate one directory per test so seeded caches use the real home.
    private static let engineHome = NSTemporaryDirectory() + "bld-engine-test-\(UUID().uuidString)"

    struct EngineContext {
        let tempDir: String
        let socksPort: UInt16
        let controllerAddr: String
        let controllerSecret: String
    }

    /// Start the mihomo engine with the given YAML config.
    /// Returns a context for cleanup. Call `stop(context:)` when done.
    /// - Parameter controllerSecret: REST controller secret. Defaults to ""
    ///   (open controller) so existing callers keep querying it unauthenticated;
    ///   pass a value to exercise the authenticated path production always uses.
    static func start(
        config: String, controllerSecret: String = "", selectorCache: [String: String]? = nil
    ) throws -> EngineContext {
        // Always stop any previously running engine and wait for full shutdown
        BridgeStopProxy()
        Thread.sleep(forTimeInterval: 1.0)

        let tempDir = engineHome
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        // Copy geodata files
        ConfigManager.shared.ensureGeodataFiles(configDir: tempDir)

        // Write config
        let configPath = tempDir + "/config.yaml"
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)

        if let selectorCache {
            let cache = try JSONSerialization.data(withJSONObject: selectorCache)
            try cache.write(to: URL(fileURLWithPath: tempDir + "/selector-cache.json"))
        }

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
            Int32(socksPort), Int32(dnsPort), controllerAddr, controllerSecret, &startError
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
            controllerAddr: controllerAddr,
            controllerSecret: controllerSecret
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
        curl(url: url, proxyArgs: ["--socks5", "127.0.0.1:\(socksPort)"], timeout: timeout)
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
            // curl 7.86+ silently bypasses the proxy for localhost targets.
            // Every one of these tests exists to exercise the proxy, and the
            // hermetic target IS on localhost, so an empty no-proxy list is
            // load-bearing: without it the request never reaches the engine
            // and the assertion passes for the wrong reason.
            "--noproxy", "",
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

/// Minimal loopback HTTP server used as a hermetic target for the proxy-chain
/// tests. Answers every request with `204 No Content` and closes.
///
/// These tests used to curl a public host. `curl --socks5` resolves the name
/// itself and hands the engine a raw IP literal, so on any network that blocks
/// the target by IP the engine's DIRECT dial times out and the test fails for
/// reasons that have nothing to do with the proxy chain. A loopback target
/// exercises the same machinery — SOCKS5 CONNECT with ATYP=0x01, rule match,
/// DIRECT dial to an IPv4 literal, bidirectional relay — without the internet.
///
/// Call `stop()` when done; the accept loop holds a strong reference to the
/// server until the listening socket closes.
final class LocalHTTPServer {

    /// Kernel-assigned port the server listens on at 127.0.0.1.
    let port: UInt16

    private let listenFD: Int32
    private let lock = NSLock()
    private var isStopped = false

    /// Binds 127.0.0.1 on a free port and starts accepting. Nil if the socket
    /// could not be set up.
    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var wanted = sockaddr_in()
        wanted.sin_family = sa_family_t(AF_INET)
        wanted.sin_port = 0
        wanted.sin_addr.s_addr = inet_addr("127.0.0.1")

        let didBind = withUnsafePointer(to: &wanted) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard didBind, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didName = withUnsafeMutablePointer(to: &actual) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length) == 0
            }
        }
        guard didName else {
            close(fd)
            return nil
        }

        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)

        DispatchQueue.global(qos: .userInitiated).async {
            self.acceptLoop()
        }
    }

    deinit {
        stop()
    }

    /// Closes the listening socket, which ends the accept loop. In-flight
    /// connections finish on their own. Safe to call more than once.
    func stop() {
        lock.lock()
        let wasRunning = !isStopped
        isStopped = true
        lock.unlock()
        if wasRunning {
            close(listenFD)
        }
    }

    private var stopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                // stop() closed the socket, or the accept failed for good.
                if stopped || errno != EINTR { return }
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.respond(to: client)
            }
        }
    }

    /// Drains the request head, then writes a fixed `204 No Content`.
    private static func respond(to fd: Int32) {
        defer { close(fd) }

        // A half-open peer must not wedge the thread for the whole test run.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var head = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while head.count < 8192 {
            let got = chunk.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return read(fd, base, buffer.count)
            }
            if got <= 0 { break }
            head.append(contentsOf: chunk[0..<got])
            if headIsComplete(head) { break }
        }

        let response = Array("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        var sent = 0
        while sent < response.count {
            let wrote = response.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base + sent, buffer.count - sent)
            }
            if wrote <= 0 { break }
            sent += wrote
        }
    }

    /// True once `bytes` contains the CRLFCRLF head terminator.
    private static func headIsComplete(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return true
            }
        }
        return false
    }
}
