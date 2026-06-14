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
