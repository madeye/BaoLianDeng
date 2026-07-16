// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI
import NetworkExtension

struct VPNToolbarContent: ToolbarContent {
    @EnvironmentObject var vpnManager: VPNManager
    @AppStorage("selectedSubscriptionID") private var selectedIDString: String?
    @AppStorage("subscriptions") private var subscriptionsData: Data?

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)

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
        guard let idStr = selectedIDString,
              let data = subscriptionsData else {
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
