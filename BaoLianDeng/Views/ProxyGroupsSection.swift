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

/// Displays proxy groups fetched from the mihomo REST API with expand/collapse,
/// node selection, and delay testing. Follows meow-go's ProxyGroupsSection pattern.
struct ProxyGroupsSection: View {
    @Bindable var viewModel: ProxyGroupsViewModel
    let isVpnConnected: Bool

    @State private var expandedGroups: Set<String> = []

    var body: some View {
        Section {
            if viewModel.isLoading && viewModel.groups.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if viewModel.groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No Proxy Groups")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(viewModel.groups, id: \.name) { group in
                    ProxyGroupRow(
                        group: group,
                        viewModel: viewModel,
                        isVpnConnected: isVpnConnected,
                        isExpanded: expandedGroups.contains(group.name),
                        onToggle: {
                            let wasExpanded = expandedGroups.contains(group.name)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if wasExpanded {
                                    expandedGroups.remove(group.name)
                                } else {
                                    expandedGroups.insert(group.name)
                                }
                            }
                            // Auto-test delays when expanding and VPN is connected
                            if !wasExpanded && isVpnConnected {
                                Task {
                                    await viewModel.testGroupDelay(group: group.name)
                                }
                            }
                        }
                    )
                }
            }

            if let error = viewModel.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Proxy Groups")
                if viewModel.isOffline {
                    Text("OFFLINE")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}

// MARK: - Group Row

private struct ProxyGroupRow: View {
    let group: MihomoProxyGroup
    @Bindable var viewModel: ProxyGroupsViewModel
    let isVpnConnected: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button(action: onToggle) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(group.name)
                                .font(.subheadline.weight(.medium))

                            GroupTypeBadge(type: group.type)
                        }

                        Text(viewModel.currentSelection(for: group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if viewModel.testingGroups.contains(group.name) {
                        ProgressView()
                            .controlSize(.small)
                    } else if isVpnConnected {
                        Button {
                            Task {
                                await viewModel.testGroupDelay(group: group.name)
                            }
                        } label: {
                            Image(systemName: "bolt.horizontal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Test delay for all nodes")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded member list
            if isExpanded {
                Divider()
                    .padding(.leading, 20)

                ForEach(group.all, id: \.self) { nodeName in
                    ProxyMemberRow(
                        nodeName: nodeName,
                        isSelected: viewModel.currentSelection(for: group) == nodeName,
                        delay: viewModel.delay(for: nodeName),
                        isSelector: group.type == "Selector",
                        onSelect: {
                            Task {
                                await viewModel.selectProxy(
                                    group: group.name,
                                    name: nodeName,
                                    vpnConnected: isVpnConnected
                                )
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Member Row

private struct ProxyMemberRow: View {
    let nodeName: String
    let isSelected: Bool
    let delay: Int?
    let isSelector: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .green : .secondary.opacity(0.5))
                    .frame(width: 20)

                Text(nodeName)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                DelayBadge(delay: delay)
            }
            .padding(.leading, 24)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelector)
        .opacity(isSelector ? 1.0 : 0.7)
    }
}

// MARK: - Group Type Badge

private struct GroupTypeBadge: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var badgeColor: Color {
        switch type {
        case "Selector": return .blue
        case "URLTest": return .teal
        case "Fallback": return .orange
        case "LoadBalance": return .purple
        case "Relay": return .pink
        default: return .gray
        }
    }
}

// MARK: - Delay Badge

private struct DelayBadge: View {
    let delay: Int?

    var body: some View {
        Text(displayText)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var displayText: String {
        guard let ms = delay else { return "--" }
        if ms == 0 { return "timeout" }
        return "\(ms)ms"
    }

    private var badgeColor: Color {
        switch ProxyGroupsViewModel.delayColor(delay) {
        case .untested: return .gray
        case .timeout: return .red
        case .fast: return .green
        case .medium: return .orange
        case .slow: return .red
        }
    }
}

#Preview {
    List {
        ProxyGroupsSection(
            viewModel: {
                let vm = ProxyGroupsViewModel()
                vm.groups = [
                    MihomoProxyGroup(name: "PROXY", type: "Selector", now: "US-Node-1", all: ["US-Node-1", "JP-Node-2", "DIRECT"]),
                    MihomoProxyGroup(name: "Auto", type: "URLTest", now: "JP-Node-2", all: ["US-Node-1", "JP-Node-2"])
                ]
                vm.selections = ["PROXY": "US-Node-1", "Auto": "JP-Node-2"]
                vm.delays = ["US-Node-1": 120, "JP-Node-2": 85]
                return vm
            }(),
            isVpnConnected: true
        )
    }
    .listStyle(.inset)
    .frame(width: 400, height: 300)
}
