// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Darwin
import Foundation
import Network
import XCTest
@testable import BaoLianDeng

/// Regression tests for madeye/BaoLianDeng#113 finding 6: the TCP relay used
/// to tear both directions down as soon as *either* hit EOF, so a client that
/// half-closed after its request (`shutdown(SHUT_WR)`) never saw the reply.
///
/// The relay core is exercised two ways: with an in-memory fake on both sides
/// (deterministic control of EOF ordering, errors, and the idle bound), and
/// with the production `NWConnectionRelayEndpoint` talking to a real loopback
/// TCP server, which proves the FIN is actually sent and that receives keep
/// working after it.
final class TCPRelayTests: XCTestCase {

    // MARK: - Request EOF, then response (the audit repro)

    /// Loopback server reads until EOF, then sends 5 bytes. A plain socket
    /// with `shutdown(SHUT_WR)` gets all 5; the old relay got 0.
    func testRequestEOFThenResponseIsDelivered() async throws {
        let server = try LoopbackServer()
        server.serve { srv, sock in
            _ = srv.readUntilEOF(sock)
            LoopbackServer.writeAll(sock, Data("reply".utf8))
        }
        defer { server.close() }

        let connection = try await SOCKS5Client.connectTCP(host: "127.0.0.1", port: server.port)
        defer { connection.cancel() }

        let app = FakeRelayEndpoint()
        app.push(.success(.data(Data("GET / HTTP/1.0\r\n\r\n".utf8))))
        app.push(.success(.eof))

        let outcome = await TCPRelay.run(
            app: app,
            proxy: NWConnectionRelayEndpoint(connection: connection),
            halfCloseIdleTimeout: 5
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.written, Data("reply".utf8))
        XCTAssertTrue(app.finishedWriting, "server EOF must be propagated to the app as a half-close")
        XCTAssertEqual(server.received, Data("GET / HTTP/1.0\r\n\r\n".utf8))
    }

    // MARK: - Reverse half-close: server closes write first, client keeps sending

    func testServerHalfCloseFirstClientKeepsSending() async throws {
        let server = try LoopbackServer()
        server.serve { srv, sock in
            LoopbackServer.writeAll(sock, Data("hello".utf8))
            shutdown(sock, SHUT_WR)
            _ = srv.readUntilEOF(sock)
        }
        defer { server.close() }

        let connection = try await SOCKS5Client.connectTCP(host: "127.0.0.1", port: server.port)
        defer { connection.cancel() }

        // The app only starts its upload once the server's half-close has
        // reached it, so the bytes are provably sent *after* the relay saw
        // EOF in the other direction.
        let app = FakeRelayEndpoint()
        app.onFinishWriting = {
            app.push(.success(.data(Data("late upload".utf8))))
            app.push(.success(.eof))
        }

        let outcome = await TCPRelay.run(
            app: app,
            proxy: NWConnectionRelayEndpoint(connection: connection),
            halfCloseIdleTimeout: 5
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.written, Data("hello".utf8))
        XCTAssertTrue(app.finishedWriting)
        XCTAssertEqual(server.received, Data("late upload".utf8))
    }

    /// The server's last bytes and its FIN can land in one `receive`
    /// callback (`data` non-empty, `isComplete == true`). Network.framework
    /// then never reports `isComplete` again — the next receive fails with
    /// ENODATA — so the endpoint must remember that trailing EOF instead of
    /// turning it into an error. Sleeping before the relay starts makes both
    /// arrive before the first receive is even issued.
    func testTrailingEOFDeliveredWithLastBytesIsAnOrderlyClose() async throws {
        let server = try LoopbackServer()
        server.serve { srv, sock in
            LoopbackServer.writeAll(sock, Data("reply".utf8))
            shutdown(sock, SHUT_WR)
            _ = srv.readUntilEOF(sock)
        }
        defer { server.close() }

        let connection = try await SOCKS5Client.connectTCP(host: "127.0.0.1", port: server.port)
        defer { connection.cancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let app = FakeRelayEndpoint()
        app.onFinishWriting = { app.push(.success(.eof)) }

        let outcome = await TCPRelay.run(
            app: app,
            proxy: NWConnectionRelayEndpoint(connection: connection),
            halfCloseIdleTimeout: 5
        )

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.written, Data("reply".utf8))
        XCTAssertTrue(app.finishedWriting)
        XCTAssertEqual(server.received, Data())
    }

    // MARK: - Pure in-memory ordering checks

    func testAppEOFForwardsFINAndKeepsDrainingProxy() async {
        let app = FakeRelayEndpoint()
        let proxy = FakeRelayEndpoint()
        app.push(.success(.data(Data("req".utf8))))
        app.push(.success(.eof))
        // Proxy answers only after it has seen the app's FIN, and not
        // instantly: a relay that tears down on the first EOF must be shown
        // to lose a response that arrives a moment later.
        proxy.onFinishWriting = {
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                proxy.push(.success(.data(Data("resp-1".utf8))))
                proxy.push(.success(.data(Data("resp-2".utf8))))
                proxy.push(.success(.eof))
            }
        }

