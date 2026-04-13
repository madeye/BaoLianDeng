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

struct RulesView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var rules: [MihomoRule] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var filteredRules: [MihomoRule] {
        if searchText.isEmpty { return rules }
        let query = searchText.lowercased()
        return rules.filter {
            $0.type.lowercased().contains(query) ||
            $0.payload.lowercased().contains(query) ||
            $0.proxy.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if !vpnManager.isConnected {
                ContentUnavailableView(
                    "VPN Not Connected",
                    systemImage: "shield.slash",
                    description: Text("Connect VPN to view active rules")
                )
            } else if isLoading && rules.isEmpty {
                ProgressView("Loading rules...")
            } else if let error = errorMessage, rules.isEmpty {
                ContentUnavailableView(
                    "Failed to Load Rules",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if rules.isEmpty {
                ContentUnavailableView(
                    "No Rules",
                    systemImage: "checklist",
                    description: Text("No rules configured")
                )
            } else {
                List {
                    Section {
                        Text(String(format: String(localized: "%lld rules loaded"), rules.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(filteredRules) { rule in
                        ruleRow(rule)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .searchable(text: $searchText, prompt: "Filter rules")
        .navigationTitle("Rules")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadRules() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!vpnManager.isConnected || isLoading)
            }
        }
        .onAppear {
            if vpnManager.isConnected {
                Task { await loadRules() }
            }
        }
        .onChange(of: vpnManager.isConnected) { _, connected in
            if connected {
                Task { await loadRules() }
            } else {
                rules = []
            }
        }
    }

    private func ruleRow(_ rule: MihomoRule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.payload)
                    .font(.body)
                    .foregroundStyle(.primary)
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

    private func loadRules() async {
        isLoading = true
        errorMessage = nil
        do {
            rules = try await MihomoAPI.fetchRules()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

#Preview {
    RulesView()
        .environmentObject(VPNManager.shared)
}
