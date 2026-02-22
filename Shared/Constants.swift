// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import Foundation

enum AppConstants {
    static let appGroupIdentifier = "group.io.github.baoliandeng"
    static let tunnelBundleIdentifier = "io.github.baoliandeng.PacketTunnel"
    static let configFileName = "config.yaml"
    static let defaultMTU = 9000
    static let tunAddress = "198.18.0.1"
    static let tunSubnetMask = "255.255.0.0"
    static let tunDNS = "198.18.0.2"
    static let externalControllerAddr = "127.0.0.1:9090"
    static let dailyTrafficKey = "dailyTrafficRecords"
}

enum ProxyMode: String, CaseIterable, Identifiable {
    case rule = "rule"
    case global = "global"
    case direct = "direct"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rule: return "Rule"
        case .global: return "Global"
        case .direct: return "Direct"
        }
    }
}
