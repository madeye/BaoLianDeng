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

import SwiftUI

struct MainContentView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var selection: SidebarItem? = .subscriptions
    @State private var showExtensionHelp = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .toolbar {
            VPNToolbarContent()
        }
        .onAppear {
            vpnManager.checkExtensionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vpnManager.checkExtensionStatus()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .subscriptions:
            HomeView()
        case .config:
            ConfigEditorView()
        case .traffic:
            TrafficView()
        case .settings:
            SettingsView()
        case .tunnelLog:
            TunnelLogView()
        case nil:
            HomeView()
        }
    }
}

#Preview {
    MainContentView()
        .environmentObject(VPNManager.shared)
        .environmentObject(TrafficStore.shared)
}
