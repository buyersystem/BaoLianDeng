import XCTest
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
            selectedNode: "HK-Node",
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
            selectedNode: "US-Node",
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

    func testMergeProxyGroupHasSelectedNode() {
        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            selectedNode: "HK-Node",
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        // First group should be PROXY with only the selected node (exclusive selection)
        XCTAssertGreaterThanOrEqual(groups.count, 1, "Must have at least one proxy group")
        let proxyGroup = groups.first!
        XCTAssertEqual(proxyGroup.name, "PROXY")
        XCTAssertTrue(proxyGroup.proxies.contains("HK-Node"), "PROXY group must contain selected node HK-Node")
        XCTAssertEqual(proxyGroup.proxies.count, 1, "PROXY group must contain only the selected node")
        XCTAssertFalse(proxyGroup.proxies.contains("DIRECT"), "PROXY group must not contain DIRECT when a node is selected")
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
            selectedNode: "HK-Node",
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
            selectedNode: "HK-Node",
            baseConfig: customBase,
            defaultConfig: defaultConfig
        )

        // Header should come from customBase
        XCTAssertTrue(result.contains("mixed-port: 9999"), "Must preserve custom port from base")
        XCTAssertTrue(result.contains("mode: global"), "Must preserve custom mode from base")
    }

    func testMergeWithNoSelectedNodeUsesFirstGroup() {
        let result = ConfigManager.mergeSubscription(
            subscriptionNoRules,
            selectedNode: nil,
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        let proxyGroup = groups.first!
        XCTAssertEqual(proxyGroup.name, "PROXY")
        // Should fall back to subscription's first group name
        XCTAssertTrue(proxyGroup.proxies.contains("AutoSelect"), "PROXY group should contain subscription's first group name")
        XCTAssertTrue(proxyGroup.proxies.contains("DIRECT"), "PROXY group must contain DIRECT")
    }

    func testMergeWithCRLFLineEndings() {
        let crlfSubscription = subscriptionNoRules.replacingOccurrences(of: "\n", with: "\r\n")

        let result = ConfigManager.mergeSubscription(
            crlfSubscription,
            selectedNode: "HK-Node",
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        XCTAssertTrue(result.contains("rules:"), "Must have rules with CRLF input")
        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 5, "Should parse all default rules with CRLF input")

        let groups = ConfigManager.shared.parseProxyGroups(from: result)
        XCTAssertTrue(groups.first?.proxies.contains("HK-Node") == true, "Must have selected node with CRLF input")
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
            selectedNode: "HK-Node",
            baseConfig: realDefault,
            defaultConfig: realDefault
        )

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertGreaterThan(rules.count, 0, "Merge with real defaultConfig must produce rules, got 0. Result tail: \(String(result.suffix(300)))")
    }

    func testMergeExclusiveNodeSelection() {
        // When a node is selected, it should be the ONLY proxy in the default proxy group.
        // No DIRECT fallback — rules handle direct traffic explicitly.
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
            selectedNode: "JP-Node",
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let groups = ConfigManager.shared.parseProxyGroups(from: result)

        // The PROXY group (default, used by MATCH rule) must contain only the selected node
        let proxyGroup = groups.first(where: { $0.name == "PROXY" })!
        XCTAssertEqual(proxyGroup.proxies, ["JP-Node"], "PROXY group must exclusively contain the selected node")

        // The first subscription group should also have only the selected node
        let autoSelect = groups.first(where: { $0.name == "AutoSelect" })!
        XCTAssertEqual(autoSelect.proxies, ["JP-Node"], "First subscription group must contain only the selected node")
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
            selectedNode: "JP-Node",
            baseConfig: defaultConfig,
            defaultConfig: defaultConfig
        )

        let rules = ConfigManager.shared.parseRules(from: result)
        XCTAssertEqual(rules.count, 4, "Must parse non-indented subscription rules from merged config, got \(rules.count)")
        XCTAssertEqual(rules[0].value, "tracker.example.com")
        XCTAssertEqual(rules[0].target, "REJECT")
    }
}
