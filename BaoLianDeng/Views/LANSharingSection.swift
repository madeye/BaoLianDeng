// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See the LICENSE file for details.

import SwiftUI

// MARK: - Settings Section (Allow LAN)

struct LANSharingSection: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var settings = LANSharingSettings()
    @State private var lanAddresses: [String] = []

    var body: some View {
        Section {
            Toggle("Allow LAN", isOn: $settings.enabled)
                .toggleStyle(.switch)
                .onChange(of: settings.enabled) {
                    if settings.enabled {
                        lanAddresses = Self.currentIPv4Addresses()
                    }
                    save()
                }

            if settings.enabled {
                TextField(
                    "Proxy Port",
                    value: $settings.proxyPort,
                    format: .number.grouping(.never)
                )
                .onSubmit { commitPort() }

                if !lanAddresses.isEmpty {
                    LabeledContent("LAN Proxy Address") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(lanAddresses, id: \.self) { address in
                                Text("\(address):\(String(settings.effectiveProxyPort))")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("LAN")
        } footer: {
            Text(
                """
                While the VPN is connected, other devices on your network can use \
                this Mac as their SOCKS5/HTTP proxy server on the proxy port. \
                Anyone on the local network can use the proxy — enable only on \
                networks you trust.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .onAppear {
            load()
            lanAddresses = Self.currentIPv4Addresses()
        }
        // The port field commits on Enter; also commit when focus leaves the tab.
        .onDisappear { commitPort() }
    }

    private func load() {
        settings = LANSharingSettings.load()
    }

    private func save() {
        settings.save()
        vpnManager.restartIfConnected()
    }

    /// Persist an edited port field, but only restart the tunnel when the
    /// stored value actually changed — onDisappear fires on every tab
    /// switch and must not bounce the VPN gratuitously.
    private func commitPort() {
        guard settings != LANSharingSettings.load() else { return }
        save()
    }

    /// Non-loopback IPv4 addresses of this Mac's active interfaces, for
    /// display so the user knows what to point other devices at. Skips
    /// utun* (the VPN's own tunnels are not reachable from the LAN).
    private static func currentIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var ptr = ifaddrPtr
        while let current = ptr {
            let ifa = current.pointee
            ptr = ifa.ifa_next

            let flags = Int32(bitPattern: ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ifa.ifa_name)
            guard !name.hasPrefix("utun") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            let address = String(cString: host)
            if !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }
}
