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

@preconcurrency import NetworkExtension
import MihomoCore
import Network
import os
import Yams

// MARK: - Transparent Proxy Provider

class TransparentProxyProvider: NETransparentProxyProvider {
    private var proxyStarted = false
    private var gcTimer: DispatchSourceTimer?
    private var diagnosticTimer: DispatchSourceTimer?
    private var logTrimTimer: DispatchSourceTimer?
    private var perAppSettings: PerAppProxySettings?
    private var perAppBundleIDSet: Set<String> = []

    private static let socksHost = "127.0.0.1"
    private static let mihomoDNSHost = "127.0.0.1"

    /// Dedicated queue for the blocking POSIX socket round-trip in
    /// `sendDNSToMihomo`. Swift's cooperative thread pool assumes tasks never
    /// block a thread; running a blocking `recv()` there can starve other
    /// async work, so it's dispatched here instead.
    private let dnsQueue = DispatchQueue(
        label: "io.github.baoliandeng.dns", attributes: .concurrent
    )

    /// Serializes all access to the tunnel log file (and its trimming) so
    /// concurrent `log()` calls from many Tasks and the periodic trim timer
    /// never interleave their exists-check/open/seek/write/close sequences.
    private let logQueue = DispatchQueue(label: "io.github.baoliandeng.log")

    /// Ports the main app picked for this tunnel session, forwarded via
    /// providerConfiguration in setupConfigFromProvider(). Mihomo binds
    /// these in startProxy(). Defaulting to 0 / "" makes a stray flow
    /// arriving before startup completes fail fast.
    private var socksPort: UInt16 = 0
    private var mihomoDNSPort: UInt16 = 0
    private var controllerAddr: String = ""
    private var controllerSecret: String = ""

    private lazy var logURL: URL = {
        let dir = ConfigManager.shared.configDirectoryURL?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tunnel.log")
    }()

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        AppLogger.tunnel.notice("\(message, privacy: .public)")
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        logQueue.async {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    // MARK: - Geodata Setup

    private func ensureGeodataFiles(configDir: String) {
        ConfigManager.shared.ensureGeodataFiles(configDir: configDir)
    }

    // MARK: - Proxy Lifecycle

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        try? FileManager.default.removeItem(at: logURL)
        log("startProxy called (NETransparentProxyProvider)")

        let configDir = setupConfigFromProvider()
        log("configDir: \(configDir)")

        let configPath = configDir + "/config.yaml"
        guard FileManager.default.fileExists(atPath: configPath) else {
            log("ERROR: config.yaml not found at \(configPath)")
            completionHandler(ProviderError.configNotFound)
            return
        }

        ConfigManager.shared.sanitizeConfig()
        log("Config sanitized")

        // Pre-resolve proxy server hostnames while DNS still works
        let resolvedIPs = preResolveProxyServers(configPath: configPath)
        log("Pre-resolved \(resolvedIPs.count) proxy server IP(s)")

        if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8) {
            log("config.yaml preview: \(String(cfg.prefix(300)))")
        }

