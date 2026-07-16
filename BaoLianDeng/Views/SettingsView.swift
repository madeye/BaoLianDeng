// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @AppStorage("logLevel", store: AppConstants.sharedDefaults)
    private var logLevel = "info"
    @AppStorage("appLanguage")
    private var appLanguage = ""
    @AppStorage(AppConstants.autoStartVPNAtLoginKey, store: AppConstants.sharedDefaults)
    private var autoStartVPNAtLogin = false
    @State private var startupErrorMessage: String?

    var body: some View {
        Form {
            Section("General") {
                Picker("Language", selection: $appLanguage) {
                    Text("System Default").tag("")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                }
                .onChange(of: appLanguage) { _, newValue in
                    if newValue.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                }

                Picker("Log Level", selection: $logLevel) {
                    Text("Silent").tag("silent")
                    Text("Error").tag("error")
                    Text("Warning").tag("warning")
                    Text("Info").tag("info")
                    Text("Debug").tag("debug")
                }

                Toggle("Start VPN at Login", isOn: $autoStartVPNAtLogin)
                    .onChange(of: autoStartVPNAtLogin) { oldValue, newValue in
                        updateLoginItem(enabled: newValue, previousValue: oldValue)
                    }

                if let startupErrorMessage {
                    Text(startupErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            PerAppProxySection()

            Section("Diagnostics") {
                NavigationLink("Network Diagnostics") {
                    DiagnosticsView()
                        .environmentObject(vpnManager)
                }
            }

            // App-extension builds (Mac App Store) have no system extension
            // to uninstall — the provider lives inside the app bundle.
            if !VPNManager.providerIsAppExtension {
                Section("System Extension") {
                    Button("Uninstall System Extension") {
                        vpnManager.stop()
                        vpnManager.deactivateSystemExtension()
                    }
                    .foregroundStyle(.red)
                }
            }

            Section("About") {
                NavigationLink("About BaoLianDeng") {
                    AboutView()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private func updateLoginItem(enabled: Bool, previousValue: Bool) {
        startupErrorMessage = nil

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            autoStartVPNAtLogin = previousValue
            startupErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(VPNManager.shared)
}
