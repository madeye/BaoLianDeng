// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
@preconcurrency import Network

/// Errors thrown by the shared SOCKS5 / NWConnection helpers.
enum SOCKS5Error: LocalizedError {
    case connectionCancelled
    case unexpectedEOF
    case socks5AuthFailed
    case socks5ConnectFailed
    case invalidDestinationHost

    var errorDescription: String? {
        switch self {
        case .connectionCancelled: return "Connection was cancelled"
        case .unexpectedEOF:       return "Unexpected end of data"
        case .socks5AuthFailed:    return "SOCKS5 authentication failed"
        case .socks5ConnectFailed: return "SOCKS5 CONNECT failed"
        case .invalidDestinationHost: return "Invalid SOCKS5 destination host"
        }
    }
}

/// Shared NWConnection + SOCKS5 primitives used by both the TCP relay path
/// and the TCP-DNS client. Kept as free-standing functions so callers can
/// reuse them without depending on TransparentProxyProvider.
enum SOCKS5Client {

    // MARK: - NWConnection helpers

    static func connectTCP(host: String, port: UInt16) async throws -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let connection = NWConnection(to: endpoint, using: .tcp)

        return try await withCheckedThrowingContinuation { cont in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume(returning: connection)
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: SOCKS5Error.connectionCancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    static func sendAll(connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
        }
    }

    static func readExact(connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, data.count >= count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: SOCKS5Error.unexpectedEOF)
                }
            }
        }
    }

    static func readSome(connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            readSomeLoop(connection: connection, cont: cont)
        }
    }

    /// Callback body for `readSome`, split out so the "no data yet" case can
    /// re-arm the receive instead of resolving the continuation (#75). Only
    /// `isComplete` (remote closed) or an error end the stream; callers such
    /// as `relayTCP` treat an empty `Data()` result as "connection closed,"
    /// so returning empty for a healthy connection with nothing to deliver
    /// yet would end the relay prematurely.
    private static func readSomeLoop(
        connection: NWConnection,
        cont: CheckedContinuation<Data, Error>
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { data, _, isComplete, error in
            if let error = error {
                cont.resume(throwing: error)
            } else if let data = data, !data.isEmpty {
                cont.resume(returning: data)
            } else if isComplete {
                // Genuine remote close / end-of-stream.
                cont.resume(returning: Data())
            } else {
                // No data, no error, not complete. `receive` with
                // minimumIncompleteLength: 1 shouldn't invoke the callback in
                // this shape, but if it ever does, keep waiting rather than
                // reporting a false end-of-stream.
                readSomeLoop(connection: connection, cont: cont)
            }
        }
    }

    // MARK: - SOCKS5 handshake (RFC 1928)

    /// Perform SOCKS5 handshake — supports IPv4, IPv6, and domain CONNECT.
    static func handshake(
        connection: NWConnection,
        destHost: String,
        destPort: UInt16
    ) async throws {
        // Step 1: Greeting — no auth
        let greeting = Data([0x05, 0x01, 0x00])
        try await sendAll(connection: connection, data: greeting)

        let authResp = try await readExact(connection: connection, count: 2)
        guard authResp[0] == 0x05, authResp[1] == 0x00 else {
            throw SOCKS5Error.socks5AuthFailed
        }

        try await sendAll(
            connection: connection,
            data: try makeConnectRequest(destHost: destHost, destPort: destPort)
        )

        // Read response: version, status, rsv, atyp
        let connResp = try await readExact(connection: connection, count: 4)
        guard connResp[0] == 0x05, connResp[1] == 0x00 else {
            throw SOCKS5Error.socks5ConnectFailed
        }

        // Skip bound address
        switch connResp[3] {
        case 0x01:  // IPv4
            _ = try await readExact(connection: connection, count: 4 + 2)
        case 0x03:  // Domain
            let lenData = try await readExact(connection: connection, count: 1)
            _ = try await readExact(
                connection: connection, count: Int(lenData[0]) + 2
            )
        case 0x04:  // IPv6
            _ = try await readExact(connection: connection, count: 16 + 2)
        default:
            break
        }
    }

    static func makeConnectRequest(destHost: String, destPort: UInt16) throws -> Data {
        var request = Data([0x05, 0x01, 0x00])

        if IPv4Address(destHost) != nil {
            request.append(0x01)
            let parts = destHost.split(separator: ".").compactMap { UInt8($0) }
            guard parts.count == 4 else {
                throw SOCKS5Error.invalidDestinationHost
            }
            request.append(contentsOf: parts)
        } else if let ipv6 = IPv6Address(destHost) {
            request.append(0x04)
            // `rawValue` is already the 16-byte network-order address. Using
            // `withUnsafeBytes(of: ipv6.rawValue)` would instead reflect the
            // `Data` struct's own memory layout (a pointer-sized header that
            // merely happens to be 16 bytes on 64-bit), shipping a garbage
            // destination that looks structurally valid.
            request.append(ipv6.rawValue)
        } else {
            let domainBytes = Array(destHost.utf8)
            guard !domainBytes.isEmpty, domainBytes.count <= 255 else {
                throw SOCKS5Error.invalidDestinationHost
            }
            request.append(0x03)
            request.append(UInt8(domainBytes.count))
            request.append(contentsOf: domainBytes)
        }

        request.append(UInt8(destPort >> 8))
        request.append(UInt8(destPort & 0xFF))
        return request
    }
}
