// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

struct TunnelLogView: View {
    @State private var logLines: [String] = []
    @State private var autoRefresh = true
    @State private var lastDataHash = 0
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let placeholder = String(localized: "No log yet — toggle the VPN to generate logs.")

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if logLines.isEmpty {
                    Text(placeholder)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 1)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                }
                Color.clear
                    .frame(height: 1)
                    .id("bottom")
            }
            .onChange(of: logLines.count) {
                if autoRefresh {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .navigationTitle("Tunnel Log")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logLines.joined(separator: "\n"), forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    Toggle(isOn: $autoRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .toggleStyle(.button)
                }
            }
        }
        .onAppear { loadLog() }
        .onReceive(timer) { _ in
            if autoRefresh { loadLog() }
        }
    }

    private func loadLog() {
        VPNManager.shared.sendMessage(["action": "get_log"]) { data in
            DispatchQueue.main.async {
                guard let data = data, let text = String(data: data, encoding: .utf8),
                      !text.isEmpty else { return }
                let hash = text.hashValue
                guard hash != lastDataHash else { return }
                lastDataHash = hash
                logLines = text.components(separatedBy: .newlines)
            }
        }
    }
}
