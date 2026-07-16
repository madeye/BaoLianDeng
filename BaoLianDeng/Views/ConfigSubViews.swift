// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

// MARK: - Proxy Group Detail View

struct ProxyGroupDetailView: View {
    @Binding var group: EditableProxyGroup
    let isEditable: Bool

    @State private var newProxyName = ""

    var body: some View {
        List {
            Section("Group Info") {
                if isEditable {
                    editableGroupInfo
                } else {
                    readOnlyGroupInfo
                }
            }

            Section {
                if isEditable {
                    editableProxiesList
                } else {
                    ForEach(group.proxies, id: \.self) { proxy in
                        Text(proxy)
                    }
                }
            } header: {
                Text("Proxies (\(group.proxies.count))")
            }
        }
        .navigationTitle(group.name)
    }

    @ViewBuilder
    private var editableGroupInfo: some View {
        HStack {
            Text("Name")
            Spacer()
            TextField("Name", text: $group.name)
                .multilineTextAlignment(.trailing)
        }
        Picker("Type", selection: $group.type) {
            Text("select").tag("select")
            Text("url-test").tag("url-test")
            Text("fallback").tag("fallback")
            Text("load-balance").tag("load-balance")
        }
        if group.type == "url-test" || group.type == "fallback" {
            HStack {
                Text("URL")
                Spacer()
                TextField("Test URL", text: Binding(
                    get: { group.url ?? "" },
                    set: { group.url = $0.isEmpty ? nil : $0 }
                ))
                .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Interval")
                Spacer()
                TextField("300", value: Binding(
                    get: { group.interval ?? 300 },
                    set: { group.interval = $0 }
                ), format: .number)
                .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var readOnlyGroupInfo: some View {
        LabeledContent("Name", value: group.name)
        LabeledContent("Type", value: group.type)
        if let url = group.url {
            LabeledContent("URL", value: url)
        }
        if let interval = group.interval {
            LabeledContent("Interval", value: "\(interval)s")
        }
    }

    @ViewBuilder
    private var editableProxiesList: some View {
        ForEach(group.proxies, id: \.self) { proxy in
            Text(proxy)
        }
        .onDelete { offsets in
            group.proxies.remove(atOffsets: offsets)
        }
        .onMove { from, destination in
            group.proxies.move(fromOffsets: from, toOffset: destination)
        }
        HStack {
            TextField("Add proxy name", text: $newProxyName)
            Button {
                let name = newProxyName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    group.proxies.append(name)
                    newProxyName = ""
                }
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .disabled(newProxyName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Add Proxy Group Sheet

struct AddProxyGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: (EditableProxyGroup) -> Void

    @State private var name = ""
    @State private var type = "select"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group Name", text: $name)
                Picker("Type", selection: $type) {
                    Text("select").tag("select")
                    Text("url-test").tag("url-test")
                    Text("fallback").tag("fallback")
                    Text("load-balance").tag("load-balance")
                }
            }
            .navigationTitle("Add Proxy Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(EditableProxyGroup(
                            name: name,
                            type: type,
                            proxies: []
                        ))
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

// MARK: - Add Rule Sheet

struct AddRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupNames: [String]
    let onAdd: (EditableRule) -> Void

    @State private var type = "DOMAIN-SUFFIX"
    @State private var value = ""
    @State private var target = "PROXY"
    @State private var noResolve = false

    private let ruleTypes = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
        "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR",
        "GEOIP", "GEOSITE", "MATCH"
    ]

    private var targets: [String] {
        var result = ["PROXY", "DIRECT", "REJECT"]
        for name in groupNames where !result.contains(name) {
            result.append(name)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(ruleTypes, id: \.self) { ruleType in
                        Text(ruleType).tag(ruleType)
                    }
                }

                if type != "MATCH" {
                    TextField(valuePlaceholder, text: $value)
                        .autocorrectionDisabled()
                }

                Picker("Target", selection: $target) {
                    ForEach(targets, id: \.self) { targetName in
                        Text(targetName).tag(targetName)
                    }
                }

                if type.contains("IP") {
                    Toggle("no-resolve", isOn: $noResolve)
                }
            }
            .navigationTitle("Add Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(EditableRule(
                            type: type,
                            value: value,
                            target: target,
                            noResolve: noResolve
                        ))
                        dismiss()
                    }
                    .disabled(type != "MATCH" && value.isEmpty)
                }
            }
        }
    }

    private var valuePlaceholder: String {
        switch type {
        case "DOMAIN": return "example.com"
        case "DOMAIN-SUFFIX": return "google.com"
        case "DOMAIN-KEYWORD": return "google"
        case "IP-CIDR", "IP-CIDR6": return "10.0.0.0/8"
        case "GEOIP": return "CN"
        case "GEOSITE": return "google"
        default: return "Value"
        }
    }
}

// MARK: - Edit Rule Sheet

struct EditRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupNames: [String]
    let rule: EditableRule
    let onSave: (EditableRule) -> Void

    @State private var type: String
    @State private var value: String
    @State private var target: String
    @State private var noResolve: Bool

    private let ruleTypes = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD",
        "IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR",
        "GEOIP", "GEOSITE", "MATCH"
    ]

    init(
        groupNames: [String], rule: EditableRule,
        onSave: @escaping (EditableRule) -> Void
    ) {
        self.groupNames = groupNames
        self.rule = rule
        self.onSave = onSave
        _type = State(initialValue: rule.type)
        _value = State(initialValue: rule.value)
        _target = State(initialValue: rule.target)
        _noResolve = State(initialValue: rule.noResolve)
    }

    private var targets: [String] {
        var result = ["PROXY", "DIRECT", "REJECT"]
        for name in groupNames where !result.contains(name) {
            result.append(name)
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(ruleTypes, id: \.self) { ruleType in
                        Text(ruleType).tag(ruleType)
                    }
                }

                if type != "MATCH" {
                    TextField(valuePlaceholder, text: $value)
                        .autocorrectionDisabled()
                }

                Picker("Target", selection: $target) {
                    ForEach(targets, id: \.self) { targetName in
                        Text(targetName).tag(targetName)
                    }
                }

                if type.contains("IP") {
                    Toggle("no-resolve", isOn: $noResolve)
                }
            }
            .navigationTitle("Edit Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = rule
                        updated.type = type
                        updated.value = value
                        updated.target = target
                        updated.noResolve = noResolve
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(type != "MATCH" && value.isEmpty)
                }
            }
        }
    }

    private var valuePlaceholder: String {
        switch type {
        case "DOMAIN": return "example.com"
        case "DOMAIN-SUFFIX": return "google.com"
        case "DOMAIN-KEYWORD": return "google"
        case "IP-CIDR", "IP-CIDR6": return "10.0.0.0/8"
        case "GEOIP": return "CN"
        case "GEOSITE": return "google"
        default: return "Value"
        }
    }
}
