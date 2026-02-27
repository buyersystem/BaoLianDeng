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
import MihomoCore
import os

final class ConfigManager {
    static let shared = ConfigManager()

    private let fileManager = FileManager.default

    private init() {}

    var sharedContainerURL: URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier)
    }

    var configDirectoryURL: URL? {
        sharedContainerURL?.appendingPathComponent("mihomo", isDirectory: true)
    }

    var configFileURL: URL? {
        configDirectoryURL?.appendingPathComponent(AppConstants.configFileName)
    }

    func ensureConfigDirectory() throws {
        guard let dirURL = configDirectoryURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        if !fileManager.fileExists(atPath: dirURL.path) {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
    }

    func saveConfig(_ yaml: String) throws {
        try ensureConfigDirectory()
        guard let fileURL = configFileURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func loadConfig() throws -> String {
        guard let fileURL = configFileURL else {
            throw ConfigError.sharedContainerUnavailable
        }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func configExists() -> Bool {
        guard let fileURL = configFileURL else { return false }
        return fileManager.fileExists(atPath: fileURL.path)
    }

    /// Save the desired mode to UserDefaults. The tunnel reads this on startup.
    func setMode(_ mode: String) {
        UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.set(mode, forKey: "proxyMode")
    }

    /// Apply the saved log level to config.yaml so Mihomo's engine uses it on startup.
    func applyLogLevel() {
        let level = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: "logLevel") ?? "info"
        guard var config = try? loadConfig() else { return }
        let levels = ["debug", "info", "warning", "error", "silent"]
        for l in levels {
            config = config.replacingOccurrences(of: "log-level: \(l)", with: "log-level: \(level)")
        }
        try? saveConfig(config)
    }

    /// Apply the saved mode to config.yaml. Call after applySelectedSubscription/sanitizeConfig.
    func applyMode() {
        let mode = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: "proxyMode") ?? "rule"
        guard var config = try? loadConfig() else { return }
        let modes = ["rule", "global", "direct"]
        for m in modes {
            config = config.replacingOccurrences(of: "mode: \(m)", with: "mode: \(mode)")
        }
        config = updateGlobalProxyGroup(config, enabled: mode == "global")
        try? saveConfig(config)
    }

    /// Add or remove a GLOBAL proxy group with the selected node.
    /// Mihomo's `mode: global` routes all traffic through the built-in GLOBAL selector,
    /// so we need to define it with the user's selected proxy node.
    func updateGlobalProxyGroup(_ yaml: String, enabled: Bool) -> String {
        // First, strip any existing GLOBAL group
        var lines = yaml.components(separatedBy: "\n")
        if let pgIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy-groups:")
        }) {
            var i = pgIdx + 1
            while i < lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed == "- name: GLOBAL" {
                    // Remove this group entry until the next group or end of section
                    let start = i
                    i += 1
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        let isTopLevel = !lines[i].hasPrefix(" ") && !lines[i].hasPrefix("\t") && !t.isEmpty
                        if isTopLevel || t.hasPrefix("- name:") { break }
                        i += 1
                    }
                    lines.removeSubrange(start..<i)
                    break
                }
                let isTopLevel = !lines[i].hasPrefix(" ") && !lines[i].hasPrefix("\t") && !trimmed.isEmpty
                if isTopLevel { break }
                i += 1
            }
        }

        guard enabled else { return lines.joined(separator: "\n") }

        // Read selected node from shared UserDefaults
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        let selectedNode = defaults?.string(forKey: "selectedNode")

        // Find proxy-groups: line and insert GLOBAL group right after it
        guard let pgIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy-groups:")
        }) else { return lines.joined(separator: "\n") }

        var globalGroup = [
            "  - name: GLOBAL",
            "    type: select",
            "    proxies:",
        ]
        if let node = selectedNode, !node.isEmpty {
            globalGroup.append("      - \(node)")
        } else {
            globalGroup.append("      - DIRECT")
        }

        lines.insert(contentsOf: globalGroup, at: pgIdx + 1)
        return lines.joined(separator: "\n")
    }

    /// Patch the on-disk config.yaml to disable geo data downloads, which would
    /// block the Network Extension during startup. Safe to call on every launch.
    func sanitizeConfig() {
        guard let yaml = try? loadConfig() else { return }
        var lines = yaml.components(separatedBy: "\n")
        var hasGeoAutoUpdate = false

        lines = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Disable automatic geo database updates
            if trimmed.hasPrefix("geo-auto-update:") {
                hasGeoAutoUpdate = true
                return line.replacingOccurrences(of: "geo-auto-update: true", with: "geo-auto-update: false")
            }
            // Fix DNS listen address: 198.18.0.2 is in the TUN subnet but not a local
            // interface address, so bind() fails. Use localhost instead.
            if trimmed.hasPrefix("listen:") && trimmed.contains("198.18.0.2") {
                return line.replacingOccurrences(of: "198.18.0.2:53", with: "127.0.0.1:1053")
            }
            // Switch TUN stack from system to gvisor for reliable TCP on iOS
            if trimmed == "stack: system" {
                return line.replacingOccurrences(of: "stack: system", with: "stack: gvisor")
            }
            // Replace blocked foreign DNS fallback servers with China-local ones
            if trimmed == "- https://1.1.1.1/dns-query" {
                return line.replacingOccurrences(of: "https://1.1.1.1/dns-query", with: "https://doh.pub/dns-query")
            }
            if trimmed == "- https://dns.google/dns-query" {
                return line.replacingOccurrences(of: "https://dns.google/dns-query", with: "https://dns.alidns.com/dns-query")
            }
            return line
        }

        // Inject geo-auto-update: false after the tun block if not already present
        if !hasGeoAutoUpdate {
            if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("dns:") }) {
                lines.insert("geo-auto-update: false", at: idx)
                lines.insert("", at: idx)
            }
        }

        try? saveConfig(lines.joined(separator: "\n"))
    }

    /// Merge a Clash subscription YAML into our base config.
    /// Keeps our TUN/DNS/port settings and local rules; takes only proxies and proxy-groups from the subscription.
    func applySubscriptionConfig(_ subscriptionYAML: String, selectedNode: String? = nil) throws {
        let node = selectedNode ?? UserDefaults(suiteName: AppConstants.appGroupIdentifier)?.string(forKey: "selectedNode")
        try saveConfig(mergeSubscription(subscriptionYAML, selectedNode: node))
    }

    /// Re-apply the currently selected subscription's config from shared UserDefaults.
    /// Safe to call from the Network Extension — reads the subscription list stored by the main app,
    /// finds the selected one, and merges its rawContent into config.yaml.
    /// Returns true if a subscription was applied, false if none selected or no rawContent.
    @discardableResult
    func applySelectedSubscription() -> Bool {
        let defaults = UserDefaults(suiteName: AppConstants.appGroupIdentifier)
        guard let idString = defaults?.string(forKey: "selectedSubscriptionID"),
              let data = defaults?.data(forKey: "subscriptions") else {
            return false
        }
        // Decode just the fields we need — avoids coupling to the full Subscription type
        struct Sub: Decodable {
            var id: UUID
            var rawContent: String?
        }
        guard let subs = try? JSONDecoder().decode([Sub].self, from: data),
              let selectedID = UUID(uuidString: idString),
              let selected = subs.first(where: { $0.id == selectedID }),
              let raw = selected.rawContent else {
            return false
        }
        do {
            try applySubscriptionConfig(raw)
            return true
        } catch {
            return false
        }
    }

    /// Download GeoIP/GeoSite databases to the config directory if they don't already exist.
    /// These are required for GEOIP and GEOSITE rules in subscription configs.
    func downloadGeoDataIfNeeded() async {
        guard let configDir = configDirectoryURL else { return }

        let files: [(String, String)] = [
            ("geoip.metadb", "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb"),
            ("geosite.dat", "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"),
        ]

        for (filename, urlString) in files {
            let fileURL = configDir.appendingPathComponent(filename)
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            guard let url = URL(string: urlString) else { continue }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: fileURL)
            } catch {
                AppLogger.config.error("Failed to download \(filename, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Validate a subscription YAML by merging it with the base config and running Mihomo's parser.
    /// Returns nil if valid, or an error message string if invalid.
    func validateSubscriptionConfig(_ yaml: String) -> String? {
        // Ensure Mihomo's home directory is set so it can find geoip.metadb / geosite.dat
        if let configDir = configDirectoryURL?.path {
            BridgeSetHomeDir(configDir)
            AppLogger.config.debug("validateSubscriptionConfig: homeDir=\(configDir, privacy: .public)")
            // Check if geo files exist
            let geoipPath = configDir + "/geoip.metadb"
            let geositePath = configDir + "/geosite.dat"
            AppLogger.config.debug("geoip.metadb exists: \(self.fileManager.fileExists(atPath: geoipPath)), geosite.dat exists: \(self.fileManager.fileExists(atPath: geositePath))")
        }
        let merged = mergeSubscription(yaml)
        AppLogger.config.debug("merged config length: \(merged.count), preview: \(String(merged.prefix(300)), privacy: .public)")
        var err: NSError?
        BridgeValidateConfig(merged, &err)
        if let err = err {
            AppLogger.config.error("BridgeValidateConfig error: \(err.localizedDescription, privacy: .public)")
        } else {
            AppLogger.config.info("BridgeValidateConfig: OK")
        }
        return err?.localizedDescription
    }

    /// Write the merged config and error to a debug file for troubleshooting.
    func dumpDebugMergedConfig(_ subscriptionYAML: String, error: String) {
        guard let dir = sharedContainerURL else { return }
        let merged = mergeSubscription(subscriptionYAML)
        let debug = """
        === VALIDATION ERROR ===
        \(error)

        === MERGED CONFIG ===
        \(merged)

        === RAW SUBSCRIPTION (first 2000 chars) ===
        \(String(subscriptionYAML.prefix(2000)))
        """
        let debugURL = dir.appendingPathComponent("debug_merged_config.txt")
        try? debug.write(to: debugURL, atomically: true, encoding: .utf8)
        AppLogger.config.debug("Debug merged config written to \(debugURL.path, privacy: .public)")
    }

    /// Merge subscription YAML: take proxies, proxy-groups, rules, and their providers from subscription.
    private func mergeSubscription(_ yaml: String, selectedNode: String? = nil) -> String {
        let base = (try? loadConfig()) ?? defaultConfig()
        return ConfigManager.mergeSubscription(yaml, selectedNode: selectedNode, baseConfig: base, defaultConfig: defaultConfig())
    }

    /// Pure merge logic — takes all inputs as parameters for testability.
    static func mergeSubscription(_ yaml: String, selectedNode: String? = nil, baseConfig: String, defaultConfig: String) -> String {
        let wantedSections = ["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers"]
        var extracted: [String: String] = [:]
        var currentKey: String? = nil
        var currentLines: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            extracted[key] = currentLines.joined(separator: "\n")
        }

        // Normalize line endings: CRLF (\r\n) or bare CR (\r) → LF (\n).
        let normalized = yaml
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalized.components(separatedBy: "\n") {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.isEmpty && !line.hasPrefix("-") && !line.hasPrefix("#")
            if isTopLevel {
                flush()
                let key = String(line.prefix(while: { $0 != ":" }))
                    .trimmingCharacters(in: .whitespaces)
                currentKey = wantedSections.contains(key) ? key : nil
                currentLines = [line]
            } else if currentKey != nil {
                currentLines.append(line)
            }
        }
        flush()

        // Header comes from base config (preserves user edits to ports, DNS, etc.);
        // default rules always come from defaultConfig so they can never be lost.
        // IMPORTANT: Only match top-level (non-indented) YAML keys to avoid matching
        // "proxies:" or "rules:" nested inside proxy-group definitions.
        let baseLines = baseConfig.components(separatedBy: "\n")
        let proxiesCut = baseLines.firstIndex(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("proxies:") }) ?? baseLines.count
        let header = baseLines[0..<proxiesCut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let defaultLines = defaultConfig.components(separatedBy: "\n")
        let defaultRulesCut = defaultLines.firstIndex(where: { !$0.hasPrefix(" ") && !$0.hasPrefix("\t") && $0.hasPrefix("rules:") }) ?? defaultLines.count
        let defaultRulesSection = defaultLines[defaultRulesCut...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var result = header
        result += "\n\n" + (extracted["proxies"] ?? "proxies: []")

        // Find the first usable proxy group name from subscription.
        var firstGroupName: String?
        if let pgYAML = extracted["proxy-groups"] {
            for line in pgYAML.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let nameValue: String?
                if trimmed.hasPrefix("- name:") {
                    nameValue = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else if trimmed.hasPrefix("name:") {
                    nameValue = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                } else {
                    nameValue = nil
                }
                if let name = nameValue, !name.isEmpty, name != "DIRECT", name != "REJECT" {
                    firstGroupName = name
                    break
                }
            }
        }

        // Inject a PROXY selector so local rules referencing "PROXY" resolve correctly.
        // When a node is selected, it is the exclusive proxy in this group (no DIRECT fallback)
        // so that all traffic routed through the default group goes through the selected node.
        var proxyGroupBlock = "proxy-groups:\n"
        proxyGroupBlock += "  - name: PROXY\n"
        proxyGroupBlock += "    type: select\n"
        proxyGroupBlock += "    proxies:\n"
        if let node = selectedNode, !node.isEmpty {
            proxyGroupBlock += "      - \(node)"
        } else if let name = firstGroupName {
            proxyGroupBlock += "      - \(name)\n"
            proxyGroupBlock += "      - DIRECT"
        } else {
            proxyGroupBlock += "      - DIRECT"
        }
        result += "\n\n" + proxyGroupBlock

        // Append subscription's proxy-groups after the PROXY group,
        // replacing the first group's proxies with only the selected node.
        if let pgYAML = extracted["proxy-groups"] {
            var pgLines = Array(pgYAML.components(separatedBy: "\n").dropFirst())
            if let node = selectedNode, !node.isEmpty {
                var firstGroupFound = false
                var inProxies = false
                var removeStart = -1
                var removeEnd = -1
                for i in 0..<pgLines.count {
                    let trimmed = pgLines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- name:") {
                        if firstGroupFound { if inProxies { removeEnd = i }; break }
                        firstGroupFound = true
                        continue
                    }
                    guard firstGroupFound else { continue }
                    if !inProxies && trimmed.hasPrefix("proxies:") {
                        inProxies = true
                        removeStart = i
                        if trimmed != "proxies:" { continue }
                        continue
                    }
                    if inProxies {
                        if !trimmed.hasPrefix("- ") || trimmed.hasPrefix("- name:") {
                            removeEnd = i; break
                        }
                    }
                }
                if removeStart >= 0 {
                    if removeEnd < 0 { removeEnd = pgLines.count }
                    pgLines.replaceSubrange(removeStart..<removeEnd, with: [
                        "    proxies:", "      - \(node)",
                    ])
                }
            }
            let entries = pgLines.joined(separator: "\n")
            if !entries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "\n" + entries
            }
        }

        if let proxyProviders = extracted["proxy-providers"] {
            result += "\n\n" + proxyProviders
        }

        if let ruleProviders = extracted["rule-providers"] {
            result += "\n\n" + ruleProviders
        }

        // Use subscription rules if available, otherwise always use default rules.
        if let subRules = extracted["rules"] {
            result += "\n\n" + subRules
        } else {
            result += "\n\n" + defaultRulesSection
        }

        return result
    }

    func defaultConfig() -> String {
        return """
        mixed-port: 7890
        mode: rule
        log-level: info
        allow-lan: false
        external-controller: \(AppConstants.externalControllerAddr)

        tun:
          enable: true
          stack: gvisor
          inet6-address: [fdfe:dcba:9876::1/126]
          dns-hijack:
            - \(AppConstants.tunDNS):53
          auto-route: false
          auto-detect-interface: false

        geo-auto-update: false

        dns:
          enable: true
          ipv6: true
          listen: 127.0.0.1:1053
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
            - https://dns.alidns.com/dns-query
            - https://doh.pub/dns-query
          fallback:
            - https://doh.pub/dns-query
            - https://dns.alidns.com/dns-query
            - 114.114.114.114
            - 223.5.5.5
          fallback-filter:
            geoip: false

        proxies: []

        proxy-groups:
          - name: PROXY
            type: select
            proxies: []

        rules:
          # Google
          - DOMAIN-SUFFIX,google.com,PROXY
          - DOMAIN-SUFFIX,google.com.hk,PROXY
          - DOMAIN-SUFFIX,googleapis.com,PROXY
          - DOMAIN-SUFFIX,googlevideo.com,PROXY
          - DOMAIN-SUFFIX,gstatic.com,PROXY
          - DOMAIN-SUFFIX,ggpht.com,PROXY
          - DOMAIN-SUFFIX,googleusercontent.com,PROXY
          - DOMAIN-SUFFIX,gmail.com,PROXY
          # YouTube
          - DOMAIN-SUFFIX,youtube.com,PROXY
          - DOMAIN-SUFFIX,ytimg.com,PROXY
          - DOMAIN-SUFFIX,youtu.be,PROXY
          # Twitter / X
          - DOMAIN-SUFFIX,twitter.com,PROXY
          - DOMAIN-SUFFIX,x.com,PROXY
          - DOMAIN-SUFFIX,twimg.com,PROXY
          - DOMAIN-SUFFIX,t.co,PROXY
          # Telegram
          - DOMAIN-SUFFIX,telegram.org,PROXY
          - DOMAIN-SUFFIX,t.me,PROXY
          - IP-CIDR,91.108.0.0/16,PROXY,no-resolve
          - IP-CIDR,149.154.0.0/16,PROXY,no-resolve
          # Meta
          - DOMAIN-SUFFIX,facebook.com,PROXY
          - DOMAIN-SUFFIX,fbcdn.net,PROXY
          - DOMAIN-SUFFIX,instagram.com,PROXY
          - DOMAIN-SUFFIX,whatsapp.com,PROXY
          - DOMAIN-SUFFIX,whatsapp.net,PROXY
          # GitHub
          - DOMAIN-SUFFIX,github.com,PROXY
          - DOMAIN-SUFFIX,githubusercontent.com,PROXY
          - DOMAIN-SUFFIX,github.io,PROXY
          # Wikipedia / Reddit
          - DOMAIN-SUFFIX,wikipedia.org,PROXY
          - DOMAIN-SUFFIX,reddit.com,PROXY
          - DOMAIN-SUFFIX,redd.it,PROXY
          # AI services
          - DOMAIN-SUFFIX,openai.com,PROXY
          - DOMAIN-SUFFIX,anthropic.com,PROXY
          - DOMAIN-SUFFIX,claude.ai,PROXY
          - DOMAIN-SUFFIX,chatgpt.com,PROXY
          # CDN / Media
          - DOMAIN-SUFFIX,amazonaws.com,PROXY
          - DOMAIN-SUFFIX,cloudfront.net,PROXY
          # Apple (direct in China)
          - DOMAIN-SUFFIX,apple.com,DIRECT
          - DOMAIN-SUFFIX,icloud.com,DIRECT
          - DOMAIN-SUFFIX,icloud-content.com,DIRECT
          # China direct
          - DOMAIN-SUFFIX,cn,DIRECT
          - DOMAIN-SUFFIX,baidu.com,DIRECT
          - DOMAIN-SUFFIX,qq.com,DIRECT
          - DOMAIN-SUFFIX,taobao.com,DIRECT
          - DOMAIN-SUFFIX,jd.com,DIRECT
          - DOMAIN-SUFFIX,bilibili.com,DIRECT
          - DOMAIN-SUFFIX,zhihu.com,DIRECT
          # LAN
          - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
          - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
          - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
          # GeoIP China
          - GEOIP,CN,DIRECT
          # Catch-all
          - MATCH,PROXY
        """
    }
}

