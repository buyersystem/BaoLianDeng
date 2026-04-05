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
import UniformTypeIdentifiers

struct PerAppProxySection: View {
    @EnvironmentObject var vpnManager: VPNManager
    @State private var settings = PerAppProxySettings()

    var body: some View {
        Section("Per-App Proxy") {
            Toggle("Enable Per-App Proxy", isOn: $settings.enabled)
                .onChange(of: settings.enabled) { save() }

            if settings.enabled {
                Picker("Mode", selection: $settings.mode) {
                    Text("Bypass Listed Apps").tag(PerAppProxyMode.blocklist)
                    Text("Proxy Only Listed Apps").tag(PerAppProxyMode.allowlist)
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.mode) { save() }

                ForEach(settings.apps) { entry in
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

                Button {
                    pickApps()
                } label: {
                    Label("Add App", systemImage: "plus.circle")
                }
            }
        }
        .onAppear { load() }
    }

    // MARK: - Persistence

    private func load() {
        let defaults = AppConstants.sharedDefaults
        guard let data = defaults.data(forKey: AppConstants.perAppProxySettingsKey),
              let decoded = try? JSONDecoder().decode(PerAppProxySettings.self, from: data) else {
            return
        }
        settings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        AppConstants.sharedDefaults.set(data, forKey: AppConstants.perAppProxySettingsKey)
        vpnManager.restartIfConnected()
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
                      let bundleID = bundle.bundleIdentifier else { continue }
                if settings.apps.contains(where: { $0.bundleID == bundleID }) { continue }
                let name = FileManager.default.displayName(atPath: url.path)
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

    // MARK: - App Icon

    private func appIcon(for entry: PerAppEntry) -> Image {
        let icon = NSWorkspace.shared.icon(forFile: entry.bundlePath)
        return Image(nsImage: icon)
    }
}
