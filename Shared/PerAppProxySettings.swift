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

import Foundation

enum PerAppProxyMode: String, Codable, CaseIterable {
    case allowlist
    case blocklist
}

struct PerAppEntry: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let bundlePath: String
}

struct PerAppProxySettings: Codable {
    var enabled: Bool = false
    var mode: PerAppProxyMode = .blocklist
    var apps: [PerAppEntry] = []

    /// Returns true if traffic from the given bundle ID should be proxied.
    func shouldProxy(bundleID: String, knownBundleIDs: Set<String>) -> Bool {
        guard enabled else { return true }
        let isInList = knownBundleIDs.contains(bundleID)
        switch mode {
        case .allowlist:
            return isInList
        case .blocklist:
            return !isInList
        }
    }
}
