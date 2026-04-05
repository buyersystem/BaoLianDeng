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

// MARK: - Models

struct Subscription: Identifiable, Codable {
    var id = UUID()
    var name: String
    var url: String
    var nodes: [ProxyNode]
    var rawContent: String?
    var isUpdating: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, url, nodes, rawContent
    }
}

struct ProxyNode: Identifiable, Codable {
    var id = UUID()
    var name: String
    var type: String
    var server: String
    var port: Int
    var delay: Int?

    var typeIcon: String {
        switch type.lowercased() {
        case "ss", "shadowsocks": return "lock.shield"
        case "vmess": return "v.circle"
        case "vless": return "v.circle.fill"
        case "trojan": return "bolt.shield"
        case "hysteria", "hysteria2": return "hare"
        case "wireguard": return "network.badge.shield.half.filled"
        default: return "globe"
        }
    }

    var typeColor: Color {
        switch type.lowercased() {
        case "ss", "shadowsocks": return .blue
        case "vmess": return .purple
        case "vless": return .indigo
        case "trojan": return .red
        case "hysteria", "hysteria2": return .orange
        case "wireguard": return .green
        default: return .gray
        }
    }
}

// MARK: - Add Subscription Sheet

struct AddSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var subscriptions: [Subscription]
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("Enter a subscription URL to import proxy nodes. Supported formats: Clash YAML, base64-encoded links.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addSubscription()
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }

    private func addSubscription() {
        let sub = Subscription(name: name, url: url, nodes: [])
        subscriptions.append(sub)
        let snapshot = subscriptions
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            AppConstants.sharedDefaults
                .set(data, forKey: "subscriptions")
        }
    }
}

// MARK: - Edit Subscription Sheet

struct EditSubscriptionView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: Subscription
    let onSave: (Subscription) -> Void

    @State private var name: String
    @State private var url: String

    init(subscription: Subscription, onSave: @escaping (Subscription) -> Void) {
        self.subscription = subscription
        self.onSave = onSave
        _name = State(initialValue: subscription.name)
        _url = State(initialValue: subscription.url)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subscription Info") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Edit Subscription")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = subscription
                        updated.name = name
                        updated.url = url
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

// MARK: - Reload Result

struct ReloadResult: Identifiable {
    let id = UUID()
    let succeeded: [String]
    let failed: [(String, String)]

    var message: String {
        var parts: [String] = []
        if !succeeded.isEmpty {
            parts.append("✓ \(succeeded.joined(separator: ", "))")
        }
        if !failed.isEmpty {
            let names = failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            parts.append("✗ \(names)")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Subscription Parser

enum SubscriptionParser {
    static func parse(_ text: String) -> [ProxyNode] {
        // Normalize CRLF / bare CR to LF so trailing \r doesn't break value parsing
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var nodes: [ProxyNode] = []
        var inProxies = false
        var current: [String: String] = [:]

        AppLogger.log(AppLogger.parser, category: "parser", "total lines: \(lines.count), text length: \(text.count)")

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("proxies:") {
                inProxies = true
                AppLogger.log(AppLogger.parser, category: "parser", "found 'proxies:' at line \(lineNum)")
                continue
            }
            // Top-level key ends the proxies section
            if inProxies, !line.hasPrefix(" "), !line.isEmpty, line.contains(":") {
                AppLogger.log(AppLogger.parser, category: "parser", "proxies section ended at line \(lineNum): '\(String(line.prefix(80)))'")
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                inProxies = false
                continue
            }
            guard inProxies else { continue }

            if trimmed == "-" {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
            } else if trimmed.hasPrefix("- {") && trimmed.hasSuffix("}") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                let inner = String(trimmed.dropFirst(3).dropLast())
                for pair in splitFlowMapping(inner) {
                    parseKV(pair, into: &current)
                }
            } else if trimmed.hasPrefix("- ") {
                if let node = makeNode(from: current) { nodes.append(node) }
                current = [:]
                parseKV(String(trimmed.dropFirst(2)), into: &current)
            } else {
                parseKV(trimmed, into: &current)
            }
        }
        if let node = makeNode(from: current) { nodes.append(node) }
        AppLogger.log(AppLogger.parser, category: "parser", "result: \(nodes.count) nodes parsed")
        if nodes.isEmpty {
            // Dump first few proxies-section lines for debugging
            var proxiesStart = -1
            for (i, l) in lines.enumerated() {
                if l.hasPrefix("proxies:") { proxiesStart = i; break }
            }
            if proxiesStart >= 0 {
                let end = min(proxiesStart + 10, lines.count)
                for i in proxiesStart..<end {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            } else {
                AppLogger.log(AppLogger.parser, category: "parser", "WARNING: no 'proxies:' section found in text")
                // Log first 10 lines to see what we got
                for i in 0..<min(10, lines.count) {
                    AppLogger.log(AppLogger.parser, category: "parser", "line \(i): '\(lines[i])'")
                }
            }
        }
        return nodes
    }

    private static func parseKV(_ s: String, into dict: inout [String: String]) {
        guard let idx = s.firstIndex(of: ":") else { return }
        let key = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
        var value = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        if !key.isEmpty { dict[key] = value }
    }

    /// Split a YAML flow mapping interior on commas, respecting quoted values.
    /// e.g. `name: "a, b", type: ss` → [`name: "a, b"`, `type: ss`]
    private static func splitFlowMapping(_ s: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuote: Character?
        for ch in s {
            if inQuote != nil {
                current.append(ch)
                if ch == inQuote { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }
        return parts
    }

    private static func makeNode(from dict: [String: String]) -> ProxyNode? {
        guard !dict.isEmpty else { return nil }
        guard let name = dict["name"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'name', keys=\(dict.keys.sorted().joined(separator: ","))")
            return nil
        }
        guard let type_ = dict["type"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'type' for '\(name)'")
            return nil
        }
        guard let server = dict["server"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'server' for '\(name)'")
            return nil
        }
        guard let portStr = dict["port"] else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: missing 'port' for '\(name)'")
            return nil
        }
        guard let port = Int(portStr) else {
            AppLogger.log(AppLogger.parser, category: "parser", "makeNode FAIL: invalid port '\(portStr)' for '\(name)'")
            return nil
        }
        return ProxyNode(name: name, type: type_, server: server, port: port)
    }
}
