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
