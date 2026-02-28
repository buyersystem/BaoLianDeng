import XCTest
import Yams
@testable import BaoLianDeng

final class ConfigMergeTests: XCTestCase {

    // MARK: - Helpers

    /// A minimal default config matching the structure of ConfigManager.defaultConfig()
    private let defaultConfig = """
        mixed-port: 7890
        mode: rule
        log-level: info

        dns:
          enable: true
          nameserver:
            - https://dns.alidns.com/dns-query

        proxies: []

        proxy-groups:
          - name: PROXY
            type: select
            proxies: []

        rules:
          - DOMAIN-SUFFIX,google.com,PROXY
          - DOMAIN-SUFFIX,twitter.com,PROXY
          - DOMAIN-SUFFIX,cn,DIRECT
          - GEOIP,CN,DIRECT
          - MATCH,PROXY
        """

    /// A subscription that has proxies and proxy-groups but NO rules
    private let subscriptionNoRules = """
        port: 7890
        proxies:
          - name: HK-Node
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: aes-256-gcm
            password: test123
        proxy-groups:
          - name: AutoSelect
            type: url-test
            proxies:
              - HK-Node
            url: http://www.gstatic.com/generate_204
            interval: 300
        """

    /// A subscription that has proxies, proxy-groups, AND rules
    private let subscriptionWithRules = """
        port: 7890
        proxies:
          - name: US-Node
            type: ss
            server: 5.6.7.8
            port: 443
            cipher: aes-256-gcm
            password: test456
        proxy-groups:
          - name: AutoSelect
            type: url-test
            proxies:
              - US-Node
            url: http://www.gstatic.com/generate_204
            interval: 300
        rules:
          - DOMAIN-SUFFIX,netflix.com,AutoSelect
          - DOMAIN-SUFFIX,youtube.com,AutoSelect
          - MATCH,DIRECT
        """

    // MARK: - Tests

