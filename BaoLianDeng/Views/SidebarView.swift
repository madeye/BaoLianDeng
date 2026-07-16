// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case subscriptions
    case config
    case traffic
    case settings
    case tunnelLog

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .subscriptions: return "Subscriptions"
        case .config: return "Config Editor"
        case .traffic: return "Traffic & Data"
        case .settings: return "Settings"
        case .tunnelLog: return "Tunnel Log"
        }
    }

    var icon: String {
        switch self {
        case .subscriptions: return "list.bullet"
        case .config: return "doc.text.fill"
        case .traffic: return "chart.bar.fill"
        case .settings: return "gearshape.fill"
        case .tunnelLog: return "terminal.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("VPN") {
                Label(SidebarItem.subscriptions.label, systemImage: SidebarItem.subscriptions.icon)
                    .tag(SidebarItem.subscriptions)
                Label(SidebarItem.config.label, systemImage: SidebarItem.config.icon)
                    .tag(SidebarItem.config)
                Label(SidebarItem.traffic.label, systemImage: SidebarItem.traffic.icon)
                    .tag(SidebarItem.traffic)
            }

            Section {
                Label(SidebarItem.settings.label, systemImage: SidebarItem.settings.icon)
                    .tag(SidebarItem.settings)
                Label(SidebarItem.tunnelLog.label, systemImage: SidebarItem.tunnelLog.icon)
                    .tag(SidebarItem.tunnelLog)
            }
        }
        .listStyle(.sidebar)
    }
}
