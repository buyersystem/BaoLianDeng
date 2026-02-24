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

// Package bridge provides iOS-specific TUN device helpers.
//
//go:build ios

package bridge

import (
	"fmt"
)

// GenerateTUNConfig returns a YAML snippet for TUN mode configuration on iOS.
// The file-descriptor field tells Mihomo to use the fd from NEPacketTunnelProvider
// instead of creating its own TUN device.
func GenerateTUNConfig(fd int32, dnsAddr string) string {
	if dnsAddr == "" {
		dnsAddr = "198.18.0.2"
	}
	return fmt.Sprintf(`tun:
  enable: true
  stack: system
  file-descriptor: %d
  dns-hijack:
    - %s:53
  auto-route: false
  auto-detect-interface: false
`, fd, dnsAddr)
}
