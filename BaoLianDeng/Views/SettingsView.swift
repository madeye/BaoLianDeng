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

            Section("System Extension") {
                Button("Uninstall System Extension") {
                    vpnManager.stop()
                    vpnManager.deactivateSystemExtension()
                }
                .foregroundStyle(.red)
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
