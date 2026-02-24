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
import NetworkExtension

final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    @Published var status: NEVPNStatus = .disconnected
    @Published var isProcessing = false
    @Published var errorMessage: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    private init() {
        loadManager()
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    // MARK: - Manager Lifecycle

    func loadManager() {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.errorMessage = "Failed to load VPN config: \(error.localizedDescription)"
                    return
                }
                self?.manager = managers?.first ?? self?.createManager()
                self?.observeStatus()
            }
        }
    }

    private func createManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppConstants.tunnelBundleIdentifier
        proto.serverAddress = "BaoLianDeng"
        proto.disconnectOnSleep = false

        manager.protocolConfiguration = proto
        manager.localizedDescription = "BaoLianDeng"
        manager.isEnabled = true

        return manager
    }

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }

        guard let connection = manager?.connection else { return }

        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            self?.status = connection.status
            if connection.status != .connecting && connection.status != .disconnecting {
                self?.isProcessing = false
            }
            if connection.status == .disconnected {
                VPNManager.clearTunnelLog()
            }
        }

        status = connection.status
    }

    // MARK: - Connect / Disconnect

    func start() {
        guard !isProcessing else { return }

        isProcessing = true
        errorMessage = nil

        let saveAndStart = { [weak self] in
            guard let self = self, let manager = self.manager else { return }

            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.errorMessage = "Failed to save VPN config: \(error.localizedDescription)"
                    }
                    return
                }

                manager.loadFromPreferences { error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to reload VPN config: \(error.localizedDescription)"
                        }
                        return
                    }

                    do {
                        try (manager.connection as? NETunnelProviderSession)?.startTunnel()
                    } catch {
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "Failed to start tunnel: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }

        // Ensure config exists before starting
        if !ConfigManager.shared.configExists() {
            do {
                let defaultConfig = ConfigManager.shared.defaultConfig()
                try ConfigManager.shared.saveConfig(defaultConfig)
            } catch {
                isProcessing = false
                errorMessage = "Failed to create default config: \(error.localizedDescription)"
                return
            }
        }

        saveAndStart()
    }

    func stop() {
        guard !isProcessing else { return }
        isProcessing = true
        manager?.connection.stopVPNTunnel()
    }

    func toggle() {
        if isConnected {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Send Message to Tunnel

    func sendMessage(_ message: [String: Any], completion: @escaping (Data?) -> Void) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            completion(nil)
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(nil)
            return
        }

        do {
            try session.sendProviderMessage(data) { response in
                completion(response)
            }
        } catch {
            completion(nil)
        }
    }

    func switchMode(_ mode: ProxyMode) {
        // Update config on disk, then restart the tunnel so it picks up the change
        ConfigManager.shared.setMode(mode.rawValue)
        guard isConnected else { return }
        isProcessing = true
        manager?.connection.stopVPNTunnel()

        // Wait for disconnect, then restart
        DispatchQueue.global().async { [weak self] in
            // Poll for disconnected state (up to 5s)
            for _ in 0..<50 {
                if self?.manager?.connection.status == .disconnected { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            DispatchQueue.main.async {
                self?.isProcessing = false
                self?.start()
            }
        }
    }

    private static func clearTunnelLog() {
        guard let dir = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier
        ) else { return }
        let logURL = dir.appendingPathComponent("tunnel.log")
        try? FileManager.default.removeItem(at: logURL)
    }
}
