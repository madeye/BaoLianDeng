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
import Network
import NetworkExtension
import os

// MARK: - UDP Helpers

/// Check if an IP address is broadcast or multicast (defense-in-depth).
func isBroadcastOrMulticast(_ hostname: String) -> Bool {
    if hostname == "255.255.255.255" { return true }
    // Multicast: 224.0.0.0/4 (first octet 224–239)
    if let dot = hostname.firstIndex(of: "."),
       let first = UInt8(hostname[hostname.startIndex..<dot]),
       first >= 224 && first <= 239 {
        return true
    }
    return false
}

// MARK: - UDP NAT Relay (NAT2, Address-Restricted Cone)

/// Relays non-DNS UDP traffic directly to the internet via a POSIX UDP socket.
/// One socket per flow, bound to a single local port (NAT2 behavior).
/// Only accepts responses from IPs we've previously sent to (address restriction).
final class UDPNATRelay {
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private let sentAddresses = NSMutableSet()  // Thread-safe via lock
    private let lock = NSLock()
    private var closed = false  // guarded by `lock`; ensures fd is closed exactly once
    private weak var flow: NEAppProxyUDPFlow?

    init?(flow: NEAppProxyUDPFlow) {
        self.flow = flow

        // Create UDP socket
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            AppLogger.tunnel.error("UDPNATRelay: socket() failed: \(errno)")
            return nil
        }
        self.fd = sock

        // Bind to 0.0.0.0:0 (OS assigns port)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            AppLogger.tunnel.error("UDPNATRelay: bind() failed: \(errno)")
            close(sock)
            return nil
        }

        // Set non-blocking
        let flags = fcntl(sock, F_GETFL)
        fcntl(sock, F_SETFL, flags | O_NONBLOCK)
    }

    /// Send a datagram to the destination and record the IP for NAT2 filtering.
    func send(datagram: Data, toHost host: String, port: UInt16) {
        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian

        // Validate IPv4 address — drop non-IPv4 (e.g. IPv6) silently
        guard inet_pton(AF_INET, host, &destAddr.sin_addr) == 1 else { return }

        lock.lock()
        sentAddresses.add(host)
        lock.unlock()

        datagram.withUnsafeBytes { buf in
            withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    let sent = sendto(fd, buf.baseAddress, buf.count, 0,
                                      sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    if sent < 0 {
                        AppLogger.tunnel.error(
                            "UDPNATRelay: sendto failed: \(errno)"
                        )
                    }
                }
            }
        }
    }

    /// Start the GCD read source to receive incoming datagrams and write them back to the flow.
    func startReceiving() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            self?.receiveDatagrams()
        }
        source.setCancelHandler { [fd = self.fd] in
            Darwin.close(fd)
        }
        source.resume()
        // Publish under the lock so `cancel()` (which reads `readSource` under
        // the same lock) sees a consistent value. The relay's lifecycle is
        // single-Task — every `startReceiving()` completes before `cancel()`
        // runs — so `closed` can't already be set here; the lock is purely for
        // memory-visibility consistency with the teardown path.
        lock.lock()
        readSource = source
        lock.unlock()
    }

    private func receiveDatagrams() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var srcAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }
            guard n > 0 else { break }

            // Extract source IP
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = srcAddr.sin_addr
            inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let sourceIP = String(cString: ipBuf)
            let sourcePort = UInt16(bigEndian: srcAddr.sin_port)

            // NAT2: only accept from IPs we've sent to
            lock.lock()
            let allowed = sentAddresses.contains(sourceIP)
            lock.unlock()
            guard allowed else { continue }

            let data = Data(bytes: buf, count: n)
            let endpoint = NWHostEndpoint(
                hostname: sourceIP, port: "\(sourcePort)"
            )

            flow?.writeDatagrams([data], sentBy: [endpoint]) { error in
                if let error = error {
                    AppLogger.tunnel.error(
                        "UDPNATRelay write error: \(error, privacy: .public)"
                    )
                }
            }
        }
    }

    func cancel() {
        // Close the fd exactly once. `cancel()` is reachable both from the
        // provider's explicit teardown and from `deinit`; without this guard
        // the fd would be closed twice. By the time the second close runs the
        // kernel has often handed fd 26 (etc.) to a *guarded* descriptor opened
        // by Network.framework/dispatch, so the stray close trips EXC_GUARD
        // (GUARD_TYPE_FD / CLOSE) and the extension is killed.
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let source = readSource
        readSource = nil
        lock.unlock()

        if let source = source {
            source.cancel()  // fd closed in cancel handler
        } else {
            Darwin.close(fd)  // No read source — close fd directly
        }
    }

    deinit {
        cancel()
    }
}
