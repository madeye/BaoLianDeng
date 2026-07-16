// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

struct NodeRow: View {
    let node: ProxyNode
    let isSelected: Bool
    let onSelect: () -> Void
    var isTesting: Bool = false
    var onTestDelay: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: node.typeIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(node.typeColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(node.type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                } else if let delay = node.delay {
                    Text(delay > 0 ? "\(delay) ms" : String(localized: "timeout"))
                        .font(.caption)
                        .foregroundStyle(delayColor(delay))
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let onTestDelay {
                Button {
                    onTestDelay()
                } label: {
                    Label("Test Latency", systemImage: "bolt.horizontal")
                }
            }
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .gray }
        if delay < 200 { return .green }
        if delay < 500 { return .orange }
        return .red
    }
}
