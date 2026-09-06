// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
@preconcurrency import Network
@preconcurrency import NetworkExtension

// MARK: - Endpoint abstraction

/// What one relay direction read from its source.
enum TCPRelayRead: Sendable, Equatable {
    case data(Data)
    /// The peer closed its write side (orderly half-close). The stream in the
    /// other direction may still carry data.
    case eof
}

/// One side of a TCP relay — the app-side `NEAppProxyTCPFlow` or the
/// proxy-side `NWConnection` in production, in-memory fakes in tests.
///
/// `read` returns `.eof` only for an orderly end of stream; errors and task
/// cancellation are thrown so `TCPRelay` can tell "the peer is done sending"
/// apart from "this direction is broken".
protocol TCPRelayEndpoint: Sendable {
    func read() async throws -> TCPRelayRead
    func write(_ data: Data) async throws
    /// Propagate the opposite peer's half-close: send a FIN / close the
    /// write side while leaving the read side open.
    func finishWriting() async throws
}

// MARK: - Outcome

enum TCPRelayOutcome: Sendable, Equatable {
    /// Both directions reached EOF and each was propagated to the other side.
    case completed
    /// A direction failed (I/O error or cancellation); the relay stopped and
    /// the caller must tear both endpoints down.
    case failed
    /// After one direction half-closed, the remaining one carried no data for
    /// `halfCloseIdleTimeout`. Guards against a peer that never closes.
    case halfCloseTimedOut
}

// MARK: - Relay

/// Bidirectional TCP relay with proper half-close semantics.
///
/// EOF from one side finishes only that direction: the FIN is forwarded to
/// the other endpoint (`finishWriting`) and the opposite direction keeps
/// running until it hits EOF too. A client that does `shutdown(SHUT_WR)`
/// after its request therefore still receives the response, and a server
/// that closes its write side first still receives the rest of the upload.
///
/// Errors and cancellation stop the relay immediately. The caller owns
/// endpoint teardown — closing/cancelling both endpoints after `run`
/// returns force-resumes any callback that never fires (see
/// `SOCKS5Client.withCancellableResult`), so the pre-existing leak guard for
/// abandoned NE / Network.framework callbacks still applies.
enum TCPRelay {
    /// Default idle bound for the direction left open after a half-close.
    /// Long enough for a slow server to answer a half-closed request, short
    /// enough that a peer which never closes cannot pin a flow for the life
    /// of the extension.
    static let defaultHalfCloseIdleTimeout: TimeInterval = 120

    private enum DirectionOutcome: Sendable {
        case finished
        case failed
        case timedOut
    }

    static func run(
        app: some TCPRelayEndpoint,
        proxy: some TCPRelayEndpoint,
        halfCloseIdleTimeout: TimeInterval = defaultHalfCloseIdleTimeout
    ) async -> TCPRelayOutcome {
        let activity = ActivityClock()
        return await withTaskGroup(of: DirectionOutcome.self) { group in
            group.addTask { await pump(from: app, to: proxy, activity: activity) }
            group.addTask { await pump(from: proxy, to: app, activity: activity) }

            guard let first = await group.next(), first == .finished else {
                group.cancelAll()
                await group.waitForAll()
                return .failed
            }

            // Half-closed: let the sibling finish, but bound its idle time.
            group.addTask {
                await idleWatchdog(activity: activity, timeout: halfCloseIdleTimeout)
            }
            let second = await group.next()
            group.cancelAll()
            await group.waitForAll()

            switch second {
            case .finished: return .completed
            case .timedOut: return .halfCloseTimedOut
            case .failed, .none: return .failed
            }
        }
    }

    private static func pump(
        from source: some TCPRelayEndpoint,
        to sink: some TCPRelayEndpoint,
        activity: ActivityClock
    ) async -> DirectionOutcome {
        while !Task.isCancelled {
            do {
                switch try await source.read() {
                case .data(let data):
                    activity.touch()
                    try await sink.write(data)
                case .eof:
                    activity.touch()
                    try await sink.finishWriting()
                    return .finished
                }
            } catch {
                return .failed
            }
        }
        return .failed
    }

    private static func idleWatchdog(
        activity: ActivityClock, timeout: TimeInterval
    ) async -> DirectionOutcome {
        while !Task.isCancelled {
            let remaining = timeout - activity.idleInterval
            if remaining <= 0 { return .timedOut }
            do {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            } catch {
                return .failed
            }
        }
        return .failed
    }
}

/// Last-activity timestamp shared by the two pump tasks and the watchdog.
private final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    var idleInterval: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

// MARK: - Production endpoints

/// App side of the relay: `NEAppProxyTCPFlow`.
///
/// `readData`/`write` belong to the same flow family as `NEAppProxyFlow.open`:
/// the completion can fire more than once during teardown races, or never at
/// all after `closeRead`/`closeWrite`. `SOCKS5Client.withCancellableResult`
/// resumes exactly once and force-resumes on task cancellation, so a waiter
/// cannot pin the flow forever (this is how finished relays once leaked ~11k
/// flows).
struct FlowRelayEndpoint: TCPRelayEndpoint {
    let flow: NEAppProxyTCPFlow

    func read() async throws -> TCPRelayRead {
        try await SOCKS5Client.withCancellableResult(TCPRelayRead.self) { resume in
            flow.readData { data, error in
                if let error = error {
                    resume(.failure(error))
                } else if let data = data, !data.isEmpty {
                    resume(.success(.data(data)))
                } else {
                    // Empty data with no error: the app closed its write side.
                    resume(.success(.eof))
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await SOCKS5Client.withCancellableResult(Void.self) { resume in
            flow.write(data) { error in
                if let error = error {
                    resume(.failure(error))
                } else {
                    resume(.success(()))
                }
            }
        }
    }

    /// Half-close towards the app; the app can keep sending.
    func finishWriting() async throws {
        flow.closeWriteWithError(nil)
    }
}

/// Proxy side of the relay: the SOCKS5 `NWConnection` to mihomo.
///
/// A class rather than a struct because Network.framework reports the peer's
/// FIN only once, possibly on the same callback as the final bytes; that
/// trailing EOF is remembered here and handed out on the next `read`.
final class NWConnectionRelayEndpoint: TCPRelayEndpoint, @unchecked Sendable {
    let connection: NWConnection
    private let lock = NSLock()
    private var pendingEOF = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func read() async throws -> TCPRelayRead {
        if lock.withLock({ pendingEOF }) { return .eof }

        let chunk = try await SOCKS5Client.readSome(connection: connection)
        if chunk.data.isEmpty { return .eof }
        if chunk.isComplete {
            lock.withLock { pendingEOF = true }
        }
        return .data(chunk.data)
    }

    func write(_ data: Data) async throws {
        try await SOCKS5Client.sendAll(connection: connection, data: data)
    }

    /// TCP half-close (FIN) on the SOCKS5 connection; receives keep working.
    func finishWriting() async throws {
        try await SOCKS5Client.withCancellableResult(Void.self) { resume in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error = error {
                        resume(.failure(error))
                    } else {
                        resume(.success(()))
                    }
                })
        }
    }
}
