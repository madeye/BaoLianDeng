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
import os

enum AppLogger {
    static let subsystem = "io.github.baoliandeng"

    static let tunnel  = Logger(subsystem: subsystem, category: "tunnel")
    static let config  = Logger(subsystem: subsystem, category: "config")
    static let vpn     = Logger(subsystem: subsystem, category: "vpn")
    static let ui      = Logger(subsystem: subsystem, category: "ui")
    static let parser  = Logger(subsystem: subsystem, category: "parser")
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Log to both os.Logger and NSLog so messages appear in system log.
    /// Uses .notice level so messages are persisted and visible via `log show`.
    static func log(_ logger: Logger, category: String, _ message: String) {
        logger.notice("\(message, privacy: .public)")
        NSLog("[%@] %@", category, message)
    }
}
