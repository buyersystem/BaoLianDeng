// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vpnManager: VPNManager
    @AppStorage("logLevel", store: UserDefaults(suiteName: AppConstants.appGroupIdentifier))
    private var logLevel = "info"

    var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    Picker("Log Level", selection: $logLevel) {
                        Text("Silent").tag("silent")
                        Text("Error").tag("error")
                        Text("Warning").tag("warning")
                        Text("Info").tag("info")
                        Text("Debug").tag("debug")
                    }
                }

                Section("Debug") {
                    NavigationLink("Tunnel Log") {
                        TunnelLogView()
                    }
                }

                Section("About") {
                    NavigationLink("About BaoLianDeng") {
                        AboutView()
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(VPNManager.shared)
}
