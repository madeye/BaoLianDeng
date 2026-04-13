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

enum ConfigSource: Hashable {
    case local
    case subscription(UUID)
}

enum EditorMode: String, CaseIterable {
    case structured = "Structured"
    case raw = "Raw YAML"
}

struct ConfigEditorView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var configText = ""
    @State private var proxyGroups: [EditableProxyGroup] = []
    @State private var rules: [EditableRule] = []
    @State private var subscriptionText = ""
    @State private var subscriptionProxyGroups: [EditableProxyGroup] = []
    @State private var subscriptionRules: [EditableRule] = []
    @State private var source: ConfigSource = .local
    @State private var selectedSubscription: Subscription?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var showSaved = false
    @State private var isLoaded = false
    @State private var scrollToTopTrigger = false
    @State private var editorMode: EditorMode = .structured
    @State private var validationErrors: [YAMLError] = []
    @State private var showValidationErrors = false
    @State private var showReloadPrompt = false
    @State private var isReloading = false

    private var isSub: Bool {
        if case .subscription = source { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if editorMode == .structured {
                structuredEditor
            } else {
                rawEditor
            }
        }
        .navigationTitle("Config")
        .toolbar { toolbarContent }
        .onChange(of: editorMode) { oldMode, newMode in
            handleModeChange(from: oldMode, to: newMode)
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
        .alert("Apply Changes Now?", isPresented: $showReloadPrompt) {
            Button("Later", role: .cancel) {}
            Button("Reload") {
                Task { await reloadConfig() }
            }
        } message: {
            Text("Config saved. Reload now to apply changes to the running VPN? This will briefly interrupt connections.")
        }
        .overlay { if showSaved { savedToast } }
        .onAppear {
            guard !isLoaded else { return }
            isLoaded = true
            loadConfig()
            loadSelectedSubscription()
        }
        .onChange(of: source) { _, newSource in
            if case .subscription = newSource {
                loadConfig()
                loadSelectedSubscription()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $editorMode) {
                ForEach(EditorMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented).frame(width: 200)
        }
        ToolbarItem(placement: .primaryAction) {
            if !isSub {
                Button("Save") { saveConfig() }.disabled(isSaving)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if !isSub {
                Button("Reset Default", role: .destructive) {
                    resetConfig()
                }
            }
        }
    }

    private var structuredEditor: some View {
        ScrollViewReader { proxy in
            List {
                if selectedSubscription != nil {
                    Section {
                        Picker("Source", selection: $source) {
                            Text("Local Config")
                                .tag(ConfigSource.local)
                            if let sub = selectedSubscription {
                                Text(sub.name).tag(
                                    ConfigSource.subscription(sub.id)
                                )
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .id("sourcePicker")
                }
                ConfigSectionsView(
                    proxyGroups: $proxyGroups,
                    rules: $rules,
                    subscriptionProxyGroups: subscriptionProxyGroups,
                    subscriptionRules: subscriptionRules,
                    isSub: isSub
                ).id("proxyGroupsTop")
            }
            .onChange(of: scrollToTopTrigger) { _, _ in
                withAnimation {
                    let anchor = selectedSubscription != nil
                        ? "sourcePicker" : "proxyGroupsTop"
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    private var rawEditor: some View {
        VStack(spacing: 0) {
            YAMLEditor(
                text: isSub ? $subscriptionText : $configText,
                validationErrors: $validationErrors,
                isEditable: !isSub,
                onFocusLost: isSub ? nil : { autoSaveRawConfig() }
            )
            ValidationStatusBar(
                errors: validationErrors,
                isReadOnly: isSub,
                showErrors: $showValidationErrors
            )
        }
    }

    private var savedToast: some View {
        VStack {
            Spacer()
            Text("Saved")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(.thinMaterial).clipShape(Capsule())
                .padding(.bottom, 80)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Actions

    private func handleModeChange(
        from oldMode: EditorMode, to newMode: EditorMode
    ) {
        if oldMode == .structured && newMode == .raw {
            var yaml = configText
            yaml = ConfigManager.shared.updateProxyGroups(
                proxyGroups, in: yaml
            )
            yaml = ConfigManager.shared.updateRules(rules, in: yaml)
            configText = yaml
        } else if oldMode == .raw && newMode == .structured {
            reparseConfig()
        }
    }

    private func autoSaveRawConfig() {
        do {
            try ConfigManager.shared.saveConfig(configText)
            showSavedToast()
            if vpnManager.isConnected {
                showReloadPrompt = true
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadConfig() {
        configText = ConfigManager.shared.configExists()
            ? ((try? ConfigManager.shared.loadConfig())
                ?? ConfigManager.shared.defaultConfig())
            : ConfigManager.shared.defaultConfig()
        reparseConfig()
    }

    private func loadSelectedSubscription() {
        let defaults = AppConstants.sharedDefaults
        guard let data = defaults.data(forKey: "subscriptions"),
              let subs = try? JSONDecoder().decode(
                [Subscription].self, from: data),
              let idStr = defaults.string(
                forKey: "selectedSubscriptionID"),
              let subID = UUID(uuidString: idStr),
              let sub = subs.first(where: { $0.id == subID })
        else { selectedSubscription = nil; return }
        selectedSubscription = sub
        subscriptionText = sub.rawContent ?? ""
        guard !subscriptionText.isEmpty else { source = .local; return }
        try? ConfigManager.shared.applySubscriptionConfig(
            subscriptionText)
        configText = (try? ConfigManager.shared.loadConfig())
            ?? ConfigManager.shared.defaultConfig()
        reparseConfig()
        subscriptionProxyGroups = proxyGroups
        subscriptionRules = rules
    }

    private func saveConfig() {
        isSaving = true
        do {
            if editorMode == .raw {
                try ConfigManager.shared.saveConfig(configText)
                reparseConfig()
            } else {
                var yaml = configText
                yaml = ConfigManager.shared.updateProxyGroups(
                    proxyGroups, in: yaml)
                yaml = ConfigManager.shared.updateRules(rules, in: yaml)
                try ConfigManager.shared.saveConfig(yaml)
                configText = yaml
            }
            showSavedToast()
            if vpnManager.isConnected {
                showReloadPrompt = true
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isSaving = false
    }

    private func reloadConfig() async {
        isReloading = true
        do {
            try await MihomoAPI.reloadConfig()
        } catch {
            await MainActor.run {
                errorMessage = "Reload failed: \(error.localizedDescription)"
                showError = true
            }
        }
        await MainActor.run {
            isReloading = false
        }
    }

    private func resetConfig() {
        configText = ConfigManager.shared.defaultConfig()
        reparseConfig()
    }

    private func reparseConfig() {
        proxyGroups = ConfigManager.shared.parseProxyGroups(
            from: configText)
        rules = ConfigManager.shared.parseRules(from: configText)
    }

    private func showSavedToast() {
        withAnimation { showSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showSaved = false }
        }
    }
}

#Preview {
    ConfigEditorView()
        .environmentObject(VPNManager.shared)
}
