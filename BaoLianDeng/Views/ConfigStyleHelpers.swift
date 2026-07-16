// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

enum ConfigStyleHelpers {
    static func groupTypeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "select": return "list.bullet"
        case "url-test": return "bolt.horizontal"
        case "fallback": return "arrow.triangle.branch"
        case "load-balance": return "scale.3d"
        default: return "square.stack.3d.up"
        }
    }

    static func groupTypeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "select": return .blue
        case "url-test": return .orange
        case "fallback": return .purple
        case "load-balance": return .green
        default: return .gray
        }
    }

    static func ruleTypeIcon(_ type: String) -> String {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
            return "globe"
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            return "network"
        case "GEOIP": return "map"
        case "GEOSITE": return "mappin.and.ellipse"
        case "MATCH": return "arrow.right.square"
        default: return "questionmark.circle"
        }
    }

    static func ruleTypeColor(_ type: String) -> Color {
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
            return .blue
        case "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR":
            return .orange
        case "GEOIP", "GEOSITE": return .purple
        case "MATCH": return .gray
        default: return .secondary
        }
    }

    static func targetColor(_ target: String) -> Color {
        switch target {
        case "DIRECT": return .green
        case "REJECT": return .red
        case "PROXY": return .blue
        default: return .orange
        }
    }
}

// MARK: - Proxy Group Row

struct ProxyGroupRowView: View {
    let group: EditableProxyGroup

    var body: some View {
        HStack {
            Image(systemName: ConfigStyleHelpers.groupTypeIcon(group.type))
                .foregroundStyle(
                    ConfigStyleHelpers.groupTypeColor(group.type)
                )
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                Text(group.type)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.proxies.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Rule Row

struct RuleRowView: View {
    let rule: EditableRule

    var body: some View {
        HStack(spacing: 8) {
            Image(
                systemName: ConfigStyleHelpers.ruleTypeIcon(rule.type)
            )
            .font(.system(size: 12))
            .foregroundStyle(
                ConfigStyleHelpers.ruleTypeColor(rule.type)
            )
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                if rule.type == "MATCH" {
                    Text("MATCH (catch-all)")
                        .font(.body)
                } else {
                    Text(rule.value)
                        .font(.body)
                        .lineLimit(1)
                    let suffix = rule.noResolve
                        ? " \u{00b7} no-resolve" : ""
                    Text(rule.type + suffix)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(rule.target)
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    ConfigStyleHelpers.targetColor(rule.target)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    ConfigStyleHelpers.targetColor(rule.target)
                        .opacity(0.12)
                )
                .clipShape(Capsule())
        }
    }
}

// MARK: - Config Sections

struct ConfigSectionsView: View {
    @Binding var proxyGroups: [EditableProxyGroup]
    @Binding var rules: [EditableRule]
    let subscriptionProxyGroups: [EditableProxyGroup]
    let subscriptionRules: [EditableRule]
    let isSub: Bool

    var body: some View {
        Section {
            NavigationLink {
                ProxyGroupsListView(
                    proxyGroups: $proxyGroups,
                    subscriptionProxyGroups: subscriptionProxyGroups,
                    isSub: isSub
                )
            } label: {
                HStack {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                    Text("Proxy Groups")
                    Spacer()
                    let count = isSub
                        ? subscriptionProxyGroups.count
                        : proxyGroups.count
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                RulesListView(
                    rules: $rules,
                    subscriptionRules: subscriptionRules,
                    proxyGroupNames: proxyGroups.map(\.name),
                    isSub: isSub
                )
            } label: {
                HStack {
                    Image(systemName: "list.bullet.rectangle")
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                    Text("Rules")
                    Spacer()
                    let count = isSub
                        ? subscriptionRules.count : rules.count
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Validation Status Bar

struct ValidationStatusBar: View {
    let errors: [YAMLError]
    let isReadOnly: Bool
    @Binding var showErrors: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                if errors.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Valid YAML")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        withAnimation { showErrors.toggle() }
                    } label: {
                        errorLabel
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if isReadOnly {
                    Text("Read Only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            if showErrors && !errors.isEmpty {
                errorList
            }
        }
    }

    private var errorLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("\(errors.count) issue\(errors.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: showErrors
                  ? "chevron.down" : "chevron.up")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var errorList: some View {
        Group {
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(errors) { error in
                        HStack(spacing: 6) {
                            Text("L\(error.line)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .frame(
                                    width: 40, alignment: .trailing
                                )
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 120)
            .background(.bar)
        }
    }
}
