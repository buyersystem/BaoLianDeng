// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

import NetworkExtension
import MihomoCore

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var proxyStarted = false
    private var gcTimer: DispatchSourceTimer?
    private var diagnosticTimer: DispatchSourceTimer?

    // Write log entries to shared container so the main app can read them
    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        NSLog("[BaoLianDeng] \(message)")
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else { return }
        let logURL = dir.appendingPathComponent("tunnel.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupLogging()
        // Clear old log on each tunnel start
        if let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier) {
            let logURL = dir.appendingPathComponent("tunnel.log")
            try? FileManager.default.removeItem(at: logURL)

            // Redirect Mihomo's internal Go logs to the same tunnel.log
            var logErr: NSError?
            BridgeSetLogFile(logURL.path, &logErr)
            if let logErr = logErr {
                NSLog("[BaoLianDeng] WARNING: Could not set Go log file: \(logErr)")
            }
        }
        log("startTunnel called")

        guard let configDir = configDirectory else {
            log("ERROR: config directory unavailable")
            completionHandler(PacketTunnelError.configDirectoryUnavailable)
            return
        }
        log("configDir: \(configDir)")

        // Point Mihomo to the shared config directory
        BridgeSetHomeDir(configDir)

        // Ensure config exists
        let configPath = configDir + "/config.yaml"
        guard FileManager.default.fileExists(atPath: configPath) else {
            log("ERROR: config.yaml not found at \(configPath)")
            completionHandler(PacketTunnelError.configNotFound)
            return
        }

        // Re-apply selected subscription config (in case iOS started the tunnel
        // without the main app, or config.yaml was reset to defaults)
        let applied = ConfigManager.shared.applySelectedSubscription()
        log("Subscription applied: \(applied)")

        // Sanitize subscription configs (fix stack, DNS, geo-auto-update)
        ConfigManager.shared.sanitizeConfig()
        log("Config sanitized")

        // Log config summary for debugging
        if let cfg = try? String(contentsOfFile: configPath, encoding: .utf8) {
            log("config.yaml preview: \(String(cfg.prefix(300)))")
        }

        let settings = createTunnelSettings()
        log("Setting tunnel network settings")

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.log("ERROR: setTunnelNetworkSettings failed: \(error)")
                completionHandler(error)
                return
            }

            guard let fd = self?.tunnelFileDescriptor else {
                self?.log("ERROR: could not find utun file descriptor")
                completionHandler(PacketTunnelError.tunnelFDNotFound)
                return
            }
            self?.log("Found TUN fd: \(fd)")

            var fdErr: NSError?
            BridgeSetTUNFd(Int32(fd), &fdErr)
            if let fdErr = fdErr {
                self?.log("ERROR: Failed to set TUN fd: \(fdErr)")
                completionHandler(fdErr)
                return
            }

            self?.log("Starting Mihomo proxy engine with external controller")
            var startError: NSError?
            BridgeStartWithExternalController(AppConstants.externalControllerAddr, "", &startError)
            if let startError = startError {
                self?.log("ERROR: BridgeStartWithExternalController failed: \(startError)")
                completionHandler(startError)
                return
            }

            self?.log("Proxy started successfully")
            self?.proxyStarted = true
            self?.startMemoryManagement()
            self?.startDiagnosticLogging()
            completionHandler(nil)

            // Run connectivity diagnostics in background
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                self?.log("TCP-TEST: direct TCP to www.baidu.com:80...")
                let directResult = BridgeTestDirectTCP("www.baidu.com", 80)
                self?.log("TCP-TEST direct: \(directResult ?? "nil")")

                self?.log("TCP-TEST: HTTP via proxy to http://www.baidu.com/...")
                let proxyResult = BridgeTestProxyHTTP("http://www.baidu.com/")
                self?.log("TCP-TEST proxy: \(proxyResult ?? "nil")")

                self?.log("DNS-TEST: resolving via Mihomo DNS...")
                let dnsResult = BridgeTestDNSResolver("127.0.0.1:1053")
                self?.log("DNS-TEST: \(dnsResult ?? "nil")")

                self?.log("PROXY-TEST: testing selected proxy node...")
                let proxyTestResult = BridgeTestSelectedProxy(AppConstants.externalControllerAddr)
                self?.log("PROXY-TEST: \(proxyTestResult ?? "nil")")
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        diagnosticTimer?.cancel()
        diagnosticTimer = nil
        stopMemoryManagement()
        if proxyStarted {
            BridgeStopProxy()
            proxyStarted = false
        }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let action = message["action"] as? String else {
            completionHandler?(nil)
            return
        }

        switch action {
        case "switch_mode":
            if let mode = message["mode"] as? String {
                handleSwitchMode(mode)
            }
            completionHandler?(responseData(["status": "ok"]))

        case "get_traffic":
            let up = BridgeGetUploadTraffic()
            let down = BridgeGetDownloadTraffic()
            completionHandler?(responseData([
                "upload": up,
                "download": down
            ]))

        case "get_version":
            let version = BridgeVersion()
            completionHandler?(responseData(["version": version ?? "unknown"]))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - TUN Configuration

    private func createTunnelSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")

        // IPv4 - route all traffic through the tunnel
        let ipv4 = NEIPv4Settings(
            addresses: [AppConstants.tunAddress],
            subnetMasks: [AppConstants.tunSubnetMask]
        )
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // DNS - point to Mihomo's fake-ip DNS server
        let dns = NEDNSSettings(servers: [AppConstants.tunDNS])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        settings.mtu = NSNumber(value: AppConstants.defaultMTU)

        return settings
    }

    // MARK: - Memory Management

    /// iOS Network Extension has a ~15MB memory limit.
    /// Periodically trigger Go GC to return memory to the OS.
    /// Go also runs its own internal GC ticker every 10s, but this ensures
    /// we also reclaim after any Swift-side allocations or IPC activity.
    private func startMemoryManagement() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler {
            BridgeForceGC()
        }
        timer.resume()
        gcTimer = timer
    }

    private func stopMemoryManagement() {
        gcTimer?.cancel()
        gcTimer = nil
    }

    // MARK: - Helpers

    private var configDirectory: String? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        )?.appendingPathComponent("mihomo").path
    }

    /// Find the utun file descriptor created by NEPacketTunnelProvider.
    /// This fd is passed to the Go core so Mihomo can read/write VPN packets directly.
    private var tunnelFileDescriptor: Int32? {
        var buf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd: Int32 in 0...1024 {
            var len = socklen_t(buf.count)
            if getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &buf, &len) == 0
                && String(cString: buf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }

    private func setupLogging() {
        let level = UserDefaults(suiteName: AppConstants.appGroupIdentifier)?
            .string(forKey: "logLevel") ?? "info"
        BridgeUpdateLogLevel(level)
    }

    /// Log traffic counters every 3s for the first 120s after startup.
    /// This reveals whether the TUN device is actually passing packets.
    private func startDiagnosticLogging() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        var count = 0
        timer.setEventHandler { [weak self] in
            let up = BridgeGetUploadTraffic()
            let down = BridgeGetDownloadTraffic()
            let running = BridgeIsRunning()
            self?.log("DIAG[\(count)]: running=\(running) upload=\(up) download=\(down)")
            count += 1
            if count >= 40 {
                self?.diagnosticTimer?.cancel()
                self?.diagnosticTimer = nil
                self?.log("DIAG: diagnostic logging stopped after 120s")
            }
        }
        timer.resume()
        diagnosticTimer = timer
    }

    private func handleSwitchMode(_ mode: String) {
        guard let configDir = configDirectory else { return }
        let configPath = configDir + "/config.yaml"

        guard var config = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        // Replace mode value in YAML
        let modes = ["rule", "global", "direct"]
        for m in modes {
            config = config.replacingOccurrences(of: "mode: \(m)", with: "mode: \(mode)")
        }

        try? config.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Restart the engine with updated config
        BridgeStopProxy()

        // Re-set the TUN fd since StopProxy clears it
        if let fd = tunnelFileDescriptor {
            var err: NSError?
            BridgeSetTUNFd(Int32(fd), &err)
        }

        var err: NSError?
        BridgeStartProxy(&err)
        if let err = err {
            log("ERROR: Failed to restart with new mode: \(err)")
        }
    }

    private func responseData(_ dict: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: dict)
    }
}

enum PacketTunnelError: LocalizedError {
    case configDirectoryUnavailable
    case configNotFound
    case tunnelFDNotFound

    var errorDescription: String? {
        switch self {
        case .configDirectoryUnavailable:
            return "Shared container directory is not available"
        case .configNotFound:
            return "config.yaml not found. Please configure proxies first."
        case .tunnelFDNotFound:
            return "Could not find TUN file descriptor. The VPN tunnel may not have been created."
        }
    }
}
