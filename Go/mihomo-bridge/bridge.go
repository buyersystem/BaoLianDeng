// Copyright (c) 2026 Max Lv <max.c.lv@gmail.com>
//
// Licensed under the MIT License. See LICENSE file in the project root for details.

// Package bridge provides a gomobile-compatible interface to the Mihomo proxy core.
// It exposes a minimal API for starting/stopping the proxy engine from iOS.
package bridge

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"

	// Required by gomobile's gobind tool at build time.
	_ "golang.org/x/mobile/bind"
)

var (
	mu          sync.Mutex
	running     bool
	tunFdGlobal int32 = -1

	logFile    *os.File
	logFileMu  sync.Mutex
	logSubOnce sync.Once
)

func init() {
	// Aggressive GC to stay within iOS Network Extension's ~15MB memory limit.
	// Go runtime itself takes ~5MB, leaving ~10MB for the app.
	debug.SetGCPercent(5)

	// Hard soft-limit: tell the Go runtime to target at most 8MB of heap.
	// This triggers GC earlier when allocations spike (e.g. config parse, DNS cache).
	debug.SetMemoryLimit(8 * 1024 * 1024)

	// Limit OS threads to reduce per-thread stack memory (~1MB each).
	runtime.GOMAXPROCS(1)

	// Background GC goroutine: run every 10s regardless of allocation pressure.
	// This catches slow leaks and keeps RSS low between traffic bursts.
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		for range ticker.C {
			runtime.GC()
			debug.FreeOSMemory()
		}
	}()
}

// SetHomeDir sets the Mihomo home directory for config and data files.
// Also updates the config file path to the absolute path within that directory.
func SetHomeDir(path string) {
	constant.SetHomeDir(path)
	constant.SetConfig(filepath.Join(path, "config.yaml"))
}

// SetConfig writes the proxy configuration YAML to the home directory.
func SetConfig(yamlContent string) error {
	homeDir := constant.Path.HomeDir()
	configPath := filepath.Join(homeDir, "config.yaml")
	return os.WriteFile(configPath, []byte(yamlContent), 0644)
}

// SetLogFile directs bridge-level and Mihomo engine logs to the given file path.
// The file is opened in append mode. Call before StartProxy for full coverage.
func SetLogFile(path string) error {
	logFileMu.Lock()
	if logFile != nil {
		logFile.Close()
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		logFileMu.Unlock()
		return fmt.Errorf("open log file: %w", err)
	}
	logFile = f
	logFileMu.Unlock()

	// Subscribe to Mihomo's internal log events (once).
	// This captures DNS, TUN, proxy, and routing logs from the engine.
	logSubOnce.Do(func() {
		sub := log.Subscribe()
		go func() {
			for event := range sub {
				if event.LogLevel < log.Level() {
					continue
				}
				logFileMu.Lock()
				if logFile != nil {
					fmt.Fprintf(logFile, "[Mihomo/%s] %s\n", event.LogLevel, event.Payload)
				}
				logFileMu.Unlock()
			}
		}()
	})

	bridgeLog("Log file opened: %s", path)
	return nil
}

func bridgeLog(format string, args ...interface{}) {
	logFileMu.Lock()
	defer logFileMu.Unlock()
	if logFile != nil {
		msg := fmt.Sprintf(format, args...)
		fmt.Fprintf(logFile, "[Bridge] %s\n", msg)
	}
}

// SetTUNFd stores the TUN file descriptor provided by iOS NEPacketTunnelProvider.
// Call this before StartProxy. The fd is injected into the config so Mihomo's
// sing-tun layer reads/writes packets through the system VPN tunnel.
func SetTUNFd(fd int32) error {
	if fd < 0 {
		return fmt.Errorf("invalid file descriptor: %d", fd)
	}
	mu.Lock()
	tunFdGlobal = fd
	mu.Unlock()
	bridgeLog("SetTUNFd: fd=%d", fd)
	return nil
}

