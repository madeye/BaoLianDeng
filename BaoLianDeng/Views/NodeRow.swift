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