// MARK: - Editable Config Models

struct EditableProxyGroup: Identifiable {
    var id = UUID()
    var name: String
    var type: String
    var proxies: [String]
    var url: String?
    var interval: Int?
}

struct EditableRule: Identifiable {
    var id = UUID()
    var type: String
    var value: String
    var target: String
    var noResolve: Bool
}

// MARK: - Config Parsing & Update

extension ConfigManager {

    func parseProxyGroups(from yaml: String) -> [EditableProxyGroup] {
        let lines = yaml.components(separatedBy: "\n")
        var groups: [EditableProxyGroup] = []
        var inSection = false
        var name = ""
        var type = ""
        var proxies: [String] = []
        var url: String?
        var interval: Int?
        var inProxies = false
        var hasGroup = false

        func flushGroup() {
            if hasGroup && !name.isEmpty {
                groups.append(EditableProxyGroup(name: name, type: type, proxies: proxies, url: url, interval: interval))
            }
            name = ""; type = ""; proxies = []; url = nil; interval = nil
            inProxies = false; hasGroup = false
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty {
                if trimmed.hasPrefix("proxy-groups:") {
                    inSection = true
                    if trimmed == "proxy-groups: []" { return [] }
                    continue
                } else if inSection {
                    flushGroup()
                    inSection = false
                    continue
                }
            }

            guard inSection else { continue }

            if trimmed.hasPrefix("- name:") {
                flushGroup()
                name = stripQuotes(String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces))
                hasGroup = true
                inProxies = false
            } else if hasGroup && trimmed.hasPrefix("type:") {
                type = stripQuotes(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if hasGroup && trimmed.hasPrefix("url:") && !trimmed.hasPrefix("url-") {
                url = stripQuotes(String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces))
            } else if hasGroup && trimmed.hasPrefix("interval:") {
                interval = Int(trimmed.dropFirst(9).trimmingCharacters(in: .whitespaces))
            } else if hasGroup && trimmed == "proxies:" {
                inProxies = true
            } else if hasGroup && trimmed.hasPrefix("proxies:") && trimmed != "proxies:" {
                let val = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if val == "[]" { proxies = [] }
                inProxies = false
            } else if inProxies && trimmed.hasPrefix("- ") {
                proxies.append(stripQuotes(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if inProxies && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#") {
                inProxies = false
            }
        }

        flushGroup()
        return groups
    }

    func parseRules(from yaml: String) -> [EditableRule] {
        let lines = yaml.components(separatedBy: "\n")
        var rules: [EditableRule] = []
        var inRules = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect top-level YAML keys. Lines starting with "- " are list items
            // (e.g. non-indented rules from subscriptions), not section headers.
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !line.isEmpty && !line.hasPrefix("-") && !line.hasPrefix("#")
            if isTopLevel {
                if trimmed.hasPrefix("rules:") {
                    inRules = true
                    if trimmed == "rules: []" { return [] }
                    continue
                } else if inRules {
                    break
                }
            }

            guard inRules else { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard trimmed.hasPrefix("- ") else { continue }

            let ruleStr = String(trimmed.dropFirst(2))
            let parts = ruleStr.components(separatedBy: ",")
            guard parts.count >= 2 else { continue }

            let ruleType = parts[0].trimmingCharacters(in: .whitespaces)
            if ruleType == "MATCH" {
                rules.append(EditableRule(type: ruleType, value: "", target: parts[1].trimmingCharacters(in: .whitespaces), noResolve: false))
            } else if parts.count >= 3 {
                let noResolve = parts.count >= 4 && parts[3].trimmingCharacters(in: .whitespaces) == "no-resolve"
                rules.append(EditableRule(
                    type: ruleType,
                    value: parts[1].trimmingCharacters(in: .whitespaces),
                    target: parts[2].trimmingCharacters(in: .whitespaces),
                    noResolve: noResolve
                ))
            }
        }

        return rules
    }

    func updateProxyGroups(_ groups: [EditableProxyGroup], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let startIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("proxy-groups:") && !t.hasPrefix("#")
        }) else {
            let insertIdx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("rules:")
            }) ?? lines.count
            var newLines = serializeProxyGroups(groups)
            newLines.append("")
            lines.insert(contentsOf: newLines, at: insertIdx)
            return lines.joined(separator: "\n")
        }

        var endIdx = startIdx + 1
        while endIdx < lines.count {
            let line = lines[endIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                break
            }
            endIdx += 1
        }

        var newLines = serializeProxyGroups(groups)
        newLines.append("")
        lines.replaceSubrange(startIdx..<endIdx, with: newLines)
        return lines.joined(separator: "\n")
    }

    func updateRules(_ rules: [EditableRule], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")

        guard let startIdx = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("rules:") && !t.hasPrefix("#")
        }) else {
            lines.append(contentsOf: serializeRules(rules))
            return lines.joined(separator: "\n")
        }

        var endIdx = startIdx + 1
        while endIdx < lines.count {
            let line = lines[endIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && !trimmed.isEmpty
                && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("#") && line.contains(":") {
                break
            }
            endIdx += 1
        }

        let newLines = serializeRules(rules)
        lines.replaceSubrange(startIdx..<endIdx, with: newLines)
        return lines.joined(separator: "\n")
    }

    private func serializeProxyGroups(_ groups: [EditableProxyGroup]) -> [String] {
        if groups.isEmpty { return ["proxy-groups: []"] }
        var result = ["proxy-groups:"]
        for group in groups {
            result.append("  - name: \(group.name)")
            result.append("    type: \(group.type)")
            if let url = group.url, !url.isEmpty {
                result.append("    url: \(url)")
            }
            if let interval = group.interval {
                result.append("    interval: \(interval)")
            }
            if group.proxies.isEmpty {
                result.append("    proxies: []")
            } else {
                result.append("    proxies:")
                for proxy in group.proxies {
                    result.append("      - \(proxy)")
                }
            }
        }
        return result
    }

    private func serializeRules(_ rules: [EditableRule]) -> [String] {
        if rules.isEmpty { return ["rules: []"] }
        var result = ["rules:"]
        for rule in rules {
            if rule.type == "MATCH" {
                result.append("  - MATCH,\(rule.target)")
            } else {
                var line = "  - \(rule.type),\(rule.value),\(rule.target)"
                if rule.noResolve { line += ",no-resolve" }
                result.append(line)
            }
        }
        return result
    }

    private func stripQuotes(_ s: String) -> String {
        if s.count >= 2 &&
            ((s.hasPrefix("\"") && s.hasSuffix("\"")) ||
             (s.hasPrefix("'") && s.hasSuffix("'"))) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

enum ConfigError: LocalizedError {
    case sharedContainerUnavailable
    case configNotFound

    var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable:
            return "App Group shared container is not available"
        case .configNotFound:
            return "Configuration file not found"
        }
    }
}
