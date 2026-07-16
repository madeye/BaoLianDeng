// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import FirebaseCore
import SwiftUI

@main
struct BaoLianDengApp: App {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var trafficStore = TrafficStore.shared

    init() {
        guard !AppConstants.isRunningUnitTests else { return }
        FirebaseApp.configure()
        ConfigManager.shared.sanitizeConfig()
    }

    var body: some Scene {
        WindowGroup {
            MainContentView()
                .environmentObject(vpnManager)
                .environmentObject(trafficStore)
        }
        .defaultSize(width: 900, height: 600)
        .windowToolbarStyle(.unified)
    }
}
