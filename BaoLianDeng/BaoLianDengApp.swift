// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import SwiftUI

@main
struct BaoLianDengApp: App {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var trafficStore = TrafficStore.shared

    init() {
        ConfigManager.shared.sanitizeConfig()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }

                ConfigEditorView()
                    .tabItem {
                        Label("Config", systemImage: "doc.text.fill")
                    }

                TrafficView()
                    .tabItem {
                        Label("Data", systemImage: "chart.bar.fill")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
            }
            .environmentObject(vpnManager)
            .environmentObject(trafficStore)
        }
    }
}
