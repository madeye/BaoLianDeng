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

/// Relays non-DNS UDP traffic directly to the internet via POSIX UDP sockets.
/// Dual-stack: one AF_INET socket and one AF_INET6 socket per flow, each bound
/// to a single local port (NAT2 behavior per family).
/// Only accepts responses from IPs we've previously sent to (address restriction).
final class UDPNATRelay {
    private let fd: Int32
    private let fd6: Int32?
    private var readSource: DispatchSourceRead?
    private var readSource6: DispatchSourceRead?
    private let sentAddresses = NSMutableSet()  // Thread-safe via lock
    private static let maxTrackedAddresses = 1024
    private let lock = NSLock()
    private var closed = false  // guarded by `lock`; ensures fds are closed exactly once
    private weak var flow: NEAppProxyUDPFlow?

    init?(flow: NEAppProxyUDPFlow) {
        self.flow = flow

        // Create UDP socket (IPv4)
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

        // Create a second, IPv6-only UDP socket (#73). A single AF_INET
        // socket can only send/receive IPv4 datagrams, so any destination
        // that resolves to an IPv6 address was being silently dropped in
        // `send(datagram:toHost:port:)`. Failure to create/bind this socket
        // is non-fatal — IPv4 relaying still works — but IPv6 destinations
        // will then be dropped with a logged reason instead of silently.
        var fd6Local: Int32?
        let sock6 = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        if sock6 >= 0 {
            var on: Int32 = 1
            setsockopt(sock6, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = 0
            addr6.sin6_addr = in6addr_any
            let bind6Result = withUnsafePointer(to: &addr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.bind(sock6, sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bind6Result < 0 {
                AppLogger.tunnel.error(
                    "UDPNATRelay: IPv6 bind() failed: \(errno); IPv6 destinations will be dropped"
                )
                close(sock6)
            } else {
                let flags6 = fcntl(sock6, F_GETFL)
                fcntl(sock6, F_SETFL, flags6 | O_NONBLOCK)
                fd6Local = sock6
            }
        } else {
            AppLogger.tunnel.error(
                "UDPNATRelay: IPv6 socket() failed: \(errno); IPv6 destinations will be dropped"
            )
        }
        self.fd6 = fd6Local
    }

    /// Send a datagram to the destination and record the IP for NAT2 filtering.
    /// Supports both IPv4 and IPv6 destinations (#73); falls back to a logged
    /// drop if `host` isn't a parsable IP literal or the IPv6 socket is
    /// unavailable.
    func send(datagram: Data, toHost host: String, port: UInt16) {
        var destAddr4 = sockaddr_in()
        destAddr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr4.sin_family = sa_family_t(AF_INET)
        destAddr4.sin_port = port.bigEndian

        if inet_pton(AF_INET, host, &destAddr4.sin_addr) == 1 {
            recordSentAddress(host)
            datagram.withUnsafeBytes { buf in
                withUnsafePointer(to: &destAddr4) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        let sent = sendto(fd, buf.baseAddress, buf.count, 0,
                                          sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        if sent < 0 {
                            AppLogger.tunnel.error(
                                "UDPNATRelay: sendto (v4) failed: \(errno)"
                            )
                        }
                    }
                }
            }
            return
        }

        var destAddr6 = sockaddr_in6()
        destAddr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destAddr6.sin6_family = sa_family_t(AF_INET6)
        destAddr6.sin6_port = port.bigEndian

        guard inet_pton(AF_INET6, host, &destAddr6.sin6_addr) == 1 else {
            AppLogger.tunnel.error(
                "UDPNATRelay: dropping datagram to unparsable destination \(host, privacy: .public)"
            )
            return
        }

        guard let fd6 = fd6 else {
            AppLogger.tunnel.error(
                "UDPNATRelay: dropping IPv6 destination \(host, privacy: .public) — no IPv6 socket available"
            )
            return
        }

        recordSentAddress(host)
        datagram.withUnsafeBytes { buf in
            withUnsafePointer(to: &destAddr6) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    let sent = sendto(fd6, buf.baseAddress, buf.count, 0,
                                      sockPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    if sent < 0 {
                        AppLogger.tunnel.error(
                            "UDPNATRelay: sendto (v6) failed: \(errno)"
                        )
                    }
                }
            }
        }
    }

    /// Record a destination for NAT2 address-restriction filtering, capped
    /// (#75) so a flow that talks to many distinct peers can't grow this set
    /// unbounded for the life of the flow. Once the cap is hit, further new
    /// peers simply won't pass the inbound filter — acceptable versus
    /// unbounded memory growth for what should be a rare, chatty-flow case.
    private func recordSentAddress(_ host: String) {
        lock.lock()
        if sentAddresses.count < Self.maxTrackedAddresses {
            sentAddresses.add(host)
        }
        lock.unlock()
    }

    /// Start the GCD read sources (IPv4 and, if available, IPv6) to receive
    /// incoming datagrams and write them back to the flow.
    func startReceiving() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            self?.receiveDatagramsV4()
        }
        source.setCancelHandler { [fd = self.fd] in
            Darwin.close(fd)
        }
        source.resume()