        let outcome = await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 5)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(proxy.written, Data("req".utf8))
        XCTAssertTrue(proxy.finishedWriting)
        XCTAssertEqual(app.written, Data("resp-1resp-2".utf8))
        XCTAssertTrue(app.finishedWriting)
    }

    func testProxyEOFHalfClosesFlowAndKeepsForwardingApp() async {
        let app = FakeRelayEndpoint()
        let proxy = FakeRelayEndpoint()
        proxy.push(.success(.data(Data("banner".utf8))))
        proxy.push(.success(.eof))
        app.onFinishWriting = {
            Task {
                try? await Task.sleep(nanoseconds: 50_000_000)
                app.push(.success(.data(Data("tail".utf8))))
                app.push(.success(.eof))
            }
        }

        let outcome = await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 5)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.written, Data("banner".utf8))
        XCTAssertTrue(app.finishedWriting)
        XCTAssertEqual(proxy.written, Data("tail".utf8))
        XCTAssertTrue(proxy.finishedWriting)
    }

    // MARK: - Safeguards

    /// A read error is not an EOF: the sibling direction, parked on a read
    /// that will never resolve, must be cancelled promptly.
    func testErrorInOneDirectionCancelsTheOther() async {
        let app = FakeRelayEndpoint()   // never produces anything
        let proxy = FakeRelayEndpoint()
        proxy.push(.failure(SOCKS5Error.unexpectedEOF))

        let start = Date()
        let outcome = await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 30)

        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertFalse(app.finishedWriting, "an error must not be reported to the app as an orderly EOF")
    }

    /// After a half-close, a peer that never closes its side cannot pin the
    /// relay forever: the idle bound tears it down.
    func testHalfCloseIdleTimeoutStopsSilentPeer() async {
        let app = FakeRelayEndpoint()
        let proxy = FakeRelayEndpoint()   // accepts the FIN, then goes silent
        app.push(.success(.eof))

        let start = Date()
        let outcome = await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 0.3)

        XCTAssertEqual(outcome, .halfCloseTimedOut)
        XCTAssertTrue(proxy.finishedWriting)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    /// Data flowing on the remaining direction keeps resetting the idle bound.
    func testHalfCloseIdleTimeoutIsIdleNotAbsolute() async {
        let app = FakeRelayEndpoint()
        let proxy = FakeRelayEndpoint()
        app.push(.success(.eof))

        let feeder = Task {
            for i in 0..<6 {
                try await Task.sleep(nanoseconds: 100_000_000)
                proxy.push(.success(.data(Data("chunk\(i)".utf8))))
            }
            proxy.push(.success(.eof))
        }
        defer { feeder.cancel() }

        // 0.6 s of traffic spaced 0.1 s apart, against a 0.3 s idle bound.
        let outcome = await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 0.3)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(app.written, Data("chunk0chunk1chunk2chunk3chunk4chunk5".utf8))
    }

    /// Cancelling the task that runs the relay must unblock both pending reads.
    func testExternalCancellationUnblocksPendingReads() async {
        let app = FakeRelayEndpoint()
        let proxy = FakeRelayEndpoint()
        let task = Task {
            await TCPRelay.run(app: app, proxy: proxy, halfCloseIdleTimeout: 30)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let start = Date()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}

// MARK: - Fake endpoint

/// In-memory `TCPRelayEndpoint`: reads are served from a queue the test
/// pushes into (a pending read parks until something is pushed, and honours
/// task cancellation through the production `withCancellableResult`); writes
/// and `finishWriting` are recorded.
private final class FakeRelayEndpoint: TCPRelayEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<TCPRelayRead, Error>] = []
    private var waiter: ((Result<TCPRelayRead, Error>) -> Void)?
    private var writtenData = Data()
    private var finished = false

    /// Invoked (synchronously, on the relay's task) when the peer's EOF is
    /// propagated to this endpoint. Tests use it to sequence "send only
    /// after the other side half-closed".
    var onFinishWriting: (() -> Void)?

    var written: Data {
        lock.lock()
        defer { lock.unlock() }
        return writtenData
    }

    var finishedWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func push(_ item: Result<TCPRelayRead, Error>) {
        lock.lock()
        if let waiter = waiter {
            self.waiter = nil
            lock.unlock()
            waiter(item)
        } else {
            queue.append(item)
            lock.unlock()
        }
    }

    func read() async throws -> TCPRelayRead {
        try await SOCKS5Client.withCancellableResult(TCPRelayRead.self) { resume in
            lock.lock()
            if !queue.isEmpty {
                let item = queue.removeFirst()
                lock.unlock()
                resume(item)
            } else {
                waiter = resume
                lock.unlock()
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.lock()
        writtenData.append(data)
        lock.unlock()
    }

    func finishWriting() async throws {
        lock.lock()
        finished = true
        lock.unlock()
        onFinishWriting?()
    }
}

// MARK: - Loopback TCP server

/// Minimal blocking POSIX server on 127.0.0.1:<ephemeral>. `serve` accepts
/// one connection on a background thread and hands it to the handler;
/// everything the handler reads via `readUntilEOF` is exposed through
/// `received`.
private final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var receivedData = Data()
    private let done = DispatchSemaphore(value: 0)

    var received: Data {
        // Wait for the handler to finish so the assertion sees the full read.
        _ = done.wait(timeout: .now() + 5)
        done.signal()
        lock.lock()
        defer { lock.unlock() }
        return receivedData
    }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func serve(_ handler: @escaping (LoopbackServer, Int32) -> Void) {
        let fd = listenFD
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            if client >= 0 {
                handler(self, client)
                Darwin.close(client)
            }
            done.signal()
        }
    }

    func readUntilEOF(_ sock: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        lock.lock()
        receivedData.append(data)
        lock.unlock()
        return data
    }

    static func writeAll(_ sock: Int32, _ data: Data) {
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = send(sock, buf.baseAddress! + offset, buf.count - offset, 0)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    func close() {
        Darwin.close(listenFD)
    }
}