        // Build transparent proxy network settings
        let settings = createProxySettings()
        log("Setting transparent proxy network settings")

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.log("ERROR: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }
            self?.log("setTunnelNetworkSettings succeeded")

            let rustLogPath = (configDir as NSString).deletingLastPathComponent
                + "/rust_bridge.log"
            BridgeSetLogFile(rustLogPath)

            // Ensure geodata files exist (bundled copy, then jsDelivr fallback)
            self?.ensureGeodataFiles(configDir: configDir)

            self?.log("Setting home dir: \(configDir)")
            BridgeSetHomeDir(configDir)

            // Use the ports the main app picked & forwarded via
            // providerConfiguration. setupConfigFromProvider() stashed
            // them on `self` already; default to 0 so a missing field
            // fails fast rather than silently binding 7890/1053.
            let socks = self?.socksPort ?? 0
            let dns = self?.mihomoDNSPort ?? 0
            let ctrl = self?.controllerAddr ?? ""
            let secret = self?.controllerSecret ?? ""
            guard socks > 0, dns > 0, !ctrl.isEmpty else {
                self?.log("ERROR: provider configuration missing ports/controllerAddr")
                completionHandler(ProviderError.configNotFound)
                return
            }
            self?.log(
                "Starting Mihomo proxy engine: socks=\(socks) dns=\(dns) controller=\(ctrl)"
            )
            var startError: NSError?
            BridgeStartWithPorts(
                Int32(socks), Int32(dns), ctrl, secret, &startError
            )
            if let startError = startError {
                self?.log("ERROR: BridgeStartWithPorts failed: \(startError)")
                completionHandler(startError)
                return
            }

            self?.proxyStarted = true
            self?.setupLogging()
            self?.startMemoryManagement()
            self?.startDiagnosticLogging()
            self?.startLogTrimming()
            completionHandler(nil)

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self?.log("TCP-TEST: HTTP via proxy...")
                let proxyResult = BridgeTestProxyHTTP("http://www.baidu.com/")
                self?.log("TCP-TEST proxy: \(proxyResult ?? "nil")")
            }
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        logTrimTimer?.cancel()
        logTrimTimer = nil
        stopMemoryManagement()
        if proxyStarted {
            BridgeStopProxy()
            proxyStarted = false
        }
        completionHandler()
    }

    // MARK: - Flow Handling

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Per-app filtering: return false to let bypassed flows connect directly
        if let settings = perAppSettings, settings.enabled {
            let appID = flow.metaData.sourceAppSigningIdentifier
            let shouldProxy = settings.shouldProxy(
                bundleID: appID, knownBundleIDs: perAppBundleIDSet
            )
            if !shouldProxy {
                log("BYPASS flow from \(appID)")
                return false
            }
        }

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            handleTCPFlow(tcpFlow)
            return true
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            handleUDPFlow(udpFlow)
            return true
        }
        return false
    }

    // MARK: - Flow open helper

    /// Open a proxy flow, bridging the completion-handler API to async.
    ///
    /// `NEAppProxy*Flow.open(withLocalEndpoint:)` can invoke its completion
    /// handler more than once during teardown races. A bare
    /// `withCheckedThrowingContinuation` would then call `cont.resume` twice and
    /// trap with "SWIFT TASK CONTINUATION MISUSE" (EXC_BREAKPOINT), killing the
    /// extension. The `resumed` flag (guarded by a lock, since the handler may
    /// fire on different threads) makes resumption happen exactly once.
    private func openFlow(_ flow: NEAppProxyFlow) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            flow.open(withLocalEndpoint: nil) { error in
                lock.lock()
                if resumed {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    // MARK: - TCP Flow (SOCKS5 relay)

    private func handleTCPFlow(_ flow: NEAppProxyTCPFlow) {
        guard let endpoint = flow.remoteEndpoint as? NWHostEndpoint else {
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            return
        }

        let destHost = endpoint.hostname
        let destPort = endpoint.port
        log("TCP \(destHost):\(destPort)")

        guard let destPortValue = UInt16(destPort) else {
            log("ERROR: malformed TCP destination port \(destPort)")
            flow.closeReadWithError(ProviderError.invalidDestination)
            flow.closeWriteWithError(ProviderError.invalidDestination)
            return
        }

        Task {
            // Open the flow first — if this fails there is nothing to close.
            do {
                try await openFlow(flow)
            } catch {
                return
            }

            var socksConn: NWConnection?
            do {
                // Connect to Mihomo's SOCKS5 proxy
                let conn = try await SOCKS5Client.connectTCP(
                    host: Self.socksHost, port: self.socksPort
                )
                socksConn = conn

                // SOCKS5 handshake — pass the raw destination IP; mihomo
                // recovers the domain via its DNS snooping reverse cache
                // (populated from the UDP DNS queries we forward to its
                // ephemeral DNS port).
                try await SOCKS5Client.handshake(
                    connection: conn,
                    destHost: destHost,
                    destPort: destPortValue
                )

                // Relay bidirectionally: flow ↔ SOCKS5 connection
                await relayTCP(flow: flow, connection: conn)

                // Ensure cleanup after normal relay completion
                conn.cancel()
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)

            } catch {
                socksConn?.cancel()
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
        }
    }

    // MARK: - UDP Flow (DNS interception)

    private func handleUDPFlow(_ flow: NEAppProxyUDPFlow) {
        Task {
            do {
                // Open the UDP flow
                try await openFlow(flow)

                // Create relay lazily — initialized on first non-DNS datagram
                var relay: UDPNATRelay?

                // Read datagrams and handle DNS + non-DNS UDP
                await handleUDPDatagrams(flow: flow, relay: &relay)

                // Clean up relay
                relay?.cancel()

                // Normal exit — close the flow
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)

            } catch {
                flow.closeReadWithError(error)
                flow.closeWriteWithError(error)
            }
        }
    }

    private func handleUDPDatagrams(
        flow: NEAppProxyUDPFlow, relay: inout UDPNATRelay?
    ) async {
        while true {
            var datagrams: [Data] = []
            var endpoints: [NWHostEndpoint] = []
            var readError: Error?

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Like `open`, `readDatagrams` can fire its completion handler
                // more than once during teardown races; the lock-guarded
                // `resumed` flag keeps `cont.resume` to exactly one call so we
                // don't trap with a continuation-misuse EXC_BREAKPOINT.
                let lock = NSLock()
                var resumed = false
                flow.readDatagrams { dgs, eps, err in
                    lock.lock()
                    if resumed {
                        lock.unlock()
                        return
                    }
                    resumed = true
                    lock.unlock()
                    datagrams = dgs ?? []
                    endpoints = (eps ?? []).compactMap {
                        $0 as? NWHostEndpoint
                    }
                    readError = err
                    cont.resume()
                }
            }

            if let readError = readError {
                log("UDP read error: \(readError)")
                break
            }

            if datagrams.isEmpty {
                break  // Flow closed
            }

            for (index, datagram) in datagrams.enumerated() {
                guard let endpoint = endpoints[safe: index] else {
                    continue
                }

                guard let port = UInt16(endpoint.port) else {
                    log("UDP: malformed destination port \(endpoint.port), dropping datagram")
                    continue
                }

                if port == 53 {
                    await handleDNSQuery(
                        query: datagram, flow: flow, endpoint: endpoint
                    )
                } else {
                    // Non-DNS UDP: relay directly (bypass mihomo)
                    guard !isBroadcastOrMulticast(endpoint.hostname) else {
                        continue
                    }

                    // Lazily create relay on first non-DNS datagram
                    if relay == nil {
                        relay = UDPNATRelay(flow: flow)
                        if let relay = relay {
                            relay.startReceiving()
                            log("UDP NAT relay created for non-DNS traffic")
                        } else {
                            log("ERROR: Failed to create UDP NAT relay")
                        }
                    }
                    relay?.send(
                        datagram: datagram,
                        toHost: endpoint.hostname,
                        port: port
                    )
                }
            }
        }
    }

    /// Forward a UDP DNS query directly to mihomo's DNS server on the
    /// ephemeral port stored in `mihomoDNSPort` and relay the response
    /// back to the app. Mihomo populates its own snooping cache from the
    /// query, and its SOCKS5 listener uses that cache to recover the
    /// domain when subsequent TCP flows arrive with only an IP.
    private func handleDNSQuery(
        query: Data, flow: NEAppProxyUDPFlow, endpoint: NWHostEndpoint
    ) async {
        guard query.count >= 12 else { return }
        let response = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            dnsQueue.async { [weak self] in
                cont.resume(returning: self?.sendDNSToMihomo(query: query))
            }
        }
        guard let response = response else {
            log("DNS forward failed")
            return
        }
        flow.writeDatagrams([response], sentBy: [endpoint]) { error in
            if let error = error {
                AppLogger.tunnel.error(
                    "DNS write error: \(error, privacy: .public)"
                )
            }
        }
    }

    /// Synchronous UDP round-trip to mihomo's DNS server on
    /// `127.0.0.1:<mihomoDNSPort>`. Loopback so per-query sockets are cheap.
    private func sendDNSToMihomo(query: Data) -> Data? {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(
            sock, SOL_SOCKET, SO_RCVTIMEO, &tv,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(self.mihomoDNSPort).bigEndian
        inet_pton(AF_INET, Self.mihomoDNSHost, &addr.sin_addr)

        let sent = query.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                    sendto(
                        sock, buf.baseAddress, buf.count, 0, saptr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sent == query.count else { return nil }

        var respBuf = [UInt8](repeating: 0, count: 65535)
        let n = recv(sock, &respBuf, respBuf.count, 0)
        guard n > 0 else { return nil }
        return Data(respBuf[0..<n])
    }

    // MARK: - TCP Relay

    private func relayTCP(flow: NEAppProxyTCPFlow, connection: NWConnection) async {
        await withTaskGroup(of: Void.self) { group in
            // Flow → SOCKS5
            group.addTask {
                while true {
                    let data: Data? = await withOneShotFlowContinuation { resume in
                        flow.readData(completionHandler: { data, error in
                            if error != nil || data == nil || data!.isEmpty {
                                resume(nil)
                            } else {
                                resume(data)
                            }
                        })
                    }
                    guard let data = data else { break }
                    do {
                        try await SOCKS5Client.sendAll(connection: connection, data: data)
                    } catch {
                        break
                    }
                }
                // Signal both sides so the other task can exit
                connection.cancel()
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
            }

            // SOCKS5 → Flow
            group.addTask {
                while true {
                    do {
                        let data = try await SOCKS5Client.readSome(connection: connection)
                        guard !data.isEmpty else { break }
                        let writeOK: Bool = await withOneShotFlowContinuation { resume in
                            flow.write(data) { error in
                                resume(error == nil)
                            }
                        }
                        if !writeOK { break }
                    } catch {
                        break
                    }
                }
                // Signal both sides so the other task can exit
                connection.cancel()
                flow.closeReadWithError(nil)
                flow.closeWriteWithError(nil)
            }
        }
    }

    // MARK: - IPC

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {
        guard let message = try? JSONSerialization.jsonObject(
            with: messageData
        ) as? [String: Any],
            let action = message["action"] as? String
        else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "get_traffic":
            let upload = BridgeGetUploadTraffic()
            let download = BridgeGetDownloadTraffic()
            completionHandler?(
                responseData(["upload": upload, "download": download])
            )

        case "get_version":
            let version = BridgeVersion()
            completionHandler?(
                responseData(["version": version ?? "unknown"])
            )

        case "get_log":
            var logContent =
                (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            let rustLogURL = logURL.deletingLastPathComponent()
                .appendingPathComponent("rust_bridge.log")
            if let rustLog = try? String(
                contentsOf: rustLogURL, encoding: .utf8
            ) {
                logContent += "\n--- Rust Bridge Log ---\n" + rustLog
            }
            // Keep only the last portion if the combined log is too large
            let maxResponseBytes = 256 * 1024
            if logContent.utf8.count > maxResponseBytes,
               let tail = String(logContent.utf8.suffix(maxResponseBytes)) {
                logContent = "… (truncated)\n" + tail
            }
            completionHandler?(logContent.data(using: .utf8))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Proxy Network Settings

    private func createProxySettings() -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )

        // Include all TCP and UDP outbound traffic.
        // Note: port 53 cannot be specified directly for transparent proxy rules
        // on macOS 15+. Instead we match all UDP and filter DNS in handleNewFlow().
        let tcpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .TCP,
            direction: .outbound
        )
        let udpRule = NENetworkRule(
            remoteNetwork: nil,
            remotePrefix: 0,
            localNetwork: nil,
            localPrefix: 0,
            protocol: .UDP,
            direction: .outbound
        )
        settings.includedNetworkRules = [tcpRule, udpRule]

        // Exclude localhost, LAN, and all reserved/private IP ranges
        var excluded: [NENetworkRule] = []
        let excludedRanges: [(String, Int)] = [
            // IPv4
            // NOTE: do NOT add a ("0.0.0.0", 8) rule. macOS treats hostname
            // "0.0.0.0" + port "0" as fully wildcard and rejects the entire
            // settings object with NETunnelProviderErrorDomain Code=1
            // "Either a non-wildcard port or a non-wildcard address must be
            // specified", which prevents the tunnel from starting.
            ("10.0.0.0", 8),      // Private (RFC 1918)
            ("100.64.0.0", 10),   // CGNAT (RFC 6598)
            ("127.0.0.0", 8),     // Loopback (RFC 1122)
            ("169.254.0.0", 16),  // Link-local (RFC 3927)
            ("172.16.0.0", 12),   // Private (RFC 1918)
            ("192.0.0.0", 24),    // IETF Protocol Assignments (RFC 6890)
            ("192.0.2.0", 24),    // Documentation TEST-NET-1 (RFC 5737)
            ("192.88.99.0", 24),  // 6to4 Relay Anycast (RFC 7526)
            ("192.168.0.0", 16),  // Private (RFC 1918)
            ("198.18.0.0", 15),   // Benchmarking (RFC 2544)
            ("198.51.100.0", 24), // Documentation TEST-NET-2 (RFC 5737)
            ("203.0.113.0", 24),  // Documentation TEST-NET-3 (RFC 5737)
            ("224.0.0.0", 4),     // Multicast (RFC 5771)
            ("240.0.0.0", 4),     // Reserved for future use (RFC 1112)
            ("255.255.255.255", 32), // Limited broadcast
            // IPv6
            ("::1", 128),         // Loopback
            ("fc00::", 7),        // Unique local address (RFC 4193)
            ("fe80::", 10),       // Link-local (RFC 4291)
            ("ff00::", 8),        // Multicast (RFC 4291)
        ]
        for (network, prefix) in excludedRanges {
            excluded.append(
                NENetworkRule(
                    remoteNetwork: NWHostEndpoint(
                        hostname: network, port: "0"
                    ),
                    remotePrefix: prefix,
                    localNetwork: nil,
                    localPrefix: 0,
                    protocol: .any,
                    direction: .outbound
                )
            )
        }
        settings.excludedNetworkRules = excluded

        return settings
    }

    // MARK: - Config from Provider

    private func setupConfigFromProvider() -> String {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        let providerConfig = proto?.providerConfiguration

        guard let configDirURL = ConfigManager.shared.configDirectoryURL else {
            log("ERROR: could not resolve config directory")
            return ""
        }
        let configDir = configDirURL.path
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true
        )

        let config: String
        if let compressed = providerConfig?["configData"] as? Data,
            let decompressed = try? (compressed as NSData).decompressed(
                using: .zlib
            ) as Data,
            let yaml = String(data: decompressed, encoding: .utf8) {
            config = yaml
            log(
                "Config from provider: \(compressed.count) -> \(decompressed.count) bytes"
            )
        } else {
            config = ConfigManager.shared.defaultConfig()
            log("No compressed config in provider, using default")
        }

        let configPath = configDir + "/config.yaml"
        try? config.write(
            toFile: configPath, atomically: true, encoding: .utf8
        )
        log("Config written to \(configPath) (\(config.count) chars)")

        // Load per-app proxy settings
        if let perAppData = providerConfig?["perAppProxy"] as? Data,
           let settings = try? JSONDecoder().decode(PerAppProxySettings.self, from: perAppData) {
            self.perAppSettings = settings
            self.perAppBundleIDSet = Set(settings.apps.map(\.bundleID))
            log("Per-app proxy: enabled=\(settings.enabled) mode=\(settings.mode.rawValue) apps=\(settings.apps.count)")
        }

        // Pull the listener ports the main app picked for this run.
        if let socks = providerConfig?["socksPort"] as? Int {
            self.socksPort = UInt16(socks)
        }
        if let dns = providerConfig?["dnsPort"] as? Int {
            self.mihomoDNSPort = UInt16(dns)
        }
        if let ctrl = providerConfig?["controllerAddr"] as? String {
            self.controllerAddr = ctrl
        }
        if let secret = providerConfig?["secret"] as? String {
            self.controllerSecret = secret
        }

        return configDir
    }

    // MARK: - Memory Management

    private func startMemoryManagement() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { BridgeForceGC() }
        timer.resume()
        gcTimer = timer
    }

    private func stopMemoryManagement() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    // MARK: - Helpers

    private func setupLogging() {
        let level = AppConstants.sharedDefaults
            .string(forKey: "logLevel") ?? "info"
        BridgeUpdateLogLevel(level)
    }

    private func startDiagnosticLogging() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            let upload = BridgeGetUploadTraffic()
            let download = BridgeGetDownloadTraffic()
            let running = BridgeIsRunning()
            self?.log(
                "DIAG: running=\(running) upload=\(upload) download=\(download)"
            )
        }
        timer.resume()
        diagnosticTimer = timer
    }

    /// Trim the log file every 10 minutes, keeping only lines from the last hour.
    private func startLogTrimming() {
        let timer = DispatchSource.makeTimerSource(
            queue: .global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 600, repeating: 600)
        timer.setEventHandler { [weak self] in
            self?.trimLogFile()
        }
        timer.resume()
        logTrimTimer = timer
    }

    private static let maxLogLines = 2000

    private func trimLogFile() {
        logQueue.sync {
            trimLog(at: logURL)
            let rustLogURL = logURL.deletingLastPathComponent()
                .appendingPathComponent("rust_bridge.log")
            trimLog(at: rustLogURL)
        }
    }

    /// Must only be called while running on `logQueue`.
    private func trimLog(at url: URL) {
        guard let content = try? String(
            contentsOf: url, encoding: .utf8
        ) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var lines = content.components(separatedBy: "\n")

        // Drop lines older than 1 hour
        if let firstKeptIndex = lines.firstIndex(where: { line in
            guard line.hasPrefix("["),
                  let end = line.firstIndex(of: "]")
            else { return false }
            let dateStr = String(
                line[line.index(after: line.startIndex)..<end]
            )
            guard let date = formatter.date(from: dateStr) else {
                return false
            }
            return date >= cutoff
        }) {
            lines = Array(lines[firstKeptIndex...])
        }

        // Cap at max line count, keeping the tail
        if lines.count > Self.maxLogLines {
            lines = Array(lines.suffix(Self.maxLogLines))
        }

        let trimmed = lines.joined(separator: "\n")
        if trimmed.count < content.count {
            try? trimmed.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func preResolveProxyServers(configPath: String) -> Set<String> {
        guard var yaml = try? String(
            contentsOfFile: configPath, encoding: .utf8
        ) else { return [] }

        guard let dict = (try? Yams.load(yaml: yaml)) as? [String: Any],
            let proxies = dict["proxies"] as? [[String: Any]]
        else { return [] }

        var hostToIP: [String: String] = [:]
        var allIPs = Set<String>()
        for proxy in proxies {
            guard let server = proxy["server"] as? String, !server.isEmpty
            else { continue }
            if server.contains(":") { continue }
            if IPv4Address(server) != nil {
                allIPs.insert(server)
                continue
            }
            if hostToIP[server] != nil { continue }

            if let resolvedIP = resolveHostnameToIPv4(server) {
                hostToIP[server] = resolvedIP
                allIPs.insert(resolvedIP)
                log("Resolved proxy server: \(server) -> \(resolvedIP)")
            }
        }

        if !hostToIP.isEmpty {
            yaml = ConfigManager.rewriteProxyServerHostnames(in: yaml, hostToIP: hostToIP)
            try? yaml.write(
                toFile: configPath, atomically: true, encoding: .utf8
            )
            log(
                "Config rewritten with \(hostToIP.count) resolved proxy server IP(s)"
            )
        }

        return allIPs
    }

    private func resolveHostnameToIPv4(_ hostname: String) -> String? {
        let hostRef = CFHostCreateWithName(nil, hostname as CFString)
            .takeRetainedValue()
        var resolved = DarwinBoolean(false)
        CFHostStartInfoResolution(hostRef, .addresses, nil)
        guard
            let addresses = CFHostGetAddressing(hostRef, &resolved)?
                .takeUnretainedValue() as? [Data]
        else { return nil }
        for addrData in addresses {
            guard addrData.count >= MemoryLayout<sockaddr_in>.size else {
                continue
            }
            var addr = sockaddr_in()
            _ = withUnsafeMutableBytes(of: &addr) {
                addrData.copyBytes(to: $0)
            }
            if addr.sin_family == UInt8(AF_INET) {
                return String(cString: inet_ntoa(addr.sin_addr))
            }
        }
        return nil
    }

    private func responseData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }
}