        var source6: DispatchSourceRead?
        if let fd6 = fd6 {
            let s6 = DispatchSource.makeReadSource(
                fileDescriptor: fd6, queue: .global(qos: .userInitiated)
            )
            s6.setEventHandler { [weak self] in
                self?.receiveDatagramsV6()
            }
            s6.setCancelHandler {
                Darwin.close(fd6)
            }
            s6.resume()
            source6 = s6
        }

        // Publish under the lock so `cancel()` (which reads `readSource`/
        // `readSource6` under the same lock) sees a consistent value. The
        // relay's lifecycle is single-Task — every `startReceiving()`
        // completes before `cancel()` runs — so `closed` can't already be
        // set here; the lock is purely for memory-visibility consistency
        // with the teardown path.
        lock.lock()
        readSource = source
        readSource6 = source6
        lock.unlock()
    }

    private func receiveDatagramsV4() {
        var buf = [UInt8](repeating: 0, count: 65536)
        var srcAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }

            if n < 0 {
                let err = errno
                if err == EINTR {
                    continue  // interrupted syscall — retry immediately
                }
                if err != EAGAIN && err != EWOULDBLOCK {
                    // A real socket error: log it and tear the relay down —
                    // the socket is unlikely to recover, and looping here
                    // would just spin re-logging the same failure (#73).
                    AppLogger.tunnel.error("UDPNATRelay: recvfrom (v4) failed: \(err)")
                    cancel()
                }
                break  // EAGAIN/EWOULDBLOCK: no more datagrams available right now
            }
            if n == 0 { break }  // zero-length datagram: treat as end of burst, as before

            // Extract source IP
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = srcAddr.sin_addr
            inet_ntop(AF_INET, &addrCopy, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let sourceIP = String(cString: ipBuf)
            let sourcePort = UInt16(bigEndian: srcAddr.sin_port)

            deliverIfAllowed(data: Data(bytes: buf, count: n), sourceIP: sourceIP, sourcePort: sourcePort)
        }
    }

    private func receiveDatagramsV6() {
        guard let fd6 = fd6 else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        var srcAddr = sockaddr_in6()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in6>.size)

        while true {
            let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd6, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }

            if n < 0 {
                let err = errno
                if err == EINTR {
                    continue  // interrupted syscall — retry immediately
                }
                if err != EAGAIN && err != EWOULDBLOCK {
                    AppLogger.tunnel.error("UDPNATRelay: recvfrom (v6) failed: \(err)")
                    cancel()
                }
                break
            }
            if n == 0 { break }

            var ipBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var addrCopy = srcAddr.sin6_addr
            inet_ntop(AF_INET6, &addrCopy, &ipBuf, socklen_t(INET6_ADDRSTRLEN))
            let sourceIP = String(cString: ipBuf)
            let sourcePort = UInt16(bigEndian: srcAddr.sin6_port)

            deliverIfAllowed(data: Data(bytes: buf, count: n), sourceIP: sourceIP, sourcePort: sourcePort)
        }
    }

    private func deliverIfAllowed(data: Data, sourceIP: String, sourcePort: UInt16) {
        // NAT2: only accept from IPs we've sent to
        lock.lock()
        let allowed = sentAddresses.contains(sourceIP)
        lock.unlock()
        guard allowed else { return }

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

    func cancel() {
        // Close each fd exactly once. `cancel()` is reachable from the
        // provider's explicit teardown, from `deinit`, and now also from a
        // terminal recvfrom() error; without this guard the fds could be
        // closed twice. By the time a second close runs the kernel has often
        // handed the fd to a *guarded* descriptor opened by Network.framework
        // /dispatch, so the stray close trips EXC_GUARD (GUARD_TYPE_FD /
        // CLOSE) and the extension is killed.
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let source = readSource
        let source6 = readSource6
        readSource = nil
        readSource6 = nil
        lock.unlock()

        if let source = source {
            source.cancel()  // fd closed in cancel handler
        } else {
            Darwin.close(fd)  // No read source — close fd directly
        }

        if let source6 = source6 {
            source6.cancel()  // fd6 closed in cancel handler
        } else if let fd6 = fd6 {
            Darwin.close(fd6)  // No read source — close fd6 directly
        }
    }

    deinit {
        cancel()
    }
}
