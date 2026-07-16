// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Foundation
import os

enum AppLogger {
    static let subsystem = "io.github.baoliandeng"

    static let tunnel  = Logger(subsystem: subsystem, category: "tunnel")
    static let config  = Logger(subsystem: subsystem, category: "config")
    static let vpn     = Logger(subsystem: subsystem, category: "vpn")
    static let ui      = Logger(subsystem: subsystem, category: "ui")
    static let parser  = Logger(subsystem: subsystem, category: "parser")
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Logs via os.Logger only, at default privacy (redacted in release builds).
    ///
    /// The NSLog mirror was removed: NSLog always writes plaintext to the
    /// persistent system log, which previously leaked proxy credentials
    /// (Shadowsocks passwords, VMess/VLESS UUIDs, Trojan passwords) whenever a
    /// call site logged raw subscription content. Callers MUST NOT pass
    /// secrets or raw credential material to this function.
    static func log(_ logger: Logger, category: String, _ message: String) {
        logger.notice("\(message)")
    }
}