// StartProxy starts the Mihomo proxy engine with the configuration in the home directory.
func StartProxy() error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return fmt.Errorf("proxy is already running")
	}

	bridgeLog("StartProxy called, tunFd=%d", tunFdGlobal)

	homeDir := constant.Path.HomeDir()
	configPath := filepath.Join(homeDir, "config.yaml")

	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		return fmt.Errorf("config.yaml not found in %s", homeDir)
	}

	cfg, err := executor.Parse()
	if err != nil {
		return fmt.Errorf("failed to parse config: %w", err)
	}
	bridgeLog("Config parsed OK")

	// Free parser temporaries before applying config
	runtime.GC()
	debug.FreeOSMemory()

	// Disable process finding on iOS (not supported)
	cfg.General.FindProcessMode = process.FindProcessMode(process.FindProcessOff)

	// Inject TUN file descriptor from iOS if available.
	// Mihomo's sing-tun uses this fd instead of creating its own TUN device.
	if tunFdGlobal >= 0 {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.FileDescriptor = int(tunFdGlobal)
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.Inet6Address = nil
		bridgeLog("TUN: enable=true fd=%d ipv6=disabled", tunFdGlobal)
	} else {
		bridgeLog("WARNING: tunFd=%d, TUN will NOT be enabled", tunFdGlobal)
	}

	bridgeLog("Calling executor.ApplyConfig...")
	executor.ApplyConfig(cfg, true)
	bridgeLog("executor.ApplyConfig completed")

	// Free memory after setup
	runtime.GC()
	debug.FreeOSMemory()

	running = true
	log.Infoln("Mihomo proxy engine started")
	return nil
}

// StartWithExternalController starts the proxy engine with the REST API enabled
// on the given address (e.g., "127.0.0.1:9090").
func StartWithExternalController(addr, secret string) error {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return fmt.Errorf("proxy is already running")
	}

	homeDir := constant.Path.HomeDir()
	configPath := filepath.Join(homeDir, "config.yaml")

	if _, err := os.Stat(configPath); os.IsNotExist(err) {
		return fmt.Errorf("config.yaml not found in %s", homeDir)
	}

	cfg, err := executor.Parse()
	if err != nil {
		return fmt.Errorf("failed to parse config: %w", err)
	}

	// Free parser temporaries before applying config
	runtime.GC()
	debug.FreeOSMemory()

	// Disable process finding on iOS (not supported)
	cfg.General.FindProcessMode = process.FindProcessMode(process.FindProcessOff)

	// Override external controller settings
	cfg.Controller.ExternalController = addr
	cfg.Controller.Secret = secret

	// Inject TUN fd
	if tunFdGlobal >= 0 {
		cfg.General.Tun.Enable = true
		cfg.General.Tun.FileDescriptor = int(tunFdGlobal)
		cfg.General.Tun.AutoRoute = false
		cfg.General.Tun.AutoDetectInterface = false
		cfg.General.Tun.Inet6Address = nil
	}

	// hub.ApplyConfig starts both the external controller (REST API) and
	// applies the proxy/TUN/DNS config via executor.ApplyConfig internally.
	hub.ApplyConfig(cfg)

	runtime.GC()
	debug.FreeOSMemory()

	running = true
	log.Infoln("Mihomo proxy engine started with external controller at %s", addr)
	return nil
}

// StopProxy stops the Mihomo proxy engine gracefully.
// Uses executor.Shutdown() which properly cleans up listeners, TUN device,
// DNS resolver state, and fake-ip pool persistence.
func StopProxy() {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return
	}

	bridgeLog("StopProxy called")
	executor.Shutdown()

	running = false
	tunFdGlobal = -1
	bridgeLog("Proxy engine stopped")
	log.Infoln("Mihomo proxy engine stopped")

	runtime.GC()
	debug.FreeOSMemory()
}

// IsRunning returns whether the proxy engine is currently active.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running
}

// UpdateLogLevel updates the logging level (debug, info, warning, error, silent).
func UpdateLogLevel(level string) {
	log.SetLevel(log.LogLevelMapping[level])
}

