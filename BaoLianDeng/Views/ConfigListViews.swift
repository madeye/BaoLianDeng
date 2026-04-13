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

// MARK: - Proxy Groups List View

struct ProxyGroupsListView: View {
    @Binding var proxyGroups: [EditableProxyGroup]
    let subscriptionProxyGroups: [EditableProxyGroup]
    let isSub: Bool

    @State private var searchText = ""
    @State private var showAddGroup = false

    private var groups: [EditableProxyGroup] {
        isSub ? subscriptionProxyGroups : proxyGroups
    }

    private var filteredGroups: [EditableProxyGroup] {
        guard !searchText.isEmpty else { return groups }
        let query = searchText.lowercased()
        return groups.filter {
            $0.name.lowercased().contains(query)
                || $0.type.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            if isSub {
                ForEach(filteredGroups) { group in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: .constant(group), isEditable: false
                        )
                    } label: { ProxyGroupRowView(group: group) }
                }
            } else {
                ForEach(filteredIndices, id: \.self) { index in
                    NavigationLink {
                        ProxyGroupDetailView(
                            group: $proxyGroups[index], isEditable: true
                        )
                    } label: {
                        ProxyGroupRowView(group: proxyGroups[index])
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            proxyGroups.remove(at: index)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search proxy groups")
        .navigationTitle("Proxy Groups")
        .toolbar {
            if !isSub {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddGroup = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddGroup) {
            AddProxyGroupSheet { proxyGroups.append($0) }
        }
    }

    private var filteredIndices: [Int] {
        guard !searchText.isEmpty else {
            return Array(proxyGroups.indices)
        }
        let query = searchText.lowercased()
        return proxyGroups.indices.filter { index in
            proxyGroups[index].name.lowercased().contains(query)
                || proxyGroups[index].type.lowercased().contains(query)
        }
    }
}

// MARK: - Rules List View

enum RulesViewMode: String, CaseIterable {
    case configured = "Configured"
    case active = "Active"
}

struct RulesListView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @Binding var rules: [EditableRule]
    let subscriptionRules: [EditableRule]
    let proxyGroupNames: [String]
    let isSub: Bool

    @State private var searchText = ""
    @State private var showAddRule = false
    @State private var editingRuleIndex: Int?
    @State private var viewMode: RulesViewMode = .configured
    @State private var activeRules: [MihomoRule] = []
    @State private var isLoadingActive = false
    @State private var activeError: String?

    private var sourceRules: [EditableRule] {
        isSub ? subscriptionRules : rules
    }

    private var filteredRules: [EditableRule] {
        guard !searchText.isEmpty else { return sourceRules }
        let query = searchText.lowercased()
        return sourceRules.filter {
            $0.type.lowercased().contains(query)
                || $0.value.lowercased().contains(query)
                || $0.target.lowercased().contains(query)
        }
    }

    private var filteredActiveRules: [MihomoRule] {
        guard !searchText.isEmpty else { return activeRules }
        let query = searchText.lowercased()
        return activeRules.filter {
            $0.type.lowercased().contains(query)
                || $0.payload.lowercased().contains(query)
                || $0.proxy.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isSub {
                Picker("View", selection: $viewMode) {
                    ForEach(RulesViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if viewMode == .active && !isSub {
                activeRulesList
            } else {
                configuredRulesList
            }
        }
        .searchable(text: $searchText, prompt: "Search rules")
        .navigationTitle(navigationTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAddRule) {
            AddRuleSheet(groupNames: proxyGroupNames) { rules.append($0) }
        }
        .sheet(isPresented: Binding(
            get: { editingRuleIndex != nil },
            set: { if !$0 { editingRuleIndex = nil } }
        )) {
            if let index = editingRuleIndex {
                EditRuleSheet(
                    groupNames: proxyGroupNames,
                    rule: rules[index]
                ) { updated in
                    rules[index] = updated
                }
            }
        }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .active && vpnManager.isConnected {
                Task { await loadActiveRules() }
            }
        }
        .onChange(of: vpnManager.isConnected) { _, connected in
            if !connected && viewMode == .active {
                activeRules = []
            }
        }
    }

    private var navigationTitle: String {
        if viewMode == .active && !isSub {
            return "Rules (\(activeRules.count))"
        }
        return "Rules (\(sourceRules.count))"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewMode == .active && !isSub {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await loadActiveRules() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!vpnManager.isConnected || isLoadingActive)
            }
        } else if !isSub {
            ToolbarItem(placement: .automatic) {
                Button {
                    showAddRule = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private var configuredRulesList: some View {
        List {
            if isSub {
                ForEach(filteredRules) { RuleRowView(rule: $0) }
            } else {
                ForEach(filteredIndices, id: \.self) { index in
                    RuleRowView(rule: rules[index])
                        .contextMenu {
                            Button("Edit") {
                                editingRuleIndex = index
                            }
                            Button("Delete", role: .destructive) {
                                rules.remove(at: index)
                            }
                        }
                }
                .onDelete { offsets in
                    let indices = offsets.map { filteredIndices[$0] }
                    for index in indices.sorted().reversed() {
                        rules.remove(at: index)
                    }
                }
                .onMove { from, dest in
                    guard searchText.isEmpty else { return }
                    rules.move(fromOffsets: from, toOffset: dest)
                }
            }
        }
    }

    @ViewBuilder
    private var activeRulesList: some View {
        if !vpnManager.isConnected {
            ContentUnavailableView(
                "VPN Not Connected",
                systemImage: "shield.slash",
                description: Text("Connect VPN to view active rules")
            )
        } else if isLoadingActive && activeRules.isEmpty {
            ProgressView("Loading rules...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = activeError, activeRules.isEmpty {
            ContentUnavailableView(
                "Failed to Load",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if activeRules.isEmpty {
            ContentUnavailableView(
                "No Active Rules",
                systemImage: "checklist",
                description: Text("No rules loaded in proxy engine")
            )
        } else {
            List {
                ForEach(filteredActiveRules) { rule in
                    activeRuleRow(rule)
                }
            }
        }
    }

    private func activeRuleRow(_ rule: MihomoRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.payload)
                    .font(.body)
                    .textSelection(.enabled)
                Text(rule.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(rule.proxy)
                .font(.caption)
                .foregroundStyle(proxyColor(rule.proxy))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(proxyColor(rule.proxy).opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private func proxyColor(_ proxy: String) -> Color {
        switch proxy {
        case "DIRECT": return .green
        case "REJECT": return .red
        default: return .blue
        }
    }

    private func loadActiveRules() async {
        isLoadingActive = true
        activeError = nil
        do {
            activeRules = try await MihomoAPI.fetchRules()
        } catch {
            activeError = error.localizedDescription
        }
        isLoadingActive = false
    }

    private var filteredIndices: [Int] {
        guard !searchText.isEmpty else {
            return Array(rules.indices)
        }
        let query = searchText.lowercased()
        return rules.indices.filter { index in
            rules[index].type.lowercased().contains(query)
                || rules[index].value.lowercased().contains(query)
                || rules[index].target.lowercased().contains(query)
        }
    }
}
