# BaoLianDeng

iOS global proxy app powered by [Mihomo](https://github.com/MetaCubeX/mihomo) (Clash Meta) core.

## Features

- **Subscription Management** — Add, edit, refresh, and switch between proxy subscriptions (Clash YAML and base64 formats)
- **Proxy Node Selection** — Browse nodes by subscription with protocol icons and latency indicators
- **Traffic Analytics** — Daily bar charts, session stats, and monthly summaries for proxy-only traffic
- **Config Editor** — In-app YAML editor with validation for both local config and subscription configs
- **Proxy Groups** — View and switch proxy groups via Mihomo's REST API
- **Tunnel Logs** — Real-time log viewer for debugging the network extension
- **Aggressive Memory Management** — Go runtime tuned for iOS's ~15 MB network extension limit

## Architecture

```
┌─────────────────────────────────────────────┐
│              iOS App (SwiftUI)              │
│  ┌──────────┬────────┬───────┬───────────┐ │
│  │  Home    │ Config │ Data  │ Settings  │ │
│  │ Subs &   │ YAML   │Charts │ Groups /  │ │
│  │  Nodes   │ Editor │& Stats│ Logs      │ │
│  └──────────┴────────┴───────┴───────────┘ │
│  ┌───────────────────────────────────────┐  │
│  │  VPNManager (NETunnelProviderManager) │  │
│  └──────────────────┬────────────────────┘  │
├─────────────────────┼──────────────────────-┤
│       Network Extension (PacketTunnel)      │
│  ┌──────────────────┴────────────────────┐  │
│  │    NEPacketTunnelProvider             │  │
│  │    ┌──────────────────────────────┐   │  │
│  │    │  MihomoCore.xcframework (Go) │   │  │
│  │    │  - Proxy Engine              │   │  │
│  │    │  - DNS (fake-ip)             │   │  │
│  │    │  - Rules / Routing           │   │  │
│  │    └──────────────────────────────┘   │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**IPC** between the app and tunnel extension uses `NETunnelProviderSession.sendMessage` for mode switching, traffic stats, and version queries. Both targets share config files and preferences via App Group `group.io.github.baoliandeng`.

## Prerequisites

- macOS with Xcode 15+
- Go 1.22+

## Build

### 1. Build the Go framework

```bash
make framework          # iOS + Simulator (arm64 + x86_64)
make framework-arm64    # arm64 only (faster, device-only)
```

This compiles the Mihomo Go core into `Framework/MihomoCore.xcframework` using gomobile. The `make` target installs gomobile automatically if needed.

### 2. Configure signing

Copy the template and set your Apple development team ID:

```bash
cp Local.xcconfig.template Local.xcconfig
# Edit Local.xcconfig and set DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

> **Finding your Team ID:** Apple Developer portal → Membership → Team ID (10-character string, e.g. `AB12CD34EF`).

Both targets require these capabilities (already configured in entitlements):
- **App Groups** — `group.io.github.baoliandeng`
- **Network Extensions** — Packet Tunnel Provider

If you distribute under a different bundle ID, also update `appGroupIdentifier` and `tunnelBundleIdentifier` in `Shared/Constants.swift` and the matching entitlement files.

### 3. Build and run

```bash
open BaoLianDeng.xcodeproj
```

Select your device and press `Cmd+R`.

**CI-style simulator build (no signing):**

```bash
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## Configuration

The app ships with a sensible default config. You can also manage configuration through:

1. **Subscriptions** (recommended) — Add a subscription URL in the Home tab. The app parses Clash YAML and base64-encoded proxy lists, merges proxies into the active config, and auto-downloads GeoIP/GeoSite databases for rule matching.

2. **Config Editor** — Edit the YAML directly in the Config tab with syntax validation.

3. **Manual file** — Place a `config.yaml` in the app's shared container.

Example minimal config:

```yaml
mixed-port: 7890
mode: rule
log-level: info

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.alidns.com/dns-query

proxies:
  - name: "my-proxy"
    type: ss
    server: your-server.com
    port: 8388
    cipher: aes-256-gcm
    password: "your-password"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-proxy

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

## Project Structure

```
BaoLianDeng/
├── BaoLianDeng/                    # Main iOS app target
│   ├── BaoLianDengApp.swift        # Entry point with TabView
│   ├── Views/
│   │   ├── HomeView.swift          # Subscriptions & node selection
│   │   ├── ConfigEditorView.swift  # Dual-mode YAML editor
│   │   ├── TrafficView.swift       # Daily charts & session stats
│   │   ├── SettingsView.swift      # Proxy groups, log level, about
│   │   ├── ProxyGroupView.swift    # Proxy group switching
│   │   ├── TunnelLogView.swift     # Real-time log viewer
│   │   ├── AboutView.swift         # App info & links
│   │   └── YAMLEditor.swift        # YAML syntax highlighting
│   ├── Models/
│   │   └── TrafficStore.swift      # Traffic stats singleton
│   └── Assets.xcassets/
├── PacketTunnel/                   # Network Extension target
│   └── PacketTunnelProvider.swift
├── Shared/                         # Code shared between targets
│   ├── Constants.swift             # App group ID, bundle IDs, network constants
│   ├── ConfigManager.swift         # Config I/O, subscription merging, sanitization
│   └── VPNManager.swift            # VPN lifecycle as ObservableObject
├── Go/mihomo-bridge/               # Go bridge to Mihomo core
│   ├── bridge.go                   # gomobile API (Bridge* exports)
│   ├── tun_ios.go                  # iOS TUN device integration
│   ├── Makefile                    # gomobile build targets
│   └── patches/                    # iOS-specific dependency patches
├── Framework/                      # Built MihomoCore.xcframework
├── fastlane/                       # App Store metadata & upload
├── scripts/                        # Screenshot automation
└── Makefile                        # Top-level build (make framework)
```

## License

GPL-3.0
