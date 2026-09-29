// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import Testing
@testable import BaoLianDeng

@Suite("AnalyticsService")
struct AnalyticsServiceTests {

    @Test("Drops the detail after the app-authored prefix")
    func dropsDetail() {
        #expect(AnalyticsService.sanitizedReason("Failed to start tunnel: /Users/alice/x.yaml is bad")
                == "Failed to start tunnel")
    }

    @Test("Handles the full-width colon from Chinese localizations")
    func fullWidthColon() {
        #expect(AnalyticsService.sanitizedReason("启动本地代理失败：端口被占用") == "启动本地代理失败")
    }

    @Test("Keeps messages without detail and caps the length")
    func noDetail() {
        #expect(AnalyticsService.sanitizedReason("VPN manager not loaded") == "VPN manager not loaded")
        #expect(AnalyticsService.sanitizedReason(String(repeating: "a", count: 300)).count == 100)
    }
}
