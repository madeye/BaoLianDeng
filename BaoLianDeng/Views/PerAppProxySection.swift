// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Section (NavigationLink)

struct PerAppProxySection: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var settings = PerAppProxySettings()

    var body: some View {
        Section("Per-App Proxy") {
            Toggle("Enable Per-App Proxy", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .onChange(of: settings.enabled) { save() }

            if settings.enabled {
                Picker("Mode", selection: $settings.mode) {
                    Text("Bypass Listed Apps").tag(PerAppProxyMode.blocklist)
                    Text("Proxy Only Listed Apps").tag(PerAppProxyMode.allowlist)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.mode) { save() }

                NavigationLink("Manage Apps") {
                    PerAppProxyDetailView(settings: $settings, save: save)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let defaults = AppConstants.sharedDefaults
        guard let data = defaults.data(
            forKey: AppConstants.perAppProxySettingsKey
        ),
            let decoded = try? JSONDecoder().decode(
                PerAppProxySettings.self, from: data
            )
        else { return }
        settings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppConstants.sharedDefaults.set(
            data, forKey: AppConstants.perAppProxySettingsKey
        )
        vpnManager.restartIfConnected()
    }
}

// MARK: - Detail View (app list + search + add/remove)

struct PerAppProxyDetailView: View {
    @Binding var settings: PerAppProxySettings
    var save: () -> Void
    @State private var searchText = ""

    private var filteredApps: [PerAppEntry] {
        if searchText.isEmpty { return settings.apps }
        let query = searchText.lowercased()
        return settings.apps.filter {
            $0.displayName.lowercased().contains(query)
                || $0.bundleID.lowercased().contains(query)
        }
    }

    var body: some View {
        List {
            ForEach(filteredApps) { entry in
                HStack(spacing: 10) {
                    appIcon(for: entry)
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                            .font(.body)
                        Text(entry.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        removeApp(entry)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle("Per-App Proxy")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    pickApps()
                } label: {
                    Label("Add App", systemImage: "plus")
                }
            }
        }
    }

    // MARK: - App Picker

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            var changed = false
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                    let bundleID = bundle.bundleIdentifier
                else { continue }
                if settings.apps.contains(where: {
                    $0.bundleID == bundleID
                }) { continue }
                let name = FileManager.default.displayName(
                    atPath: url.path
                )
                let entry = PerAppEntry(
                    bundleID: bundleID,
                    displayName: name,
                    bundlePath: url.path
                )
                settings.apps.append(entry)
                changed = true
            }
            if changed { save() }
        }
    }

    private func removeApp(_ entry: PerAppEntry) {
        settings.apps.removeAll { $0.bundleID == entry.bundleID }
        save()
    }

    private func appIcon(for entry: PerAppEntry) -> Image {
        let icon = NSWorkspace.shared.icon(forFile: entry.bundlePath)
        return Image(nsImage: icon)
    }
}