// ReadConfig reads the current configuration file and returns its contents.
func ReadConfig() (string, error) {
	homeDir := constant.Path.HomeDir()
	configPath := filepath.Join(homeDir, "config.yaml")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// ValidateConfig validates a YAML configuration string without applying it.
func ValidateConfig(yamlContent string) error {
	_, err := config.Parse([]byte(yamlContent))
	return err
}

// GetUploadTraffic returns the current upload traffic in bytes.
func GetUploadTraffic() int64 {
	snapshot := statistic.DefaultManager.Snapshot()
	return snapshot.UploadTotal
}

// GetDownloadTraffic returns the current download traffic in bytes.
func GetDownloadTraffic() int64 {
	snapshot := statistic.DefaultManager.Snapshot()
	return snapshot.DownloadTotal
}

// ForceGC triggers garbage collection and returns memory to the OS.
// Call periodically from iOS to manage the extension's memory budget.
func ForceGC() {
	runtime.GC()
	debug.FreeOSMemory()
}

// Version returns the Mihomo core version.
func Version() string {
	return constant.Version
}

// TestDirectTCP tests if the Network Extension can make outbound TCP connections
// bypassing the TUN. Returns "OK: ..." or "FAIL: ...".
func TestDirectTCP(host string, port int32) string {
	addr := fmt.Sprintf("%s:%d", host, port)
	start := time.Now()
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	elapsed := time.Since(start)
	if err != nil {
		return fmt.Sprintf("FAIL after %v: %v", elapsed, err)
	}
	conn.Close()
	return fmt.Sprintf("OK: connected to %s in %v", addr, elapsed)
}

// TestProxyHTTP tests the Mihomo mixed proxy by making an HTTP request through it.
// Returns the HTTP status line or error.
func TestProxyHTTP(targetURL string) string {
	proxyAddr := "127.0.0.1:7890"
	conn, err := net.DialTimeout("tcp", proxyAddr, 5*time.Second)
	if err != nil {
		return fmt.Sprintf("FAIL proxy connect: %v", err)
	}
	defer conn.Close()

	// Send HTTP GET through the proxy
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n", targetURL)
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	_, err = conn.Write([]byte(req))
	if err != nil {
		return fmt.Sprintf("FAIL proxy write: %v", err)
	}

	buf := make([]byte, 512)
	n, err := conn.Read(buf)
	if err != nil && err != io.EOF {
		return fmt.Sprintf("FAIL proxy read: %v", err)
	}
	// Return first line (HTTP status)
	resp := string(buf[:n])
	if idx := len(resp); idx > 0 {
		for i, c := range resp {
			if c == '\r' || c == '\n' {
				resp = resp[:i]
				break
			}
		}
	}
	return fmt.Sprintf("OK: %s", resp)
}

// TestDNSResolver tests Mihomo's DNS resolver by sending an A query for www.baidu.com
// and verifying the response is a fake-ip in 198.18.0.0/16.
// dnsAddr should be "127.0.0.1:1053".
func TestDNSResolver(dnsAddr string) string {
	dnsConn, err := net.DialTimeout("udp", dnsAddr, 3*time.Second)
	if err != nil {
		return fmt.Sprintf("DNS-TEST: FAIL connect to %s: %v", dnsAddr, err)
	}
	defer dnsConn.Close()

	dnsQuery := buildDNSQuery("www.baidu.com")
	dnsConn.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = dnsConn.Write(dnsQuery)
	if err != nil {
		return fmt.Sprintf("DNS-TEST: FAIL write: %v", err)
	}
	buf := make([]byte, 512)
	n, err := dnsConn.Read(buf)
	if err != nil {
		return fmt.Sprintf("DNS-TEST: FAIL read: %v", err)
	}

	ip := parseDNSResponseA(buf[:n])
	if ip == "" {
		return "DNS-TEST: FAIL could not parse A record from response"
	}
	if strings.HasPrefix(ip, "198.18.") {
		return fmt.Sprintf("DNS-TEST: OK fake-ip %s for www.baidu.com", ip)
	}
	return fmt.Sprintf("DNS-TEST: WARN got %s (not in 198.18.0.0/16) for www.baidu.com", ip)
}

// TestSelectedProxy queries the Mihomo REST API, finds the first Selector proxy group
// with real proxy nodes, then tests the selected node's latency.
// apiAddr should be "127.0.0.1:9090".
func TestSelectedProxy(apiAddr string) string {
	client := &http.Client{Timeout: 10 * time.Second}

	// List all proxies to find Selector groups
	resp, err := client.Get(fmt.Sprintf("http://%s/proxies", apiAddr))
	if err != nil {
		return fmt.Sprintf("PROXY-TEST: FAIL list proxies: %v", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Sprintf("PROXY-TEST: FAIL read response: %v", err)
	}

	var proxies struct {
		Proxies map[string]json.RawMessage `json:"proxies"`
	}
	if err := json.Unmarshal(body, &proxies); err != nil {
		return fmt.Sprintf("PROXY-TEST: FAIL parse proxies: %v", err)
	}

	// Find the first Selector group that has a selected node (skip built-in groups)
	type proxyGroup struct {
		Name string   `json:"name"`
		Type string   `json:"type"`
		Now  string   `json:"now"`
		All  []string `json:"all"`
	}
	builtIn := map[string]bool{"DIRECT": true, "REJECT": true, "GLOBAL": true, "default": true}
	var selected *proxyGroup
	for name, raw := range proxies.Proxies {
		if builtIn[name] {
			continue
		}
		var g proxyGroup
		if json.Unmarshal(raw, &g) != nil {
			continue
		}
		if g.Type == "Selector" && g.Now != "" && g.Now != "DIRECT" && g.Now != "REJECT" {
			selected = &g
			selected.Name = name
			break
		}
	}
	if selected == nil {
		// List what we found for debugging
		var names []string
		for name := range proxies.Proxies {
			names = append(names, name)
		}
		return fmt.Sprintf("PROXY-TEST: FAIL no Selector group with proxy node found (groups: %v)", names)
	}

	// Get the selected proxy's type
	proxyResp, err := client.Get(fmt.Sprintf("http://%s/proxies/%s", apiAddr, selected.Now))
	proxyType := "unknown"
	if err == nil {
		defer proxyResp.Body.Close()
		proxyBody, _ := io.ReadAll(proxyResp.Body)
		var proxyInfo struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(proxyBody, &proxyInfo) == nil && proxyInfo.Type != "" {
			proxyType = proxyInfo.Type
		}
	}

	result := fmt.Sprintf("PROXY-TEST: group=%s selected=%s type=%s", selected.Name, selected.Now, proxyType)

	// Test latency via the delay endpoint
	delayURL := fmt.Sprintf("http://%s/proxies/%s/delay?url=http://www.gstatic.com/generate_204&timeout=5000",
		apiAddr, selected.Now)
	req, _ := http.NewRequest("GET", delayURL, nil)
	delayResp, err := client.Do(req)
	if err != nil {
		result += fmt.Sprintf(" delay=FAIL(%v)", err)
		return result
	}
	defer delayResp.Body.Close()
	delayBody, _ := io.ReadAll(delayResp.Body)

	var delayResult struct {
		Delay   int    `json:"delay"`
		Message string `json:"message"`
	}
	if json.Unmarshal(delayBody, &delayResult) == nil {
		if delayResult.Delay > 0 {
			result += fmt.Sprintf(" delay=%dms", delayResult.Delay)
		} else if delayResult.Message != "" {
			result += fmt.Sprintf(" delay=FAIL(%s)", delayResult.Message)
		} else {
			result += fmt.Sprintf(" delay=FAIL(status %d, body: %.200s)", delayResp.StatusCode, string(delayBody))
		}
	} else {
		result += fmt.Sprintf(" delay=FAIL(status %d)", delayResp.StatusCode)
	}
	return result
}

// buildDNSQuery builds a minimal DNS A query for the given domain.
func buildDNSQuery(domain string) []byte {
	buf := make([]byte, 0, 64)
	// Header: ID=0x1234, flags=0x0100 (standard query), QDCOUNT=1
	buf = append(buf, 0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
	// Question: domain name
	for _, label := range splitDomain(domain) {
		buf = append(buf, byte(len(label)))
		buf = append(buf, []byte(label)...)
	}
	buf = append(buf, 0x00)       // root label
	buf = append(buf, 0x00, 0x01) // QTYPE = A
	buf = append(buf, 0x00, 0x01) // QCLASS = IN
	return buf
}

func splitDomain(domain string) []string {
	var labels []string
	label := ""
	for _, c := range domain {
		if c == '.' {
			if label != "" {
				labels = append(labels, label)
			}
			label = ""
		} else {
			label += string(c)
		}
	}
	if label != "" {
		labels = append(labels, label)
	}
	return labels
}

// parseDNSResponseA extracts the first A record IP from a DNS response.
func parseDNSResponseA(msg []byte) string {
	if len(msg) < 12 {
		return ""
	}
	// Skip header (12 bytes)
	pos := 12
	// Skip question section (QDCOUNT from header bytes 4-5)
	qdcount := int(msg[4])<<8 | int(msg[5])
	for i := 0; i < qdcount && pos < len(msg); i++ {
		for pos < len(msg) {
			l := int(msg[pos])
			pos++
			if l == 0 {
				break
			}
			if l >= 0xC0 { // pointer
				pos++
				break
			}
			pos += l
		}
		pos += 4 // QTYPE + QCLASS
	}
	// Parse answer section (ANCOUNT from header bytes 6-7)
	ancount := int(msg[6])<<8 | int(msg[7])
	for i := 0; i < ancount && pos < len(msg); i++ {
		// Skip name (could be pointer)
		if pos < len(msg) && msg[pos] >= 0xC0 {
			pos += 2
		} else {
			for pos < len(msg) {
				l := int(msg[pos])
				pos++
				if l == 0 {
					break
				}
				pos += l
			}
		}
		if pos+10 > len(msg) {
			break
		}
		rtype := int(msg[pos])<<8 | int(msg[pos+1])
		rdlen := int(msg[pos+8])<<8 | int(msg[pos+9])
		pos += 10
		if rtype == 1 && rdlen == 4 && pos+4 <= len(msg) { // A record
			return fmt.Sprintf("%d.%d.%d.%d", msg[pos], msg[pos+1], msg[pos+2], msg[pos+3])
		}
		pos += rdlen
	}
	return ""
}
