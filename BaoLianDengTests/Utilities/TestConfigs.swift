// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

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
