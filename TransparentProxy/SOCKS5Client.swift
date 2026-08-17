// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
@preconcurrency import Network

/// Errors thrown by the shared SOCKS5 / NWConnection helpers.
enum SOCKS5Error: LocalizedError, Equatable {
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
        let gate = OnceResume<Result<NWConnection, Error>>()

        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<NWConnection, Error>, Never>) in
                gate.arm(cont)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        gate.resume(.success(connection))
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        gate.resume(.failure(error))
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        gate.resume(.failure(SOCKS5Error.connectionCancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
            return try result.get()
        } onCancel: {
            connection.cancel()
            gate.resume(.failure(SOCKS5Error.connectionCancelled))
        }
    }

    static func sendAll(connection: NWConnection, data: Data) async throws {
        try await withCancellableResult(Void.self) { resume in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error = error {
                        resume(.failure(error))
                    } else {
                        resume(.success(()))
                    }
                })
        }
    }

    static func readExact(connection: NWConnection, count: Int) async throws -> Data {
        try await withCancellableResult(Data.self) { resume in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, _, error in
                if let error = error {
                    resume(.failure(error))
                } else if let data = data, data.count >= count {
                    resume(.success(data))
                } else {
                    resume(.failure(SOCKS5Error.unexpectedEOF))
                }
            }
        }
    }

    static func readSome(connection: NWConnection) async throws -> Data {
        let gate = OnceResume<Result<Data, Error>>()
        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<Data, Error>, Never>) in
                gate.arm(cont)
                readSomeLoop(connection: connection, gate: gate)
            }
            return try result.get()
        } onCancel: {
            connection.cancel()
            gate.resume(.failure(SOCKS5Error.connectionCancelled))
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
        gate: OnceResume<Result<Data, Error>>
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { data, _, isComplete, error in
            if let error = error {
                gate.resume(.failure(error))
            } else if let data = data, !data.isEmpty {
                gate.resume(.success(data))
            } else if isComplete {
                // Genuine remote close / end-of-stream.
                gate.resume(.success(Data()))
            } else {
                // No data, no error, not complete. `receive` with
                // minimumIncompleteLength: 1 shouldn't invoke the callback in
                // this shape, but if it ever does, keep waiting rather than
                // reporting a false end-of-stream.
                readSomeLoop(connection: connection, gate: gate)
            }
        }
    }

    /// Bridge a Network.framework / NE callback to async, resuming exactly
    /// once. Task cancellation force-resumes with `connectionCancelled` so a
    /// callback that never fires (common after `NWConnection.cancel()` or
    /// `NEAppProxyFlow.close*`) cannot pin the caller forever.
    static func withCancellableResult<T: Sendable>(
        _: T.Type = T.self,
        _ body: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let gate = OnceResume<Result<T, Error>>()
        return try await withTaskCancellationHandler {
            let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>, Never>) in
                gate.arm(cont)
                body { gate.resume($0) }
            }
            return try result.get()
        } onCancel: {
            gate.resume(.failure(SOCKS5Error.connectionCancelled))
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

// MARK: - One-shot resume gate

/// Resumes a continuation exactly once. `arm` and `resume` may race:
/// `withTaskCancellationHandler.onCancel` can fire before the continuation
/// exists, and an NE / Network.framework callback can fire after cancel.
///
/// First `resume` wins. A `resume` that arrives before `arm` is parked and
/// delivered when `arm` runs, so the waiter cannot hang either way.
final class OnceResume<T>: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T, Never>)
        case pending(T)
        case done
    }

    private let lock = NSLock()
    private var state: State = .idle

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        switch state {
        case .pending(let value):
            state = .done
            lock.unlock()
            continuation.resume(returning: value)
        case .idle:
            state = .waiting(continuation)
            lock.unlock()
        case .waiting, .done:
            lock.unlock()
        }
    }

    func resume(_ value: T) {
        lock.lock()
        switch state {
        case .waiting(let continuation):
            state = .done
            lock.unlock()
            continuation.resume(returning: value)
        case .idle:
            state = .pending(value)
            lock.unlock()
        case .pending, .done:
            lock.unlock()
        }
    }
}
