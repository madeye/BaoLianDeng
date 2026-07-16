// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

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
