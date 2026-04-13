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

struct ConnectionsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var connections: [MihomoConnection] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var timer: Timer?

    private var filteredConnections: [MihomoConnection] {
        if searchText.isEmpty { return connections }
        let query = searchText.lowercased()
        return connections.filter {
            $0.host.lowercased().contains(query) ||
            $0.rule.lowercased().contains(query) ||
            $0.rulePayload.lowercased().contains(query) ||
            $0.chains.joined(separator: " ").lowercased().contains(query) ||
            $0.network.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if !vpnManager.isConnected {
                ContentUnavailableView(
                    "VPN Not Connected",
                    systemImage: "shield.slash",
                    description: Text("Connect VPN to view connections")
                )
            } else if connections.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No Active Connections",
                    systemImage: "network.slash",
                    description: Text("Active connections will appear here")
                )
            } else {
                List {
                    Section {
                        HStack {
                            Text(String(format: String(localized: "%lld active connections"), filteredConnections.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Close All", role: .destructive) {
                                Task {
                                    try? await MihomoAPI.closeAllConnections()
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }

                    ForEach(filteredConnections) { conn in
                        connectionRow(conn)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .searchable(text: $searchText, prompt: "Filter by host, rule, or chain")
        .navigationTitle("Connections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await fetchConnections() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!vpnManager.isConnected)
            }
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: vpnManager.isConnected) { _, connected in
            if connected {
                startPolling()
            } else {
                stopPolling()
                connections = []
            }
        }
    }

    private func connectionRow(_ conn: MihomoConnection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conn.host.isEmpty ? conn.destinationIP : conn.host)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if conn.destinationPort > 0 {
                    Text(":\(conn.destinationPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(conn.network.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                Label(formatBytes(conn.upload), systemImage: "arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Label(formatBytes(conn.download), systemImage: "arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Label(formatDuration(since: conn.start), systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if !conn.rule.isEmpty {
                    Text(conn.rulePayload.isEmpty ? conn.rule : "\(conn.rule)(\(conn.rulePayload))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            if !conn.chains.isEmpty {
                Text(conn.chains.joined(separator: " → "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                Task {
                    try? await MihomoAPI.closeConnection(conn.id)
                    await fetchConnections()
                }
            } label: {
                Label("Close Connection", systemImage: "xmark.circle")
            }
        }
    }

    private func startPolling() {
        guard vpnManager.isConnected else { return }
        stopPolling()
        Task { await fetchConnections() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                await fetchConnections()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func fetchConnections() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await MihomoAPI.fetchConnections()
            connections = response.connections.sorted { $0.start > $1.start }
        } catch {
            // Silently fail — polling will retry
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let secs = seconds % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }
}

#Preview {
    ConnectionsView()
        .environmentObject(VPNManager.shared)
}
