// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import Foundation

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
                NSLog("[ConfigManager] Failed to download \(filename): \(error)")
            }
        }
    }

    /// Merge subscription YAML: only take proxies/groups/providers, keep local rules.
    private func mergeSubscription(_ yaml: String, selectedNode: String? = nil) -> String {
        let wantedSections = ["proxies", "proxy-groups", "proxy-providers"]
        var extracted: [String: String] = [:]
        var currentKey: String? = nil
        var currentLines: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            extracted[key] = currentLines.joined(separator: "\n")
        }

        for line in yaml.components(separatedBy: "\n") {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.isEmpty
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

        // Split local config into header (up to proxies:) and rules (from rules: onward)
        let base = defaultConfig()
        let baseLines = base.components(separatedBy: "\n")
        let proxiesCut = baseLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:") }) ?? baseLines.count
        let rulesCut = baseLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rules:") }) ?? baseLines.count

        let header = baseLines[0..<proxiesCut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let rulesSection = baseLines[rulesCut...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var result = header
        result += "\n\n" + (extracted["proxies"] ?? "proxies: []")

        // Find the first usable proxy group name from subscription
        var firstGroupName: String?
        if let pgYAML = extracted["proxy-groups"] {
            for line in pgYAML.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("name:") {
                    let name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !name.isEmpty && name != "DIRECT" && name != "REJECT" {
                        firstGroupName = name
                        break
                    }
                }
            }
        }

        // Inject a PROXY selector so local rules referencing "PROXY" resolve correctly.
        // When a specific node is selected, use only that node; otherwise fall back to
        // the subscription's first group.
        var proxyGroupBlock = "proxy-groups:\n"
        proxyGroupBlock += "  - name: PROXY\n"
        proxyGroupBlock += "    type: select\n"
        proxyGroupBlock += "    proxies:\n"
        if let node = selectedNode, !node.isEmpty {
            proxyGroupBlock += "      - \(node)\n"
        } else if let name = firstGroupName {
            proxyGroupBlock += "      - \(name)\n"
        }
        proxyGroupBlock += "      - DIRECT"
        result += "\n\n" + proxyGroupBlock

        // Append subscription's proxy-groups after the PROXY group
        if let pgYAML = extracted["proxy-groups"] {
            // Strip the "proxy-groups:" header and append the group entries
            let pgLines = pgYAML.components(separatedBy: "\n")
            let entries = pgLines.dropFirst().joined(separator: "\n")
            if !entries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += "\n" + entries
            }
        }

        if let proxyProviders = extracted["proxy-providers"] {
            result += "\n\n" + proxyProviders
        }

        // Append local rules (always from local config, never from subscription)
        result += "\n\n" + rulesSection

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
          dns-hijack:
            - \(AppConstants.tunDNS):53
          auto-route: false
          auto-detect-interface: false

        geo-auto-update: false

        dns:
          enable: true
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
