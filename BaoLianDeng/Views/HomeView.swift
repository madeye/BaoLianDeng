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
import NetworkExtension
import UniformTypeIdentifiers
import os

struct HomeView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var selectedMode: ProxyMode = .rule
    @State private var subscriptions: [Subscription] = []
    @State private var selectedNode: String?
    @State private var selectedSubscriptionID: UUID?
    @State private var showAddSubscription = false
    @State private var editingSubscription: Subscription?
    @State private var isReloading = false
    @State private var reloadResult: ReloadResult?
    @State private var expandedSubscriptionIDs: Set<UUID> = []
    @State private var scrollProxy: ScrollViewProxy?
    @State private var toastMessage: String = ""
    @State private var showToast: Bool = false
    @State private var showExtensionHelp = false
    @State private var showFileImporter = false
    @State private var testingNodes: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            List {
                extensionStatusSection

                routingSection

                Section(header:
                    Text("Subscriptions")
                        .id("subscriptionsTop")
                ) {
                    subscriptionSections
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onAppear { scrollProxy = proxy }
        }
        .navigationTitle("Subscriptions")
        .onTapGesture(count: 2) {
            withAnimation {
                scrollProxy?.scrollTo("subscriptionsTop", anchor: .top)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.yaml],
            allowsMultipleSelection: false
        ) { result in
            importConfigFile(result)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Subscription") {
                        showAddSubscription = true
                    }
                    Button("Import Config File") {
                        showFileImporter = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reloadAllSubscriptions() }
                } label: {
                    if isReloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(subscriptions.isEmpty || isReloading)
            }
        }
        .alert(item: $reloadResult) { result in
            Alert(
                title: Text("Reload Complete"),
                message: Text(result.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showAddSubscription, onDismiss: {
            fetchNewSubscriptions()
        }) {
            AddSubscriptionView(subscriptions: $subscriptions)
        }
        .sheet(item: $editingSubscription) { sub in
            EditSubscriptionView(subscription: sub) { updated in
                if let i = subscriptions.firstIndex(where: { $0.id == updated.id }) {
                    subscriptions[i] = updated
                    saveSubscriptions()
                }
            }
        }
        .onAppear {
            loadSubscriptions()
            loadCurrentMode()
        }
        .overlay {
            if showToast {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.thinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 80)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func displayToast(_ message: String) {
        toastMessage = message
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { self.showToast = false }
        }
    }

    private var extensionHelpMessage: String {
        switch vpnManager.systemExtensionInstallState {
        case .rebootRequired:
            return "The system extension install finished, but macOS requires a reboot before BaoLianDeng can start the VPN."
        case .failed:
            return "System Settings has been opened.\n\nRetry the Network Extension approval for BaoLianDeng. If macOS keeps rejecting it, relaunch the app or reinstall the package."
        default:
            return "System Settings has been opened.\n\nPlease go to Network Extensions and toggle on BaoLianDeng to enable the VPN."
        }
    }

    // MARK: - Extension Status

    private var extensionStatusSection: some View {
        Section {
            if !vpnManager.extensionEnabled {
                Button {
                    showExtensionHelp = true
                    vpnManager.checkExtensionStatus(forceRetry: true)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.shield.fill")
                        Text(String(localized: "Enable Network Extension"))
                            .font(.subheadline)
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .alert("Enable Network Extension", isPresented: $showExtensionHelp) {
                    Button("OK") {}
                } message: {
                    Text(extensionHelpMessage)
                }
            }

            if let err = vpnManager.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Routing

    private var routingSection: some View {
        Section {
            Picker("Routing", selection: $selectedMode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedMode) { _, newMode in
                if vpnManager.isConnected {
                    // Live switch via REST API — no tunnel restart needed
                    Task {
                        try? await MihomoAPI.switchMode(newMode.rawValue)
                    }
                    ConfigManager.shared.setMode(newMode.rawValue)
                } else {
                    vpnManager.switchMode(newMode)
                }
            }
        }
    }

    // MARK: - Subscription Sections

    @ViewBuilder
    private var subscriptionSections: some View {
        if subscriptions.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("No Subscriptions")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Tap + to add a subscription URL")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ForEach($subscriptions) { $sub in
                HStack {
                        Button(action: {
                            if selectedSubscriptionID != sub.id {
                                selectSubscription(sub)
                            }
                            withAnimation {
                                if expandedSubscriptionIDs.contains(sub.id) {
                                    expandedSubscriptionIDs.remove(sub.id)
                                } else {
                                    expandedSubscriptionIDs.insert(sub.id)
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: expandedSubscriptionIDs.contains(sub.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sub.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text("\(sub.nodes.count) nodes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedSubscriptionID == sub.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Button(action: { refreshSubscription(&sub) }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            if let i = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                                deleteSubscription(at: IndexSet(integer: i))
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingSubscription = sub
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button {
                            editingSubscription = sub
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button {
                            refreshSubscription(&sub)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        if vpnManager.isConnected && !sub.nodes.isEmpty {
                            Button {
                                testAllNodesDelay(in: $sub)
                            } label: {
                                Label("Test All Latency", systemImage: "bolt.horizontal")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            if let i = subscriptions.firstIndex(where: { $0.id == sub.id }) {
                                deleteSubscription(at: IndexSet(integer: i))
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                if expandedSubscriptionIDs.contains(sub.id) {
                    ForEach(sub.nodes) { node in
                        NodeRow(
                            node: node,
                            isSelected: node.name == selectedNode,
                            onSelect: {
                                selectedNode = node.name
                                saveSelectedNode(node.name)
                                if selectedSubscriptionID != sub.id {
                                    selectSubscription(sub)
                                }
                                vpnManager.selectNode(node.name)
                            },
                            isTesting: testingNodes.contains(node.name),
                            onTestDelay: vpnManager.isConnected ? {
                                testNodeDelay(node: node, in: $sub)
                            } : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func selectSubscription(_ sub: Subscription) {
        selectedSubscriptionID = sub.id
        AppConstants.sharedDefaults
            .set(sub.id.uuidString, forKey: "selectedSubscriptionID")
        let nodeNames = Set(sub.nodes.map(\.name))
        if selectedNode == nil || !nodeNames.contains(selectedNode ?? "") {
            if let first = sub.nodes.first {
                selectedNode = first.name
                saveSelectedNode(first.name)
            }
        }
        if let raw = sub.rawContent {
            Task.detached {
                let merged = (try? ConfigManager.shared.applySubscriptionConfig(raw)) ?? ""
                await Self.reloadMihomoConfig(with: merged)
            }
        }
    }

    private func loadSubscriptions() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                () -> (subs: [Subscription], selectedNode: String?, selectedID: UUID?)? in
                let defaults = AppConstants.sharedDefaults
                guard let data = defaults.data(forKey: "subscriptions"),
                      var subs = try? JSONDecoder().decode([Subscription].self, from: data) else {
                    return nil
                }
                var needsSave = false
                for i in subs.indices {
                    if subs[i].nodes.isEmpty, let raw = subs[i].rawContent, !raw.isEmpty {
                        subs[i].nodes = SubscriptionParser.parse(raw)
                        if !subs[i].nodes.isEmpty { needsSave = true }
                    }
                }
                if needsSave, let saveData = try? JSONEncoder().encode(subs) {
                    defaults.set(saveData, forKey: "subscriptions")
                }
                let selectedNode = defaults.string(forKey: "selectedNode")
                let selectedID: UUID?
                if let idStr = defaults.string(forKey: "selectedSubscriptionID"),
                   let id = UUID(uuidString: idStr),
                   subs.contains(where: { $0.id == id }) {
                    selectedID = id
                } else {
                    selectedID = nil
                }
                return (subs, selectedNode, selectedID)
            }.value

            guard let result else { return }
            subscriptions = result.subs
            selectedNode = result.selectedNode
            if let id = result.selectedID {
                selectedSubscriptionID = id
                expandedSubscriptionIDs.insert(id)
                if let sub = result.subs.first(where: { $0.id == id }),
                   let raw = sub.rawContent {
                    try? ConfigManager.shared.applySubscriptionConfig(raw)
                }
            }
            fetchNewSubscriptions()
        }
    }

    private func saveSubscriptions() {
        let snapshot = subscriptions
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: "subscriptions")
        }
    }

    private func saveSelectedNode(_ name: String) {
        AppConstants.sharedDefaults
            .set(name, forKey: "selectedNode")
    }

    static func reloadMihomoConfig(with yaml: String) async {
        guard let url = URL(string: "http://\(AppConstants.externalControllerAddr)/configs?force=true") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["payload": yaml])
        _ = try? await URLSession.shared.data(for: request)
    }

    private func fetchNewSubscriptions() {
        for sub in subscriptions where sub.nodes.isEmpty {
            let id = sub.id
            let url = sub.url
            let name = sub.name
            Task {
                let wasConnected = await vpnManager.disconnectForFetch()
                defer { if wasConnected { vpnManager.start() } }
                do {
                    let result = try await fetchSubscription(from: url)
                    if let validationError = ConfigManager.shared.validateSubscriptionConfig(result.raw) {
                        displayToast(String(format: String(localized: "Invalid: %@"), validationError))
                        AppLogger.ui.error("Validation failed for \(name, privacy: .public): \(validationError, privacy: .public)")
                        return
                    }
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        subscriptions[i].nodes = result.nodes
                        subscriptions[i].rawContent = result.raw
                    }
                    saveSubscriptions()
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        selectSubscription(subscriptions[i])
                    }
                    displayToast(String(format: String(localized: "Fetched %@"), name))
                } catch {
                    displayToast(String(format: String(localized: "Failed to fetch %@"), name))
                }
            }
        }
    }

    private func loadCurrentMode() {
        // Sync mode from saved preference, or from running engine
        if let saved = AppConstants.sharedDefaults.string(forKey: "proxyMode"),
           let mode = ProxyMode(rawValue: saved) {
            selectedMode = mode
        }
        guard vpnManager.isConnected else { return }
        Task {
            if let mode = try? await MihomoAPI.fetchCurrentMode(),
               let proxyMode = ProxyMode(rawValue: mode) {
                selectedMode = proxyMode
            }
        }
    }

    private func testAllNodesDelay(in sub: Binding<Subscription>) {
        let nodes = sub.wrappedValue.nodes
        for node in nodes {
            testNodeDelay(node: node, in: sub)
        }
    }

    private func testNodeDelay(node: ProxyNode, in sub: Binding<Subscription>) {
        guard !testingNodes.contains(node.name) else { return }
        testingNodes.insert(node.name)
        Task {
            defer { testingNodes.remove(node.name) }
            do {
                let delay = try await MihomoAPI.testProxyDelay(proxy: node.name)
                if let subIdx = subscriptions.firstIndex(where: { $0.id == sub.wrappedValue.id }),
                   let nodeIdx = subscriptions[subIdx].nodes.firstIndex(where: { $0.id == node.id }) {
                    subscriptions[subIdx].nodes[nodeIdx].delay = delay
                }
            } catch {
                // Timeout or unreachable — set delay to 0 to indicate failure
                if let subIdx = subscriptions.firstIndex(where: { $0.id == sub.wrappedValue.id }),
                   let nodeIdx = subscriptions[subIdx].nodes.firstIndex(where: { $0.id == node.id }) {
                    subscriptions[subIdx].nodes[nodeIdx].delay = 0
                }
            }
        }
    }

    private func importConfigFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                displayToast(String(localized: "Cannot access file"))
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let yaml = try String(contentsOf: url, encoding: .utf8)
                if let validationError = ConfigManager.shared.validateSubscriptionConfig(yaml) {
                    displayToast(String(format: String(localized: "Invalid: %@"), validationError))
                    return
                }
                let nodes = SubscriptionParser.parse(yaml)
                let name = url.deletingPathExtension().lastPathComponent
                let sub = Subscription(name: name, url: "", nodes: nodes, rawContent: yaml)
                subscriptions.append(sub)
                saveSubscriptions()
                selectSubscription(sub)
                expandedSubscriptionIDs.insert(sub.id)
                displayToast(String(format: String(localized: "Imported %@ (%lld nodes)"), name, nodes.count))
            } catch {
                displayToast(String(format: String(localized: "Failed to read file: %@"), error.localizedDescription))
            }
        case .failure(let error):
            displayToast(String(format: String(localized: "File picker error: %@"), error.localizedDescription))
        }
    }

    private func deleteSubscription(at offsets: IndexSet) {
        for i in offsets where subscriptions[i].id == selectedSubscriptionID {
            selectedSubscriptionID = nil
            AppConstants.sharedDefaults
                .removeObject(forKey: "selectedSubscriptionID")
        }
        subscriptions.remove(atOffsets: offsets)
        saveSubscriptions()
    }

    private func refreshSubscription(_ sub: inout Subscription) {
        let id = sub.id
        let url = sub.url
        let name = sub.name
        sub.isUpdating = true
        Task {
            let wasConnected = await vpnManager.disconnectForFetch()
            defer { if wasConnected { vpnManager.start() } }
            do {
                let result = try await fetchSubscription(from: url)
                if let validationError = ConfigManager.shared.validateSubscriptionConfig(result.raw) {
                    if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                        subscriptions[i].isUpdating = false
                    }
                    displayToast(String(format: String(localized: "Invalid: %@"), validationError))
                    return
                }
                if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                    subscriptions[i].nodes = result.nodes
                    subscriptions[i].rawContent = result.raw
                    subscriptions[i].isUpdating = false
                }
                saveSubscriptions()
                if id == selectedSubscriptionID {
                    let merged = (try? ConfigManager.shared.applySubscriptionConfig(result.raw)) ?? ""
                    await Self.reloadMihomoConfig(with: merged)
                }
                displayToast(String(format: String(localized: "Updated %@ (%lld nodes)"), name, result.nodes.count))
            } catch {
                if let i = subscriptions.firstIndex(where: { $0.id == id }) {
                    subscriptions[i].isUpdating = false
                }
                displayToast(String(format: String(localized: "Failed to fetch %@"), name))
            }
        }
    }

    private func reloadAllSubscriptions() async {
        guard !subscriptions.isEmpty else { return }
        isReloading = true
        let wasConnected = await vpnManager.disconnectForFetch()
        defer { if wasConnected { vpnManager.start() } }
        var succeeded: [String] = []
        var failed: [(String, String)] = []

        await withTaskGroup(of: (Int, Result<(nodes: [ProxyNode], raw: String), Error>).self) { group in
            for (i, sub) in subscriptions.enumerated() {
                group.addTask {
                    do {
                        let result = try await fetchSubscription(from: sub.url)
                        return (i, .success(result))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            for await (i, result) in group {
                switch result {
                case .success(let fetched):
                    if let validationError = ConfigManager.shared.validateSubscriptionConfig(fetched.raw) {
                        failed.append((subscriptions[i].name, "Invalid config: \(validationError)"))
                    } else {
                        subscriptions[i].nodes = fetched.nodes
                        subscriptions[i].rawContent = fetched.raw
                        succeeded.append(subscriptions[i].name)
                    }
                case .failure(let error):
                    failed.append((subscriptions[i].name, error.localizedDescription))
                }
            }
        }

        saveSubscriptions()
        if let selID = selectedSubscriptionID,
           let sub = subscriptions.first(where: { $0.id == selID }),
           let raw = sub.rawContent {
            let merged = (try? ConfigManager.shared.applySubscriptionConfig(raw)) ?? ""
            await Self.reloadMihomoConfig(with: merged)
        }
        isReloading = false
        reloadResult = ReloadResult(succeeded: succeeded, failed: failed)
    }

    private func fetchSubscription(from urlString: String) async throws -> (nodes: [ProxyNode], raw: String) {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("ClashMetaForAndroid/2.11.1.Meta", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription URL=\(urlString) status=\((response as? HTTPURLResponse)?.statusCode ?? -1) bytes=\(data.count)")
        guard let text = String(data: data, encoding: .utf8) else {
            AppLogger.log(AppLogger.network, category: "network", "ERROR: fetchSubscription cannot decode as UTF-8")
            throw URLError(.cannotDecodeContentData)
        }
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription raw preview (first 500 chars): \(String(text.prefix(500)))")
        let result = SubscriptionParser.parseWithYAML(text)
        let rawContent = result.generatedYAML ?? text
        AppLogger.log(AppLogger.network, category: "network", "fetchSubscription parsed \(result.nodes.count) nodes (generated YAML: \(result.generatedYAML != nil))")
        return (result.nodes, rawContent)
    }
}

#Preview {
    HomeView()
        .environmentObject(VPNManager.shared)
}