// MARK: - Array Safe Subscript

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Flow continuation helper

/// Bridge a flow completion-handler callback to async, resuming the
/// continuation exactly once even if the handler fires more than once during
/// teardown races.
///
/// `NEAppProxyTCPFlow.readData`/`write` belong to the same flow family as
/// `NEAppProxyFlow.open` (see `TransparentProxyProvider.openFlow`), whose
/// completion handler can fire multiple times during teardown. A bare
/// `withCheckedContinuation` would then call `cont.resume` twice and trap with
/// "SWIFT TASK CONTINUATION MISUSE" (EXC_BREAKPOINT), killing the extension.
/// The `resumed` flag (guarded by a lock, since the handler may fire on
/// different threads) makes resumption happen exactly once.
private func withOneShotFlowContinuation<T>(
    _ body: (@escaping (T) -> Void) -> Void
) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let lock = NSLock()
        var resumed = false
        body { value in
            lock.lock()
            if resumed {
                lock.unlock()
                return
            }
            resumed = true
            lock.unlock()
            cont.resume(returning: value)
        }
    }
}

// MARK: - Errors

enum ProviderError: LocalizedError {
    case configNotFound
    case udpRelayFailed
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "config.yaml not found. Please configure proxies first."
        case .udpRelayFailed:
            return "UDP relay socket creation failed"
        case .invalidDestination:
            return "Flow had a malformed destination port"
        }
    }
}
