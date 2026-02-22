# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BaoLianDeng is an iOS VPN proxy app powered by Mihomo (Clash Meta). It combines a SwiftUI app with a Go-based proxy engine compiled via gomobile into an xcframework.

## Build Commands

### Go Framework (must be built first)
```bash
make framework          # Build MihomoCore.xcframework for iOS + Simulator
make framework-arm64    # Build for arm64 only (faster, device-only)
make clean              # Remove built framework
```

### Go tooling setup (done automatically by `make framework`)
```bash
cd Go/mihomo-bridge && make setup   # Install gomobile and gobind
```

### iOS App (Xcode)
```bash
open BaoLianDeng.xcodeproj          # Open project in Xcode, then Cmd+R

# CI-style simulator build (no signing):
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Linting
```bash
swiftlint lint --strict    # SwiftLint (optional, CI continues on error)
```

## Architecture

**Two-target iOS app** communicating via IPC:

1. **BaoLianDeng** (main app) — SwiftUI with TabView (Home, Config Editor, Traffic, Settings). Uses `VPNManager` to control the tunnel via `NETunnelProviderManager`.

2. **PacketTunnel** (network extension) — `NEPacketTunnelProvider` that hosts the Go proxy engine. Discovers the TUN file descriptor by scanning fds 0–1024 for `utun*` interfaces, then passes it to Go via `BridgeSetTUNFd()`.

3. **MihomoCore.xcframework** (Go) — Compiled from `Go/mihomo-bridge/` via gomobile. Exports functions prefixed with `Bridge` (e.g., `BridgeStartProxy`, `BridgeSetTUNFd`, `BridgeGetTrafficStats`).

**Shared code** in `Shared/` is used by both targets:
- `Constants.swift` — App group ID, bundle IDs, network constants
- `ConfigManager.swift` — YAML config file I/O in shared container
- `VPNManager.swift` — VPN lifecycle as an ObservableObject

**IPC protocol** — Main app sends dictionaries to PacketTunnel via `sendMessage`:
- `["action": "switch_mode", "mode": "rule|global|direct"]`
- `["action": "get_traffic"]`
- `["action": "get_version"]`

**Data sharing** — Both targets use App Group `group.io.github.baoliandeng` for shared UserDefaults and config files at `mihomo/config.yaml`.

## Key Constraints

- **Network Extension memory limit is ~15MB.** Go runtime is configured with `SetGCPercent(5)`, `SetMemoryLimit(8MB)`, `GOMAXPROCS(1)`, and a background GC goroutine every 10 seconds. Swift side also calls `ForceGC()` every 10 seconds. Be careful adding dependencies or allocations in PacketTunnel.
- **TUN address space**: `198.18.0.0/16` (fake-ip range), DNS at `198.18.0.2:53`, TUN at `198.18.0.1`.
- **External controller**: Mihomo REST API at `127.0.0.1:9090` (used by ProxyGroupView for group/node info).
- **iOS 17.0** minimum deployment target.
- Both targets require matching entitlements: App Groups, Network Extension (packet-tunnel-provider), and Keychain sharing.

## Go Bridge

`Go/mihomo-bridge/bridge.go` is the gomobile boundary. All exported functions must follow gomobile constraints (simple types only — no slices, maps, or interfaces in signatures). Key exports:
- `SetHomeDir`, `SetConfig`, `SetTUNFd` — setup
- `StartProxy`, `StopProxy`, `IsRunning` — lifecycle
- `GetTrafficStats` — returns (up, down int64)
- `ValidateConfig` — YAML validation
- `ForceGC` — manual garbage collection

## Sensitive Information

- **DEVELOPMENT_TEAM** is defined in `Local.xcconfig` (gitignored). Copy `Local.xcconfig.template` to `Local.xcconfig` and set your team ID. The project-level configs inherit it via `baseConfigurationReference` — no team ID in `project.pbxproj`.
- **xcuserdata/** directories — gitignored, never commit these.
- Never commit signing identities, provisioning profile names, or Apple developer account details.

## Prerequisites

- macOS with Xcode 15+
- Go 1.22+
- Signing requires: development team set for both targets, App Group and Network Extension capabilities enabled