    func testMergeWithNoRulesUsesDefaultRules() {
        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        // Should contain default rules
        XCTAssertTrue(result.contains("rules:"), "Merged config must contain a rules: section")
        XCTAssertTrue(result.contains("DOMAIN-SUFFIX,google.com,PROXY"), "Must contain default rule for google.com")
        XCTAssertTrue(result.contains("DOMAIN-SUFFIX,twitter.com,PROXY"), "Must contain default rule for twitter.com")
        XCTAssertTrue(result.contains("MATCH,PROXY"), "Must contain MATCH,PROXY catch-all")

        // Parse rules to verify they're valid
        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 5, "Should have all 5 default rules")
        XCTAssertEqual(rules.first?.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules.first?.value, "google.com")
        XCTAssertEqual(rules.first?.target, "PROXY")
        XCTAssertEqual(rules.last?.type, "MATCH")
        XCTAssertEqual(rules.last?.target, "PROXY")
    }

    func testMergeWithRulesUsesSubscriptionRules() {
        let result = ConfigManager.mergeSubscription(
            subscriptionWithRules,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        // Should contain subscription rules, NOT default rules
        XCTAssertTrue(result.contains("DOMAIN-SUFFIX,netflix.com,AutoSelect"), "Must contain subscription rule for netflix")
        XCTAssertTrue(result.contains("DOMAIN-SUFFIX,youtube.com,AutoSelect"), "Must contain subscription rule for youtube")
        XCTAssertTrue(result.contains("MATCH,DIRECT"), "Must contain subscription catch-all MATCH,DIRECT")

        // Should NOT contain default-only rules
        XCTAssertFalse(result.contains("DOMAIN-SUFFIX,twitter.com,PROXY"), "Must NOT contain default rule when subscription provides rules")

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 3, "Should have 3 subscription rules")
    }

    func testMergeProxyGroupContainsAllNodes() {
        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        // First group should be PROXY with all proxy nodes + DIRECT
        XCTAssertGreaterThanOrEqual(groups.count, 1, "Must have at least one proxy group")
        let proxyGroup = groups.first!
        XCTAssertEqual(proxyGroup.name, "PROXY")
        XCTAssertTrue(proxyGroup.proxies.contains("HK-Node"), "PROXY group must contain HK-Node")
        XCTAssertTrue(proxyGroup.proxies.contains("DIRECT"), "PROXY group must contain DIRECT fallback")
    }

    func testMergeWithCorruptedBaseConfig() {
        // Simulate a corrupted base config that lost its rules section
        let corruptedBase = """
            mixed-port: 7890
            mode: rule

            dns:
              enable: true

            proxies: []

            proxy-groups:
              - name: PROXY
                type: select
                proxies: []
            """

        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            baseConfig: corruptedBase,
            defaultConfig: defaultConfig
        )

        // Even with corrupted base, should still get default rules
        XCTAssertTrue(result.contains("rules:"), "Must have rules section even with corrupted base")
        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 5, "Should have all 5 default rules from defaultConfig")
        XCTAssertEqual(rules.first?.value, "google.com")
    }

    func testMergePreservesHeaderFromBase() {
        // Base config with custom port
        let customBase = """
            mixed-port: 9999
            mode: global
            log-level: debug

            proxies: []

            proxy-groups:
              - name: PROXY
                type: select
                proxies: []

            rules:
              - MATCH,DIRECT
            """

        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            baseConfig: customBase,
            defaultConfig: defaultConfig
        )

        // Header should come from customBase
        XCTAssertTrue(result.contains("mixed-port: 9999"), "Must preserve custom port from base")
        XCTAssertTrue(result.contains("mode: global"), "Must preserve custom mode from base")
    }

    func testMergeWithCRLFLineEndings() {
        let crlfSubscription = subscriptionNoRules.replacingOccurrences(of: "\n", with: "\r\n")

        let result = ConfigManager.mergeSubscription(
            crlfSubscription,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        XCTAssertTrue(result.contains("rules:"), "Must have rules with CRLF input")
        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 5, "Should parse all default rules with CRLF input")

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        XCTAssertTrue(groups.first?.proxies.contains("HK-Node") == true, "Must have HK-Node with CRLF input")
    }

    func testDefaultConfigRulesAreParseable() {
        // Verify that parseRules can actually parse the default config
        let rules = ConfigManager.shared.parseRules(from: defaultConfig)
        XCTAssertEqual(rules.count, 5, "Default config should have 5 parseable rules")
    }

    func testRealDefaultConfigRulesAreParseable() {
        // Verify the ACTUAL defaultConfig() from ConfigManager
        let realDefault = ConfigManager.shared.defaultConfig()
        let rules = ConfigManager.shared.parseRules(from: realDefault)
        XCTAssertGreaterThan(rules.count, 0, "Real defaultConfig() must produce parseable rules, got 0")
        // Check a known rule
        let googleRule = rules.first(where: { $0.value == "google.com" })
        XCTAssertNotNil(googleRule, "Must contain google.com rule")
        XCTAssertEqual(googleRule?.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(googleRule?.target, "PROXY")
    }

    func testRealDefaultConfigMergeProducesRules() {
        // End-to-end: use the REAL defaultConfig() as both base and default
        let realDefault = ConfigManager.shared.defaultConfig()
        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            baseConfig: realDefault,
            defaultConfig: realDefault
        )

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertGreaterThan(rules.count, 0, "Merge with real defaultConfig must produce rules, got 0. Result tail: \(String(result.suffix(300)))")
    }

    func testMergeProxyGroupContainsAllMultipleNodes() {
        // PROXY group should contain ALL proxy nodes so the REST API can select any.
        let subscriptionMultiNode = """
            port: 7890
            proxies:
              - name: HK-Node
                type: ss
                server: 1.2.3.4
                port: 443
                cipher: aes-256-gcm
                password: test123
              - name: JP-Node
                type: ss
                server: 5.6.7.8
                port: 443
                cipher: aes-256-gcm
                password: test456
              - name: US-Node
                type: ss
                server: 9.10.11.12
                port: 443
                cipher: aes-256-gcm
                password: test789
            proxy-groups:
              - name: AutoSelect
                type: url-test
                proxies:
                  - HK-Node
                  - JP-Node
                  - US-Node
                url: http://www.gstatic.com/generate_204
                interval: 300
            """

        let result = ConfigManager.mergeSubscription(
            subscriptionMultiNode,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)

        // The PROXY group must contain all proxy nodes + DIRECT
        let proxyGroup = groups.first(where: { $0.name == "PROXY" })!
        XCTAssertTrue(proxyGroup.proxies.contains("HK-Node"), "PROXY group must contain HK-Node")
        XCTAssertTrue(proxyGroup.proxies.contains("JP-Node"), "PROXY group must contain JP-Node")
        XCTAssertTrue(proxyGroup.proxies.contains("US-Node"), "PROXY group must contain US-Node")
        XCTAssertTrue(proxyGroup.proxies.contains("DIRECT"), "PROXY group must contain DIRECT")
        XCTAssertEqual(proxyGroup.proxies.count, 4, "PROXY group must have 3 nodes + DIRECT")

        // The subscription group should keep all its original proxies
        let autoSelect = groups.first(where: { $0.name == "AutoSelect" })!
        XCTAssertEqual(autoSelect.proxies, ["HK-Node", "JP-Node", "US-Node"], "Subscription group must keep all original proxies")
    }

    func testParseNonIndentedRules() {
        // Subscription configs often emit rules without indentation
        let config = """
            mixed-port: 7890

            proxies: []

            proxy-groups:
              - name: PROXY
                type: select
                proxies: []

            rules:
            - DOMAIN-SUFFIX,google.com,PROXY
            - DOMAIN-SUFFIX,twitter.com,PROXY
            - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
            - GEOIP,CN,DIRECT
            - MATCH,PROXY
            """

        let rules = ConfigManager.shared.parseRules(from: config)
        XCTAssertEqual(rules.count, 5, "Must parse non-indented rules, got \(rules.count)")
        XCTAssertEqual(rules[0].type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules[0].value, "google.com")
        XCTAssertEqual(rules[0].target, "PROXY")
        XCTAssertEqual(rules[3].type, "GEOIP")
        XCTAssertEqual(rules[4].type, "MATCH")
    }

    func testParseNonIndentedRulesFromMergedConfig() {
        // Subscription with non-indented rules — merged config should preserve them
        let subscriptionNonIndentedRules = """
            port: 7890
            proxies:
              - name: JP-Node
                type: ss
                server: 9.8.7.6
                port: 443
                cipher: aes-256-gcm
                password: test789
            proxy-groups:
              - name: AutoSelect
                type: url-test
                proxies:
                  - JP-Node
            rules:
            - DOMAIN-SUFFIX,tracker.example.com,REJECT
            - DOMAIN-SUFFIX,google.com,AutoSelect
            - GEOIP,CN,DIRECT
            - MATCH,AutoSelect
            """

        let result = ConfigManager.mergeSubscription(
            subscriptionNonIndentedRules,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 4, "Must parse non-indented subscription rules from merged config, got \(rules.count)")
        XCTAssertEqual(rules[0].value, "tracker.example.com")
        XCTAssertEqual(rules[0].target, "REJECT")
    }

    // MARK: - Standalone Dash Format

    /// Subscription YAML where proxies and proxy-groups use standalone `-` on its own line
    private let subscriptionStandaloneDash = """
        port: 7890
        proxies:
          -
            name: 'HK-Node'
            type: trojan
            server: 1.2.3.4
            port: 443
            password: test123
          -
            name: 'JP-Node'
            type: trojan
            server: 5.6.7.8
            port: 443
            password: test456
        proxy-groups:
          -
            name: 'AutoSelect'
            type: url-test
            proxies:
              - HK-Node
              - JP-Node
            url: http://www.gstatic.com/generate_204
            interval: 300
          -
            name: 'Fallback'
            type: select
            proxies:
              - AutoSelect
              - DIRECT
        rules:
        - DOMAIN-SUFFIX,google.com,AutoSelect
        - MATCH,Fallback
        """

    func testExtractProxyNamesStandaloneDash() {
        let parsed = (try? Yams.load(yaml: subscriptionStandaloneDash)) as? [String: Any]
        let proxies = parsed?["proxies"] as? [[String: Any]] ?? []
        let names = ConfigManager.extractProxyNames(from: proxies)
        XCTAssertEqual(names, ["HK-Node", "JP-Node"], "Must extract proxy names from standalone dash format")
    }

    func testParseProxyGroupsStandaloneDash() {
        let result = ConfigManager.mergeSubscription(
            subscriptionStandaloneDash,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        // PROXY (injected) + AutoSelect + Fallback
        XCTAssertEqual(groups.count, 3, "Must parse 3 groups (PROXY + 2 subscription groups), got \(groups.count)")

        let proxyGroup = groups.first(where: { $0.name == "PROXY" })!
        XCTAssertTrue(proxyGroup.proxies.contains("HK-Node"), "PROXY group must contain HK-Node")
        XCTAssertTrue(proxyGroup.proxies.contains("JP-Node"), "PROXY group must contain JP-Node")

        let autoSelect = groups.first(where: { $0.name == "AutoSelect" })
        XCTAssertNotNil(autoSelect, "Must have AutoSelect group")
        XCTAssertEqual(autoSelect?.type, "url-test")
        XCTAssertEqual(autoSelect?.proxies, ["HK-Node", "JP-Node"])

        let fallback = groups.first(where: { $0.name == "Fallback" })
        XCTAssertNotNil(fallback, "Must have Fallback group")
        XCTAssertEqual(fallback?.proxies, ["AutoSelect", "DIRECT"])
    }

    func testMergeStandaloneDashRules() {
        let result = ConfigManager.mergeSubscription(
            subscriptionStandaloneDash,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].value, "google.com")
        XCTAssertEqual(rules[0].target, "AutoSelect")
        XCTAssertEqual(rules[1].type, "MATCH")
        XCTAssertEqual(rules[1].target, "Fallback")
    }

    // MARK: - Flow Style Format

    func testParseFlowStyleProxyGroups() {
        // Yams handles flow-style mappings that broke the old line-by-line parser
        let flowConfig = """
            mixed-port: 7890
            proxies:
              - {name: Node1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-256-gcm, password: test}
            proxy-groups:
              - {name: PROXY, type: select, proxies: [Node1, DIRECT]}
              - {name: Auto, type: url-test, proxies: [Node1], url: "http://www.gstatic.com/generate_204", interval: 300}
            rules:
              - MATCH,PROXY
            """

        let groups = ConfigManager.shared.parseProxyGroups(from: flowConfig)
        XCTAssertEqual(groups.count, 2, "Must parse flow-style proxy groups")
        XCTAssertEqual(groups[0].name, "PROXY")
        XCTAssertEqual(groups[0].type, "select")
        XCTAssertEqual(groups[0].proxies, ["Node1", "DIRECT"])
        XCTAssertEqual(groups[1].name, "Auto")
        XCTAssertEqual(groups[1].type, "url-test")
        XCTAssertEqual(groups[1].proxies, ["Node1"])
        XCTAssertEqual(groups[1].url, "http://www.gstatic.com/generate_204")
        XCTAssertEqual(groups[1].interval, 300)

        let rules = ConfigManager.shared.parseRules(from: flowConfig)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].type, "MATCH")
        XCTAssertEqual(rules[0].target, "PROXY")
    }
}
