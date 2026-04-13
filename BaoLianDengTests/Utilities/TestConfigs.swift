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

enum TestConfigs {

    /// Minimal config that starts the proxy engine with SOCKS5 on :7890,
    /// external controller on :9090, and DNS on :1053.
    static let minimal = """
        mixed-port: 7890
        mode: rule
        log-level: silent
        external-controller: 127.0.0.1:9090
        dns:
          enable: true
          listen: 127.0.0.1:1053
          enhanced-mode: redir-host
          nameserver:
            - 114.114.114.114
        proxies: []
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - DIRECT
        rules:
          - MATCH,DIRECT
        """

    /// Config with an unreachable proxy node for testing error paths.
    static let withUnreachableProxy = """
        mixed-port: 7890
        mode: rule
        log-level: silent
        external-controller: 127.0.0.1:9090
        proxies:
          - name: unreachable
            type: ss
            server: 192.0.2.1
            port: 8388
            cipher: aes-256-gcm
            password: test
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - unreachable
              - DIRECT
        rules:
          - MATCH,PROXY
        """

    /// Invalid YAML that should fail parsing.
    static let invalid = """
        mixed-port: 7890
        proxies: [[[not valid yaml
        """
}
