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
import Charts

struct TrafficView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @EnvironmentObject var trafficStore: TrafficStore

    var body: some View {
        List {
            sessionSection
            connectionsSection
            chartSection
            monthlySummarySection
            subscriptionUsageSection
            statusSection
        }
        .navigationTitle("Traffic & Data")
        .onAppear {
            if vpnManager.isConnected {
                trafficStore.startPolling()
            }
        }
        .onDisappear {
            trafficStore.stopPolling()
        }
        .onChange(of: vpnManager.isConnected) { _, connected in
            if connected {
                trafficStore.resetSession()
                trafficStore.startPolling()
            } else {
                trafficStore.stopPolling()
            }
        }
    }

    // MARK: - Current Session (Proxy Only)

    private var sessionSection: some View {
        Section("Current Session (Proxy Only)") {
            HStack {
                Label("Upload", systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                Spacer()
                Text(formatBytes(trafficStore.sessionProxyUpload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Text(formatBytes(trafficStore.sessionProxyDownload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Total", systemImage: "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(.purple)
                Spacer()
                Text(formatBytes(trafficStore.sessionTotal))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Active Connections

    private var connectionsSection: some View {
        Section {
            NavigationLink {
                ConnectionsView()
                    .environmentObject(vpnManager)
            } label: {
                HStack {
                    Label("Active Connections", systemImage: "network")
                    Spacer()
                    if vpnManager.isConnected {
                        Text("\(trafficStore.activeProxyCount) proxy / \(trafficStore.activeTotalCount) total")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Daily Bar Chart

    private var chartSection: some View {
        Section("Daily Proxy Traffic (Last 30 Days)") {
            if chartEntries.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.bar",
                    description: Text("Traffic data will appear here when VPN is active")
                )
                .frame(height: 200)
            } else {
                let dayCount = Set(chartEntries.map(\.dayLabel)).count
                let chartWidth = max(CGFloat(dayCount) * 28, 300)
                ScrollView(.horizontal, showsIndicators: false) {
                    Chart(chartEntries, id: \.id) { entry in
                        BarMark(
                            x: .value("Day", entry.dayLabel),
                            y: .value("Bytes", entry.megabytes)
                        )
                        .foregroundStyle(by: .value("Direction", entry.category))
                    }
                    .chartForegroundStyleScale([
                        String(localized: "Upload"): Color.blue,
                        String(localized: "Download"): Color.green,
                    ])
                    .chartYAxisLabel("MB")
                    .frame(width: chartWidth, height: 200)
                }
                .defaultScrollAnchor(.trailing)
            }
        }
    }

    // MARK: - Monthly Summary

    private var monthlySummarySection: some View {
        Section("Monthly Summary") {
            HStack {
                Label("Upload", systemImage: "arrow.up.circle")
                    .foregroundStyle(.blue)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthUpload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Download", systemImage: "arrow.down.circle")
                    .foregroundStyle(.green)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthDownload))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack {
                Label("Total", systemImage: "arrow.up.arrow.down.circle")
                    .foregroundStyle(.purple)
                Spacer()
                Text(formatBytes(trafficStore.currentMonthTotal))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Subscription Usage

    private var subscriptionUsageSection: some View {
        Section {
            NavigationLink {
                SubscriptionUsageView()
                    .environmentObject(trafficStore)
            } label: {
                HStack {
                    Label("Usage by Subscription", systemImage: "chart.pie.fill")
                    Spacer()
                    if !trafficStore.subscriptionUsages.isEmpty {
                        Text(formatBytes(trafficStore.subscriptionUsages.reduce(0) { $0 + $1.total }))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Connection")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(vpnManager.isConnected ? .green : .gray)
                        .frame(width: 8, height: 8)
                    Text(vpnManager.isConnected ? String(localized: "Active") : String(localized: "Inactive"))
                        .foregroundStyle(.secondary)
                }
            }

            if vpnManager.isConnected {
                HStack {
                    Text("Active Connections")
                    Spacer()
                    Text("\(trafficStore.activeProxyCount) proxy / \(trafficStore.activeTotalCount) total")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Chart Data

    private var chartEntries: [TrafficChartEntry] {
        let records = trafficStore.dailyRecords.sorted { $0.date < $1.date }
        var entries: [TrafficChartEntry] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "M/d"
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        for record in records {
            let dayLabel: String
            if let date = formatter.date(from: record.date) {
                dayLabel = displayFormatter.string(from: date)
            } else {
                dayLabel = String(record.date.suffix(5))
            }
            entries.append(TrafficChartEntry(
                dayLabel: dayLabel, date: record.date,
                megabytes: Double(record.proxyUpload) / 1_048_576.0,
                category: String(localized: "Upload")
            ))
            entries.append(TrafficChartEntry(
                dayLabel: dayLabel, date: record.date,
                megabytes: Double(record.proxyDownload) / 1_048_576.0,
                category: String(localized: "Download")
            ))
        }
        return entries
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

private struct TrafficChartEntry {
    let dayLabel: String
    let date: String
    let megabytes: Double
    let category: String

    var id: String { "\(date)-\(category)" }
}

struct SubscriptionUsageView: View {
    @EnvironmentObject var trafficStore: TrafficStore
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            if trafficStore.subscriptionUsages.isEmpty {
                ContentUnavailableView(
                    "No Usage Data",
                    systemImage: "chart.pie",
                    description: Text("Connect the VPN to start attributing traffic to subscriptions")
                )
            } else {
                ForEach(trafficStore.subscriptionUsages.sorted { $0.total > $1.total }) { usage in
                    usageRow(for: usage)
                }
            }
        }
        .navigationTitle("Usage by Subscription")
        .toolbar {
            if !trafficStore.subscriptionUsages.isEmpty {
                ToolbarItem(placement: .automatic) {
                    Button("Reset", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog(
            "Reset all subscription usage data?",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset All", role: .destructive) { trafficStore.resetSubscriptionUsages() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently clear the usage counters for all subscriptions.")
        }
    }

    private func usageRow(for usage: SubscriptionUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usage.name).font(.headline)
            HStack {
                Label(formatBytes(usage.upload), systemImage: "arrow.up.circle.fill")
                    .font(.caption).foregroundStyle(.blue)
                Spacer()
                Label(formatBytes(usage.download), systemImage: "arrow.down.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill").foregroundStyle(.purple)
                    Text(formatBytes(usage.total)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            GeometryReader { geo in
                let grandTotal = trafficStore.subscriptionUsages.reduce(0) { $0 + $1.total }
                let fraction = grandTotal > 0 ? Double(usage.total) / Double(grandTotal) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(.systemFill)).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(Color.purple.opacity(0.7))
                        .frame(width: geo.size.width * fraction, height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 6)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    TrafficView()
        .environmentObject(VPNManager.shared)
        .environmentObject(TrafficStore.shared)
}
