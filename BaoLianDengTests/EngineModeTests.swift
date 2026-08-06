// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import XCTest
@testable import BaoLianDeng

final class EngineModeTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "EngineModeTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testLoadDefaultsToVPN() {
        XCTAssertEqual(EngineMode.load(from: defaults), .vpn)
    }

    func testLoadRoundTrip() {
        defaults.set(EngineMode.localProxy.rawValue, forKey: AppConstants.engineModeKey)
        XCTAssertEqual(EngineMode.load(from: defaults), .localProxy)

        defaults.set(EngineMode.vpn.rawValue, forKey: AppConstants.engineModeKey)
        XCTAssertEqual(EngineMode.load(from: defaults), .vpn)
    }

    func testLoadIgnoresGarbageValue() {
        defaults.set("bogus", forKey: AppConstants.engineModeKey)
        XCTAssertEqual(EngineMode.load(from: defaults), .vpn)
    }

    func testLocalProxyPortClampsInvalidValues() {
        let defaults = AppConstants.sharedDefaults
        let saved = defaults.object(forKey: AppConstants.localProxyPortKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: AppConstants.localProxyPortKey)
            } else {
                defaults.removeObject(forKey: AppConstants.localProxyPortKey)
            }
        }

        defaults.removeObject(forKey: AppConstants.localProxyPortKey)
        XCTAssertEqual(AppConstants.localProxyPort, UInt16(AppConstants.defaultLocalProxyPort))

        defaults.set(0, forKey: AppConstants.localProxyPortKey)
        XCTAssertEqual(AppConstants.localProxyPort, UInt16(AppConstants.defaultLocalProxyPort))

        defaults.set(70000, forKey: AppConstants.localProxyPortKey)
        XCTAssertEqual(AppConstants.localProxyPort, UInt16(AppConstants.defaultLocalProxyPort))

        defaults.set(1080, forKey: AppConstants.localProxyPortKey)
        XCTAssertEqual(AppConstants.localProxyPort, 1080)
    }

    func testEphemeralPortFreeCheck() {
        // A port we just bound must report as busy; after closing it frees up.
        let sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(sock, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                Darwin.bind(sock, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindOK, 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                getsockname(sock, saptr, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        XCTAssertFalse(EphemeralPort.isTCPPortFree(port))
        close(sock)
        XCTAssertTrue(EphemeralPort.isTCPPortFree(port))
    }

    func testEphemeralPortFreeCheckIgnoresTimeWait() {
        // Regression: a proxy server actively closes client sockets on stop,
        // leaving server-side TIME_WAIT entries on its port. The check must
        // tolerate that (the engine's tokio listener binds with SO_REUSEADDR
        // and would succeed) instead of reporting the port as busy for ~30s.
        let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                Darwin.bind(listener, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindOK, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                getsockname(listener, saptr, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        // Client connects; server accepts then closes FIRST so the server
        // side (on `port`) is the one that lands in TIME_WAIT.
        let client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(client, 0)
        let connectOK = withUnsafePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                Darwin.connect(client, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connectOK, 0)
        let conn = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(conn, 0)
        close(conn)
        close(client)
        close(listener)

        XCTAssertTrue(EphemeralPort.isTCPPortFree(port))
    }
}
