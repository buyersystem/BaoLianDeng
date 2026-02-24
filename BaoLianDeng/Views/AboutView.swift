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

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 60))
                            .foregroundStyle(.blue)
                        Text("BaoLianDeng")
                            .font(.title2.bold())
                        Text("Global Proxy powered by Mihomo")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            }

            Section("Information") {
                InfoRow(title: "Version", value: Bundle.main.appVersion)
                InfoRow(title: "Build", value: Bundle.main.buildNumber)
            }

            Section("Links") {
                Link(destination: URL(string: "https://github.com/madeye/BaoLianDeng")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://wiki.metacubex.one")!) {
                    Label("Mihomo Documentation", systemImage: "book")
                }
            }

            Section("License") {
                Text("Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>")
                    .font(.caption)
                Link(destination: URL(string: "https://github.com/madeye/BaoLianDeng/blob/main/LICENSE")!) {
                    Label("MIT License", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("About")
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
