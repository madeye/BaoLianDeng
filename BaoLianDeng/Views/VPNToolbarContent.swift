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
import NetworkExtension

struct VPNToolbarContent: ToolbarContent {
    @EnvironmentObject var vpnManager: VPNManager

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let name = selectedSubscriptionName, !name.isEmpty {
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200)
                }

                Toggle("", isOn: Binding(
                    get: { vpnManager.isConnected },
                    set: { _ in vpnManager.toggle() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(vpnManager.isProcessing)
                .controlSize(.small)
            }
        }
    }

    private var selectedSubscriptionName: String? {
        let defaults = AppConstants.sharedDefaults
        guard let idStr = defaults.string(forKey: "selectedSubscriptionID"),
              let data = defaults.data(forKey: "subscriptions") else {
            return nil
        }
        struct Sub: Decodable { var id: UUID; var name: String }
        guard let subs = try? JSONDecoder().decode([Sub].self, from: data),
              let selectedID = UUID(uuidString: idStr),
              let sub = subs.first(where: { $0.id == selectedID }) else {
            return nil
        }
        return sub.name
    }

    private var statusText: String {
        switch vpnManager.status {
        case .connected: return String(localized: "Connected")
        case .connecting: return String(localized: "Connecting...")
        case .disconnecting: return String(localized: "Disconnecting...")
        case .disconnected: return String(localized: "Not Connected")
        case .reasserting: return String(localized: "Reconnecting...")
        case .invalid: return String(localized: "Not Configured")
        @unknown default: return String(localized: "Unknown")
        }
    }

    private var statusColor: Color {
        switch vpnManager.status {
        case .connected: return .green
        case .connecting, .disconnecting, .reasserting: return .orange
        case .disconnected, .invalid: return .red
        @unknown default: return .gray
        }
    }
}
