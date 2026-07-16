// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import MihomoCore
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var results: [DiagnosticTest: DiagnosticResult] = [:]
    @State private var isRunningAll = false
    @State private var memoryInfo: String?

    var body: some View {
        List {
            Section("Tests") {
                ForEach(DiagnosticTest.allCases, id: \.self) { test in
                    testRow(test)
                }
            }

            if let mem = memoryInfo {
                Section("Engine") {
                    HStack {
                        Text("Memory Usage")
                        Spacer()
                        Text(mem)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await runAllTests() }
                } label: {
                    if isRunningAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Run All")
                    }
                }
                .disabled(isRunningAll)
            }
        }
    }

    private func testRow(_ test: DiagnosticTest) -> some View {
        let result = results[test]
        let isRunning = result?.isRunning ?? false
        let canRun = !isRunning && !isRunningAll && (test.requiresVPN ? vpnManager.isConnected : true)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result?.icon ?? "circle")
                    .foregroundStyle(result?.color ?? .secondary)
                Text(test.displayName)
                    .font(.body)
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await runSingleTest(test) }
                    } label: {
                        Text("Run")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canRun)
                }
            }
            if !test.requiresVPN && !vpnManager.isConnected {
                Text(String(localized: "Available without VPN"))
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if test.requiresVPN && !vpnManager.isConnected {
                Text(String(localized: "Requires VPN connection"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let detail = result?.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    private func runSingleTest(_ test: DiagnosticTest) async {
        results[test] = DiagnosticResult(isRunning: true)
        let output = await executeTest(test)
        results[test] = DiagnosticResult(
            detail: output,
            passed: output.hasPrefix("OK"),
            isRunning: false
        )
    }

    private func runAllTests() async {
        isRunningAll = true

        // Fetch memory info if VPN is connected
        if vpnManager.isConnected {
            if let memory = try? await MihomoAPI.fetchMemory() {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .memory
                memoryInfo = formatter.string(fromByteCount: memory.inuse)
            }
        }

        for test in DiagnosticTest.allCases {
            if test.requiresVPN && !vpnManager.isConnected {
                results[test] = DiagnosticResult(
                    detail: String(localized: "Skipped — VPN not connected"),
                    passed: nil,
                    isRunning: false
                )
                continue
            }
            results[test] = DiagnosticResult(isRunning: true)
            let output = await executeTest(test)
            results[test] = DiagnosticResult(
                detail: output,
                passed: output.hasPrefix("OK"),
                isRunning: false
            )
        }

        isRunningAll = false
    }

    private func executeTest(_ test: DiagnosticTest) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String
                switch test {
                case .directTCP:
                    result = BridgeTestDirectTCP("93.184.216.34", 80)
                case .proxyHTTP:
                    result = BridgeTestProxyHTTP("http://www.gstatic.com/generate_204")
                case .dnsResolver:
                    let dnsPort = BridgeGetDNSPort()
                    result = dnsPort > 0
                        ? BridgeTestDNSResolver("127.0.0.1:\(dnsPort)")
                        : "VPN not running"
                case .selectedProxy:
                    result = AppConstants.externalControllerAddr.map(BridgeTestSelectedProxy)
                        ?? "VPN not running"
                }
                continuation.resume(returning: result)
            }
        }
    }
}

// MARK: - Models

private enum DiagnosticTest: CaseIterable, Hashable {
    case directTCP
    case proxyHTTP
    case dnsResolver
    case selectedProxy

    var displayName: String {
        switch self {
        case .directTCP: return String(localized: "Direct TCP Connection")
        case .proxyHTTP: return String(localized: "Proxy HTTP Request")
        case .dnsResolver: return String(localized: "DNS Resolver")
        case .selectedProxy: return String(localized: "Selected Proxy Latency")
        }
    }

    var requiresVPN: Bool {
        switch self {
        case .directTCP: return false
        case .proxyHTTP, .dnsResolver, .selectedProxy: return true
        }
    }
}

private struct DiagnosticResult {
    var detail: String?
    var passed: Bool?
    var isRunning: Bool

    var icon: String {
        if isRunning { return "hourglass" }
        guard let passed else { return "circle" }
        return passed ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var color: Color {
        if isRunning { return .secondary }
        guard let passed else { return .secondary }
        return passed ? .green : .red
    }
}

#Preview {
    DiagnosticsView()
        .environmentObject(VPNManager.shared)
}
