# Replace Go Bridge with Rust FFI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Go/gomobile bridge with a Rust FFI layer that produces an identical `MihomoCore.xcframework`, eliminating the Go runtime's ~5-8MB memory overhead in the iOS Network Extension.

**Architecture:** A new `mihomo-ffi` Rust crate in `Rust/mihomo-ffi/` exports C functions wrapping the mihomo-rust engine (included as a git submodule at `Rust/mihomo/`). An ObjC wrapper layer converts between C types and Foundation types, producing the same API that Swift currently calls. The framework name stays `MihomoCore` — zero Swift changes.

**Tech Stack:** Rust (staticlib for iOS), ObjC (Foundation wrapper), mihomo-rust crates (path deps via submodule), netstack-smoltcp (TCP/IP stack), tokio (async runtime)

**Spec:** `docs/superpowers/specs/2026-03-23-replace-go-with-rust-design.md`

---

## File Map

### New files (in BaoLianDeng repo)

| File | Responsibility |
|------|---------------|
| `.gitmodules` | Git submodule config for `Rust/mihomo` |
| `Rust/mihomo/` | Git submodule (mihomo-rust, read-only) |
| `Rust/mihomo-ffi/Cargo.toml` | Crate config: staticlib, path deps to submodule |
| `Rust/mihomo-ffi/src/lib.rs` | FFI exports, global state, engine lifecycle, error handling |
| `Rust/mihomo-ffi/src/tun_fd.rs` | `TunFdListener`: fd-based TUN for iOS |
| `Rust/mihomo-ffi/src/diagnostics.rs` | Test functions (TCP, HTTP, DNS, proxy) |
| `Rust/mihomo-ffi/src/logging.rs` | Log file writer + tracing subscriber |
| `Rust/mihomo-ffi/objc/MihomoCore.h` | ObjC header matching gomobile-generated API |
| `Rust/mihomo-ffi/objc/MihomoCore.m` | ObjC wrapper: Foundation ↔ C FFI |

### Modified files

| File | Change |
|------|--------|
| `Makefile` | Replace Go build with Rust + ObjC build |
| `.github/workflows/ci.yml` | Replace Go toolchain with Rust + iOS targets |
| `.gitignore` | Add `Rust/mihomo-ffi/target/` |

### Removed files

| Path | Reason |
|------|--------|
| `Go/mihomo-bridge/` | Entire directory replaced by Rust |

---

### Task 1: Add mihomo-rust git submodule

**Files:**
- Create: `.gitmodules`
- Create: `Rust/mihomo/` (submodule checkout)

- [ ] **Step 1: Add submodule**

```bash
cd /Volumes/DATA/workspace/BaoLianDeng
git submodule add https://github.com/madeye/mihomo-rust.git Rust/mihomo
```

- [ ] **Step 2: Pin to current HEAD**

```bash
cd Rust/mihomo && git checkout d6964a8d && cd ../..
```

- [ ] **Step 3: Verify submodule**

Run: `git submodule status`
Expected: Shows `Rust/mihomo` at the pinned commit hash.

- [ ] **Step 4: Update .gitignore**

Add to `.gitignore`:
```
# Rust build artifacts
Rust/mihomo-ffi/target/
```

- [ ] **Step 5: Commit**

```bash
git add .gitmodules Rust/mihomo .gitignore
git commit -m "Add mihomo-rust as git submodule at Rust/mihomo"
```

---

### Task 2: Create mihomo-ffi crate scaffold with error handling and string utilities

**Files:**
- Create: `Rust/mihomo-ffi/Cargo.toml`
- Create: `Rust/mihomo-ffi/src/lib.rs`

- [ ] **Step 1: Create Cargo.toml**

Create `Rust/mihomo-ffi/Cargo.toml`:

```toml
[package]
name = "mihomo-ffi"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["staticlib"]

[dependencies]
mihomo-tunnel = { path = "../mihomo/crates/mihomo-tunnel" }
mihomo-config = { path = "../mihomo/crates/mihomo-config" }
mihomo-dns = { path = "../mihomo/crates/mihomo-dns" }
mihomo-listener = { path = "../mihomo/crates/mihomo-listener" }
mihomo-api = { path = "../mihomo/crates/mihomo-api" }
mihomo-common = { path = "../mihomo/crates/mihomo-common" }
tokio = { version = "1", features = ["full"] }
parking_lot = "0.12"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
netstack-smoltcp = "0.2"
futures = "0.3"
serde_yaml = "0.9"
serde_json = "1"
anyhow = "1"
libc = "0.2"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls"] }
rustls = { version = "0.23", default-features = false, features = ["ring", "logging", "std", "tls12"] }
```

- [ ] **Step 2: Create src/lib.rs with error handling utilities and simple exports**

Create `Rust/mihomo-ffi/src/lib.rs`:

```rust
mod diagnostics;
mod logging;
mod tun_fd;

use mihomo_api::ApiServer;
use mihomo_config::raw::RawConfig;
use mihomo_listener::{MixedListener, TunListenerConfig};
use mihomo_tunnel::Tunnel;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

// ---------------------------------------------------------------------------
// Thread-local error message
// ---------------------------------------------------------------------------

thread_local! {
    static LAST_ERROR: std::cell::RefCell<String> = std::cell::RefCell::new(String::new());
    static LAST_ERROR_CSTR: std::cell::RefCell<CString> =
        std::cell::RefCell::new(CString::new("").unwrap());
}

fn set_error(msg: String) {
    LAST_ERROR.with(|e| *e.borrow_mut() = msg);
}

/// # Safety
/// Returns pointer to thread-local static. Do NOT free.
#[no_mangle]
pub unsafe extern "C" fn bridge_get_last_error() -> *const c_char {
    let msg = LAST_ERROR.with(|e| e.borrow().clone());
    LAST_ERROR_CSTR.with(|cs| {
        *cs.borrow_mut() = CString::new(msg).unwrap_or_else(|_| CString::new("unknown error").unwrap());
        cs.borrow().as_ptr()
    })
}

// ---------------------------------------------------------------------------
// String utilities
// ---------------------------------------------------------------------------

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

fn str_to_cstring_ptr(s: &str) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

/// # Safety
/// Free a string previously returned by a bridge_* function.
#[no_mangle]
pub unsafe extern "C" fn bridge_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn get_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    })
}

struct EngineState {
    tunnel: Tunnel,
    // Keep handles alive so spawned tasks don't get cancelled
    _handles: Vec<tokio::task::JoinHandle<()>>,
}

static ENGINE: Mutex<Option<EngineState>> = Mutex::new(None);
static HOME_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);
static TUN_FD: Mutex<Option<i32>> = Mutex::new(None);

// ---------------------------------------------------------------------------
// Version constant
// ---------------------------------------------------------------------------

static VERSION_CSTR: OnceLock<CString> = OnceLock::new();

/// # Safety
/// Returns pointer to static string. Do NOT free.
#[no_mangle]
pub unsafe extern "C" fn bridge_version() -> *const c_char {
    VERSION_CSTR
        .get_or_init(|| CString::new("mihomo-rust 0.2.0").unwrap())
        .as_ptr()
}

/// No-op. Kept for Swift compatibility (Swift calls ForceGC every 10s).
#[no_mangle]
pub extern "C" fn bridge_force_gc() {}

/// # Safety
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_home_dir(path: *const c_char) {
    let p = cstr_to_str(path);
    *HOME_DIR.lock() = Some(PathBuf::from(p));
}

/// # Safety
/// `yaml` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_config(yaml: *const c_char) -> i32 {
    let yaml_str = cstr_to_str(yaml);
    let home = HOME_DIR.lock();
    let Some(home) = home.as_ref() else {
        set_error("home directory not set".to_string());
        return -1;
    };
    let config_path = home.join("config.yaml");
    match std::fs::write(&config_path, yaml_str) {
        Ok(()) => 0,
        Err(e) => {
            set_error(format!("write config: {}", e));
            -1
        }
    }
}

/// # Safety
/// `fd` must be a valid TUN file descriptor from iOS NEPacketTunnelProvider.
#[no_mangle]
pub extern "C" fn bridge_set_tun_fd(fd: i32) -> i32 {
    if fd < 0 {
        set_error(format!("invalid file descriptor: {}", fd));
        return -1;
    }
    *TUN_FD.lock() = Some(fd);
    0
}

#[no_mangle]
pub extern "C" fn bridge_is_running() -> bool {
    ENGINE.lock().is_some()
}

/// # Safety
/// Returns heap-allocated string. Caller must free via bridge_free_string.
/// Returns null on error (check bridge_get_last_error).
#[no_mangle]
pub unsafe extern "C" fn bridge_read_config() -> *mut c_char {
    let home = HOME_DIR.lock();
    let Some(home) = home.as_ref() else {
        set_error("home directory not set".to_string());
        return std::ptr::null_mut();
    };
    let config_path = home.join("config.yaml");
    match std::fs::read_to_string(&config_path) {
        Ok(content) => str_to_cstring_ptr(&content),
        Err(e) => {
            set_error(format!("read config: {}", e));
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `yaml` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_validate_config(yaml: *const c_char) -> i32 {
    let yaml_str = cstr_to_str(yaml);
    match mihomo_config::load_config_from_str(yaml_str) {
        Ok(_) => 0,
        Err(e) => {
            set_error(format!("validate config: {}", e));
            -1
        }
    }
}

/// # Safety
/// `level` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_update_log_level(level: *const c_char) {
    let _level = cstr_to_str(level);
    // TODO: update tracing subscriber level dynamically
}

#[no_mangle]
pub extern "C" fn bridge_get_upload_traffic() -> i64 {
    let engine = ENGINE.lock();
    match engine.as_ref() {
        Some(state) => state.tunnel.statistics().snapshot().0,
        None => 0,
    }
}

#[no_mangle]
pub extern "C" fn bridge_get_download_traffic() -> i64 {
    let engine = ENGINE.lock();
    match engine.as_ref() {
        Some(state) => state.tunnel.statistics().snapshot().1,
        None => 0,
    }
}

// ---------------------------------------------------------------------------
// Engine lifecycle
// ---------------------------------------------------------------------------

/// # Safety
/// Call bridge_set_home_dir and optionally bridge_set_tun_fd before this.
#[no_mangle]
pub extern "C" fn bridge_start_proxy() -> i32 {
    start_engine(None, None)
}

/// # Safety
/// `addr` and `secret` must be valid null-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn bridge_start_with_external_controller(
    addr: *const c_char,
    secret: *const c_char,
) -> i32 {
    let addr_str = cstr_to_str(addr).to_string();
    let secret_str = cstr_to_str(secret).to_string();
    start_engine(Some(addr_str), Some(secret_str))
}

fn start_engine(
    external_controller: Option<String>,
    secret: Option<String>,
) -> i32 {
    let mut engine = ENGINE.lock();
    if engine.is_some() {
        set_error("proxy is already running".to_string());
        return -1;
    }

    let home = HOME_DIR.lock().clone();
    let Some(home) = home else {
        set_error("home directory not set".to_string());
        return -1;
    };

    let config_path = home.join("config.yaml");
    let config_path_str = config_path.to_string_lossy().to_string();

    if !config_path.exists() {
        set_error(format!("config.yaml not found in {}", home.display()));
        return -1;
    }

    let tun_fd = TUN_FD.lock().take();

    let rt = get_runtime();

    match rt.block_on(async { start_engine_async(&config_path_str, tun_fd, external_controller, secret).await }) {
        Ok(state) => {
            *engine = Some(state);
            0
        }
        Err(e) => {
            set_error(format!("start proxy: {}", e));
            -1
        }
    }
}

async fn start_engine_async(
    config_path: &str,
    tun_fd: Option<i32>,
    external_controller: Option<String>,
    secret: Option<String>,
) -> Result<EngineState, anyhow::Error> {
    // Initialize rustls crypto provider
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut config = mihomo_config::load_config(config_path)?;

    // Override external controller if specified
    if let Some(addr) = external_controller {
        config.api.external_controller = addr.parse().ok();
    }
    if let Some(s) = secret {
        config.api.secret = if s.is_empty() { None } else { Some(s) };
    }

    let raw_config = Arc::new(parking_lot::RwLock::new(config.raw.clone()));
    let tunnel = Tunnel::new(config.dns.resolver.clone());
    tunnel.set_mode(config.general.mode);
    tunnel.update_rules(config.rules);
    tunnel.update_proxies(config.proxies);

    let mut handles: Vec<tokio::task::JoinHandle<()>> = Vec::new();

    // Start DNS server
    if let Some(listen_addr) = config.dns.listen_addr {
        let dns_server = mihomo_dns::DnsServer::new(config.dns.resolver.clone(), listen_addr);
        handles.push(tokio::spawn(async move {
            if let Err(e) = dns_server.run().await {
                tracing::error!("DNS server error: {}", e);
            }
        }));
    }

    // Start REST API
    if let Some(api_addr) = config.api.external_controller {
        let api_server = ApiServer::new(
            tunnel.clone(),
            api_addr,
            config.api.secret.clone(),
            config_path.to_string(),
            raw_config.clone(),
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = api_server.run().await {
                tracing::error!("API server error: {}", e);
            }
        }));
    }

    // Start mixed listener
    let bind_addr = &config.listeners.bind_address;
    if let Some(port) = config.listeners.mixed_port {
        let addr: std::net::SocketAddr = format!("{}:{}", bind_addr, port).parse()?;
        let listener = MixedListener::new(tunnel.clone(), addr);
        handles.push(tokio::spawn(async move {
            if let Err(e) = listener.run().await {
                tracing::error!("Mixed listener error: {}", e);
            }
        }));
    }

    // Start TUN listener
    if let Some(fd) = tun_fd {
        // iOS path: use fd-based TUN listener
        let tun_config = config.tun.as_ref();
        let mtu = tun_config.map(|t| t.mtu).unwrap_or(1500);
        let dns_hijack = tun_config
            .map(|t| t.dns_hijack.clone())
            .unwrap_or_default();
        let tun_listener = tun_fd::TunFdListener::new(
            tunnel.clone(),
            fd,
            mtu,
            dns_hijack,
            config.dns.resolver.clone(),
        );
        handles.push(tokio::spawn(async move {
            if let Err(e) = tun_listener.run().await {
                tracing::error!("TUN fd listener error: {}", e);
            }
        }));
    } else if let Some(ref tun_config) = config.tun {
        if tun_config.enable {
            // Desktop path: create TUN device
            let tun_listener_config = TunListenerConfig {
                device: tun_config.device.clone(),
                mtu: tun_config.mtu,
                inet4_address: tun_config.inet4_address.clone(),
                dns_hijack: tun_config.dns_hijack.clone(),
            };
            let tun = mihomo_listener::TunListener::new(
                tunnel.clone(),
                tun_listener_config,
                config.dns.resolver.clone(),
            );
            handles.push(tokio::spawn(async move {
                if let Err(e) = tun.run().await {
                    tracing::error!("TUN listener error: {}", e);
                }
            }));
        }
    }

    Ok(EngineState {
        tunnel,
        _handles: handles,
    })
}

#[no_mangle]
pub extern "C" fn bridge_stop_proxy() {
    let mut engine = ENGINE.lock();
    if let Some(state) = engine.take() {
        // Abort all spawned tasks
        for handle in state._handles {
            handle.abort();
        }
    }
    // Reset TUN fd
    *TUN_FD.lock() = None;
}

/// # Safety
/// `fd` must be a valid TUN fd. `dns_addr` must be a null-terminated string.
#[no_mangle]
pub unsafe extern "C" fn bridge_generate_tun_config(fd: i32, dns_addr: *const c_char) -> *mut c_char {
    let dns = cstr_to_str(dns_addr);
    let dns = if dns.is_empty() { "198.18.0.2" } else { dns };
    let yaml = format!(
        "tun:\n  enable: true\n  stack: gvisor\n  device: fd://{}\n  auto-route: false\n  auto-detect-interface: false\n  dns-hijack:\n    - \"{}:53\"\n",
        fd, dns
    );
    str_to_cstring_ptr(&yaml)
}
```

- [ ] **Step 3: Verify crate compiles for host target**

Run: `cd /Volumes/DATA/workspace/BaoLianDeng/Rust/mihomo-ffi && cargo check 2>&1 | head -20`
Expected: Compilation succeeds (or warnings only). Fix any errors before proceeding.

- [ ] **Step 4: Commit**

```bash
git add Rust/mihomo-ffi/Cargo.toml Rust/mihomo-ffi/src/lib.rs
git commit -m "Add mihomo-ffi crate scaffold with FFI exports and engine lifecycle"
```

---

### Task 3: Implement TUN fd listener

**Files:**
- Create: `Rust/mihomo-ffi/src/tun_fd.rs`

- [ ] **Step 1: Create tun_fd.rs**

Create `Rust/mihomo-ffi/src/tun_fd.rs`:

```rust
use futures::{SinkExt, StreamExt};
use mihomo_common::{ConnType, Metadata, Network};
use mihomo_dns::{DnsServer, Resolver};
use mihomo_listener::tun_conn::TunTcpConn;
use mihomo_tunnel::Tunnel;
use netstack_smoltcp::StackBuilder;
use std::io;
use std::net::SocketAddr;
use std::os::unix::io::{FromRawFd, RawFd};
use std::sync::Arc;
use tokio::io::unix::AsyncFd;
use tracing::{debug, error, info};

/// TUN listener that reads/writes raw IP packets from an iOS-provided
/// file descriptor (from NEPacketTunnelProvider) and processes them
/// through the tunnel's proxy routing engine via netstack-smoltcp.
pub struct TunFdListener {
    tunnel: Tunnel,
    fd: i32,
    mtu: u16,
    dns_hijack: Vec<SocketAddr>,
    resolver: Arc<Resolver>,
}

/// Wrapper around a raw fd for async I/O via tokio's AsyncFd.
struct RawTunDevice {
    fd: std::os::fd::OwnedFd,
}

impl RawTunDevice {
    /// # Safety
    /// `fd` must be a valid, open file descriptor. Ownership is transferred.
    unsafe fn from_raw_fd(fd: RawFd) -> Self {
        use std::os::fd::FromRawFd;
        Self {
            fd: std::os::fd::OwnedFd::from_raw_fd(fd),
        }
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let n = unsafe {
            libc::read(
                self.fd.as_raw_fd(),
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }

    fn write(&self, buf: &[u8]) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let n = unsafe {
            libc::write(
                self.fd.as_raw_fd(),
                buf.as_ptr() as *const libc::c_void,
                buf.len(),
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(n as usize)
        }
    }
}

impl std::os::fd::AsRawFd for RawTunDevice {
    fn as_raw_fd(&self) -> RawFd {
        use std::os::fd::AsRawFd;
        self.fd.as_raw_fd()
    }
}

impl TunFdListener {
    pub fn new(
        tunnel: Tunnel,
        fd: i32,
        mtu: u16,
        dns_hijack: Vec<SocketAddr>,
        resolver: Arc<Resolver>,
    ) -> Self {
        Self {
            tunnel,
            fd,
            mtu,
            dns_hijack,
            resolver,
        }
    }

    pub async fn run(self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let device = unsafe { RawTunDevice::from_raw_fd(self.fd as RawFd) };

        // Set fd to non-blocking for tokio AsyncFd
        unsafe {
            let flags = libc::fcntl(self.fd, libc::F_GETFL);
            libc::fcntl(self.fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }

        let async_device = Arc::new(AsyncFd::new(device)?);

        info!("TUN fd listener started: fd={}, mtu={}", self.fd, self.mtu);

        // Build the netstack-smoltcp stack
        let (stack, tcp_runner, udp_socket, tcp_listener) = StackBuilder::default()
            .enable_tcp(true)
            .enable_udp(true)
            .build()?;

        let tcp_runner = tcp_runner.ok_or("TCP runner not created")?;
        let udp_socket = udp_socket.ok_or("UDP socket not created")?;
        let tcp_listener = tcp_listener.ok_or("TCP listener not created")?;

        // Spawn TCP runner
        tokio::spawn(async move {
            if let Err(e) = tcp_runner.await {
                error!("TCP runner error: {}", e);
            }
        });

        // Bidirectional packet relay: fd ↔ netstack
        let relay_device = async_device.clone();
        tokio::spawn(async move {
            relay_packets(relay_device, stack).await;
        });

        // TCP acceptor
        let tunnel_tcp = self.tunnel.clone();
        let mut tcp_listener = tcp_listener;
        tokio::spawn(async move {
            while let Some((stream, _local_addr, remote_addr)) = tcp_listener.next().await {
                let src_addr = *stream.local_addr();
                let metadata = Metadata {
                    network: Network::Tcp,
                    conn_type: ConnType::Tun,
                    src_ip: Some(src_addr.ip()),
                    dst_ip: Some(remote_addr.ip()),
                    src_port: src_addr.port(),
                    dst_port: remote_addr.port(),
                    ..Default::default()
                };
                let conn = Box::new(TunTcpConn::new(stream, remote_addr));
                let tunnel = tunnel_tcp.clone();
                tokio::spawn(async move {
                    mihomo_tunnel::tcp::handle_tcp(tunnel.inner(), conn, metadata).await;
                });
            }
        });

        // UDP handler with DNS hijack
        let tunnel_udp = self.tunnel.clone();
        let dns_hijack_addrs = self.dns_hijack.clone();
        let resolver = self.resolver.clone();
        let (mut udp_read, mut udp_write) = udp_socket.split();

        tokio::spawn(async move {
            while let Some((payload, src_addr, dst_addr)) = udp_read.next().await {
                if dns_hijack_addrs.contains(&dst_addr) {
                    match DnsServer::handle_query(&payload, &resolver).await {
                        Ok(response) => {
                            let reply: netstack_smoltcp::udp::UdpMsg =
                                (response, dst_addr, src_addr);
                            if let Err(e) = udp_write.send(reply).await {
                                debug!("DNS hijack reply error: {}", e);
                            }
                        }
                        Err(e) => {
                            debug!("DNS hijack query error: {}", e);
                        }
                    }
                    continue;
                }

                let metadata = Metadata {
                    network: Network::Udp,
                    conn_type: ConnType::Tun,
                    src_ip: Some(src_addr.ip()),
                    dst_ip: Some(dst_addr.ip()),
                    src_port: src_addr.port(),
                    dst_port: dst_addr.port(),
                    ..Default::default()
                };
                let tunnel = tunnel_udp.clone();
                tokio::spawn(async move {
                    mihomo_tunnel::udp::handle_udp(tunnel.inner(), &payload, src_addr, metadata)
                        .await;
                });
            }
        });

        info!("TUN fd listener running");
        std::future::pending::<()>().await;
        Ok(())
    }
}

/// Bidirectional packet relay between raw fd and netstack-smoltcp stack.
async fn relay_packets(device: Arc<AsyncFd<RawTunDevice>>, mut stack: netstack_smoltcp::Stack) {
    let mut tun_buf = vec![0u8; 65535];

    loop {
        tokio::select! {
            // fd → stack: read raw IP packet, feed to netstack
            result = device.readable() => {
                match result {
                    Ok(mut guard) => {
                        match guard.get_inner().read(&mut tun_buf) {
                            Ok(n) if n > 0 => {
                                let pkt = tun_buf[..n].to_vec();
                                guard.clear_ready();
                                if let Err(e) = stack.send(pkt).await {
                                    debug!("fd->stack error: {}", e);
                                    break;
                                }
                            }
                            Ok(_) => { guard.clear_ready(); }
                            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                                guard.clear_ready();
                            }
                            Err(e) => {
                                error!("TUN fd recv error: {}", e);
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        error!("TUN fd readable error: {}", e);
                        break;
                    }
                }
            }
            // stack → fd: read outgoing packet from netstack, write to fd
            Some(result) = stack.next() => {
                match result {
                    Ok(pkt) => {
                        match device.writable().await {
                            Ok(mut guard) => {
                                match guard.get_inner().write(&pkt) {
                                    Ok(_) => { guard.clear_ready(); }
                                    Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                                        guard.clear_ready();
                                    }
                                    Err(e) => {
                                        debug!("stack->fd error: {}", e);
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                error!("TUN fd writable error: {}", e);
                                break;
                            }
                        }
                    }
                    Err(e) => {
                        error!("stack stream error: {}", e);
                        break;
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Volumes/DATA/workspace/BaoLianDeng/Rust/mihomo-ffi && cargo check 2>&1 | head -30`
Expected: Compiles successfully. Note: some mihomo-listener types (like `TunTcpConn`, `DnsServer::handle_query`) may not be public. If so, adapt — e.g., create a simpler TCP conn wrapper or call DNS via UDP directly. Fix any compilation errors.

- [ ] **Step 3: Commit**

```bash
git add Rust/mihomo-ffi/src/tun_fd.rs
git commit -m "Add TunFdListener for iOS fd-based TUN injection"
```

---

### Task 4: Implement logging module

**Files:**
- Create: `Rust/mihomo-ffi/src/logging.rs`

- [ ] **Step 1: Create logging.rs**

Create `Rust/mihomo-ffi/src/logging.rs`:

```rust
use std::ffi::CStr;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::raw::c_char;
use std::sync::Mutex;

use crate::{set_error, cstr_to_str};

static LOG_FILE: Mutex<Option<File>> = Mutex::new(None);

/// # Safety
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_set_log_file(path: *const c_char) -> i32 {
    let path_str = cstr_to_str(path);
    match OpenOptions::new().create(true).append(true).open(path_str) {
        Ok(file) => {
            let mut log = LOG_FILE.lock().unwrap();
            *log = Some(file);
            bridge_log(&format!("Log file opened: {}", path_str));
            0
        }
        Err(e) => {
            set_error(format!("open log file: {}", e));
            -1
        }
    }
}

pub fn bridge_log(msg: &str) {
    if let Ok(mut log) = LOG_FILE.lock() {
        if let Some(ref mut file) = *log {
            let _ = writeln!(file, "[Bridge] {}", msg);
        }
    }
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Volumes/DATA/workspace/BaoLianDeng/Rust/mihomo-ffi && cargo check 2>&1 | head -10`
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
git add Rust/mihomo-ffi/src/logging.rs
git commit -m "Add logging module for bridge log file"
```

---

### Task 5: Implement diagnostics module

**Files:**
- Create: `Rust/mihomo-ffi/src/diagnostics.rs`

- [ ] **Step 1: Create diagnostics.rs**

Create `Rust/mihomo-ffi/src/diagnostics.rs`:

```rust
use std::ffi::CStr;
use std::io::{Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::os::raw::c_char;
use std::time::{Duration, Instant};

use crate::{cstr_to_str, str_to_cstring_ptr};

/// # Safety
/// `host` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_test_direct_tcp(host: *const c_char, port: i32) -> *mut c_char {
    let host_str = cstr_to_str(host);
    let addr = format!("{}:{}", host_str, port);
    let start = Instant::now();
    match TcpStream::connect_timeout(
        &addr.parse().unwrap_or_else(|_| "0.0.0.0:0".parse().unwrap()),
        Duration::from_secs(5),
    ) {
        Ok(_) => {
            let elapsed = start.elapsed();
            str_to_cstring_ptr(&format!("OK: connected to {} in {:?}", addr, elapsed))
        }
        Err(e) => {
            let elapsed = start.elapsed();
            str_to_cstring_ptr(&format!("FAIL after {:?}: {}", elapsed, e))
        }
    }
}

/// # Safety
/// `url` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn bridge_test_proxy_http(url: *const c_char) -> *mut c_char {
    let target_url = cstr_to_str(url);
    let proxy_addr = "127.0.0.1:7890";
    let conn = match TcpStream::connect_timeout(
        &proxy_addr.parse().unwrap(),
        Duration::from_secs(5),
    ) {
        Ok(c) => c,
        Err(e) => return str_to_cstring_ptr(&format!("FAIL proxy connect: {}", e)),
    };
    let _ = conn.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = conn.set_write_timeout(Some(Duration::from_secs(10)));

    let req = format!(
        "GET {} HTTP/1.1\r\nHost: www.baidu.com\r\nConnection: close\r\n\r\n",
        target_url
    );
    let mut conn = conn;
    if let Err(e) = conn.write_all(req.as_bytes()) {
        return str_to_cstring_ptr(&format!("FAIL proxy write: {}", e));
    }

    let mut buf = vec![0u8; 512];
    match conn.read(&mut buf) {
        Ok(n) => {
            let resp = String::from_utf8_lossy(&buf[..n]);
            let first_line = resp.lines().next().unwrap_or("");
            str_to_cstring_ptr(&format!("OK: {}", first_line))
        }
        Err(e) => str_to_cstring_ptr(&format!("FAIL proxy read: {}", e)),
    }
}

/// # Safety
/// `dns_addr` must be a valid null-terminated UTF-8 string like "127.0.0.1:1053".
#[no_mangle]
pub unsafe extern "C" fn bridge_test_dns_resolver(dns_addr: *const c_char) -> *mut c_char {
    let addr_str = cstr_to_str(dns_addr);
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => {
            return str_to_cstring_ptr(&format!("DNS-TEST: FAIL bind: {}", e));
        }
    };
    let _ = sock.set_read_timeout(Some(Duration::from_secs(5)));

    if let Err(e) = sock.connect(addr_str) {
        return str_to_cstring_ptr(&format!("DNS-TEST: FAIL connect to {}: {}", addr_str, e));
    }

    // Build minimal DNS A query for www.baidu.com
    let query = build_dns_query("www.baidu.com");
    if let Err(e) = sock.send(&query) {
        return str_to_cstring_ptr(&format!("DNS-TEST: FAIL write: {}", e));
    }

    let mut buf = vec![0u8; 512];
    match sock.recv(&mut buf) {
        Ok(n) => {
            if let Some(ip) = parse_dns_response_a(&buf[..n]) {
                if ip.starts_with("198.18.") {
                    str_to_cstring_ptr(&format!(
                        "DNS-TEST: OK fake-ip {} for www.baidu.com",
                        ip
                    ))
                } else {
                    str_to_cstring_ptr(&format!(
                        "DNS-TEST: WARN got {} (not in 198.18.0.0/16) for www.baidu.com",
                        ip
                    ))
                }
            } else {
                str_to_cstring_ptr("DNS-TEST: FAIL could not parse A record from response")
            }
        }
        Err(e) => str_to_cstring_ptr(&format!("DNS-TEST: FAIL read: {}", e)),
    }
}

/// # Safety
/// `api_addr` must be a valid null-terminated UTF-8 string like "127.0.0.1:9090".
#[no_mangle]
pub unsafe extern "C" fn bridge_test_selected_proxy(api_addr: *const c_char) -> *mut c_char {
    let addr = cstr_to_str(api_addr);
    let rt = crate::get_runtime();
    let result = rt.block_on(async { test_selected_proxy_async(addr).await });
    str_to_cstring_ptr(&result)
}

async fn test_selected_proxy_async(api_addr: &str) -> String {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
    {
        Ok(c) => c,
        Err(e) => return format!("PROXY-TEST: FAIL build client: {}", e),
    };

    // List proxies
    let url = format!("http://{}/proxies", api_addr);
    let resp = match client.get(&url).send().await {
        Ok(r) => r,
        Err(e) => return format!("PROXY-TEST: FAIL list proxies: {}", e),
    };
    let body: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => return format!("PROXY-TEST: FAIL parse proxies: {}", e),
    };

    let proxies = match body.get("proxies").and_then(|p| p.as_object()) {
        Some(p) => p,
        None => return "PROXY-TEST: FAIL no proxies object".to_string(),
    };

    let builtin = ["DIRECT", "REJECT", "GLOBAL", "default"];

    // Find first Selector group with a real proxy node
    let mut selected_name = None;
    let mut selected_now = None;
    for (name, info) in proxies {
        if builtin.contains(&name.as_str()) {
            continue;
        }
        if info.get("type").and_then(|t| t.as_str()) == Some("Selector") {
            if let Some(now) = info.get("now").and_then(|n| n.as_str()) {
                if now != "DIRECT" && now != "REJECT" && !now.is_empty() {
                    selected_name = Some(name.clone());
                    selected_now = Some(now.to_string());
                    break;
                }
            }
        }
    }

    let (group, now) = match (selected_name, selected_now) {
        (Some(g), Some(n)) => (g, n),
        _ => {
            let names: Vec<&String> = proxies.keys().collect();
            return format!("PROXY-TEST: FAIL no Selector group with proxy node found (groups: {:?})", names);
        }
    };

    // Get proxy type
    let proxy_url = format!("http://{}/proxies/{}", api_addr, now);
    let proxy_type = match client.get(&proxy_url).send().await {
        Ok(r) => {
            let info: serde_json::Value = r.json().await.unwrap_or_default();
            info.get("type")
                .and_then(|t| t.as_str())
                .unwrap_or("unknown")
                .to_string()
        }
        Err(_) => "unknown".to_string(),
    };

    let mut result = format!("PROXY-TEST: group={} selected={} type={}", group, now, proxy_type);

    // Test latency
    let delay_url = format!(
        "http://{}/proxies/{}/delay?url=http://www.gstatic.com/generate_204&timeout=5000",
        api_addr, now
    );
    match client.get(&delay_url).send().await {
        Ok(r) => {
            let info: serde_json::Value = r.json().await.unwrap_or_default();
            if let Some(delay) = info.get("delay").and_then(|d| d.as_i64()) {
                if delay > 0 {
                    result += &format!(" delay={}ms", delay);
                } else if let Some(msg) = info.get("message").and_then(|m| m.as_str()) {
                    result += &format!(" delay=FAIL({})", msg);
                }
            }
        }
        Err(e) => {
            result += &format!(" delay=FAIL({})", e);
        }
    }

    result
}

// DNS helpers (ported from Go bridge)

fn build_dns_query(domain: &str) -> Vec<u8> {
    let mut buf = Vec::with_capacity(64);
    // Header: ID=0x1234, flags=0x0100, QDCOUNT=1
    buf.extend_from_slice(&[0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    for label in domain.split('.') {
        buf.push(label.len() as u8);
        buf.extend_from_slice(label.as_bytes());
    }
    buf.push(0x00); // root label
    buf.extend_from_slice(&[0x00, 0x01]); // QTYPE = A
    buf.extend_from_slice(&[0x00, 0x01]); // QCLASS = IN
    buf
}

fn parse_dns_response_a(msg: &[u8]) -> Option<String> {
    if msg.len() < 12 {
        return None;
    }
    let mut pos = 12;
    let qdcount = (msg[4] as usize) << 8 | msg[5] as usize;
    for _ in 0..qdcount {
        while pos < msg.len() {
            let l = msg[pos] as usize;
            pos += 1;
            if l == 0 { break; }
            if l >= 0xC0 { pos += 1; break; }
            pos += l;
        }
        pos += 4; // QTYPE + QCLASS
    }
    let ancount = (msg[6] as usize) << 8 | msg[7] as usize;
    for _ in 0..ancount {
        if pos < msg.len() && msg[pos] >= 0xC0 {
            pos += 2;
        } else {
            while pos < msg.len() {
                let l = msg[pos] as usize;
                pos += 1;
                if l == 0 { break; }
                pos += l;
            }
        }
        if pos + 10 > msg.len() { break; }
        let rtype = (msg[pos] as usize) << 8 | msg[pos + 1] as usize;
        let rdlen = (msg[pos + 8] as usize) << 8 | msg[pos + 9] as usize;
        pos += 10;
        if rtype == 1 && rdlen == 4 && pos + 4 <= msg.len() {
            return Some(format!("{}.{}.{}.{}", msg[pos], msg[pos + 1], msg[pos + 2], msg[pos + 3]));
        }
        pos += rdlen;
    }
    None
}
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Volumes/DATA/workspace/BaoLianDeng/Rust/mihomo-ffi && cargo check 2>&1 | head -10`
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
git add Rust/mihomo-ffi/src/diagnostics.rs
git commit -m "Add diagnostic test functions (TCP, HTTP, DNS, proxy)"
```

---

### Task 6: Create ObjC wrapper (header + implementation)

**Files:**
- Create: `Rust/mihomo-ffi/objc/MihomoCore.h`
- Create: `Rust/mihomo-ffi/objc/MihomoCore.m`

- [ ] **Step 1: Create MihomoCore.h**

Create `Rust/mihomo-ffi/objc/MihomoCore.h` — the complete ObjC header from the spec (see spec section 2 for the full header). Copy it exactly as specified in the design spec.

- [ ] **Step 2: Create MihomoCore.m**

Create `Rust/mihomo-ffi/objc/MihomoCore.m` — the complete ObjC wrapper implementation. The spec contains the full implementation for all 21 Bridge* functions. **Important:** Ensure ALL 22 C FFI `extern` declarations are present at the top of the file. The complete list of externs needed:

```c
extern void bridge_set_home_dir(const char *path);
extern int32_t bridge_set_config(const char *yaml);
extern int32_t bridge_set_log_file(const char *path);
extern int32_t bridge_set_tun_fd(int32_t fd);
extern int32_t bridge_start_proxy(void);
extern int32_t bridge_start_with_external_controller(const char *addr, const char *secret);
extern void bridge_stop_proxy(void);
extern bool bridge_is_running(void);
extern char *bridge_read_config(void);
extern int32_t bridge_validate_config(const char *yaml);
extern void bridge_update_log_level(const char *level);
extern int64_t bridge_get_upload_traffic(void);
extern int64_t bridge_get_download_traffic(void);
extern void bridge_force_gc(void);
extern const char *bridge_version(void);
extern char *bridge_test_direct_tcp(const char *host, int32_t port);
extern char *bridge_test_proxy_http(const char *url);
extern char *bridge_test_dns_resolver(const char *addr);
extern char *bridge_test_selected_proxy(const char *api_addr);
extern char *bridge_generate_tun_config(int32_t fd, const char *dns_addr);
extern void bridge_free_string(char *ptr);
extern const char *bridge_get_last_error(void);
```

Then implement all 21 ObjC wrapper functions as shown in the spec section 2. Every Bridge* function in MihomoCore.h must have a corresponding implementation.

- [ ] **Step 3: Verify ObjC compiles (host target sanity check)**

Run: `xcrun clang -c Rust/mihomo-ffi/objc/MihomoCore.m -o /tmp/mihomo-test.o -fobjc-arc -IRust/mihomo-ffi/objc -fsyntax-only 2>&1`
Expected: No syntax errors. Linker errors about undefined symbols are expected (the Rust staticlib isn't linked yet).

- [ ] **Step 4: Commit**

```bash
git add Rust/mihomo-ffi/objc/MihomoCore.h Rust/mihomo-ffi/objc/MihomoCore.m
git commit -m "Add ObjC wrapper matching existing gomobile Bridge API"
```

---

### Task 7: Replace Makefile with Rust build

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Replace Makefile content**

Replace `Makefile` with the Rust build system from the spec (see spec section 4 for the full Makefile). Key changes:
- `framework` target builds Rust staticlib for 3 iOS targets, compiles ObjC, combines with libtool, creates xcframework
- `framework-arm64` target for device-only builds
- `clean` removes the framework directory

Use the exact Makefile content from the spec, but update paths:
- `RUST_FFI_DIR = Rust/mihomo-ffi`
- `FFI_OBJC = $(RUST_FFI_DIR)/objc`
- Rust staticlib output at `$(RUST_FFI_DIR)/target/<target>/release/libmihomo_ffi.a`

- [ ] **Step 2: Install Rust iOS targets**

Run: `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`

- [ ] **Step 3: Build framework-arm64 (device only, fastest test)**

Run: `make framework-arm64`
Expected: Builds successfully, produces `Framework/MihomoCore.xcframework/` with device library.

If this fails, debug and fix. Common issues:
- Missing `libc` crate dependency in Cargo.toml (add `libc = "0.2"`)
- Missing system frameworks at link time
- Rust type mismatches with mihomo-rust APIs

- [ ] **Step 4: Build full framework**

Run: `make framework`
Expected: Builds successfully with device + simulator libraries.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "Replace Go build with Rust + ObjC xcframework build"
```

---

### Task 8: Build iOS app with new framework

**Files:**
- No file changes — verification only

- [ ] **Step 1: Build iOS app for simulator**

Run:
```bash
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED. If linker errors about undefined symbols or missing frameworks:
- Add missing system frameworks to Xcode project (e.g., `Security.framework`, `Network.framework`, `SystemConfiguration.framework`)
- Add `-lc++` or `-lresolv` to "Other Linker Flags" if needed by rustls/ring

- [ ] **Step 2: Build for device**

Run:
```bash
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit any Xcode project changes**

If you had to add linker flags or frameworks to the Xcode project:
```bash
git add BaoLianDeng.xcodeproj/project.pbxproj
git commit -m "Add linker flags for Rust staticlib dependencies"
```

---

### Task 9: Remove Go bridge

**Files:**
- Remove: `Go/mihomo-bridge/` (entire directory)
- Remove: `Go/` (if empty)

- [ ] **Step 1: Verify app builds without Go code**

The app should already be building from Task 8. Confirm by running `make framework && xcodebuild build ...` one more time.

- [ ] **Step 2: Remove Go directory**

```bash
rm -rf Go/
```

- [ ] **Step 3: Commit**

```bash
git rm -r Go/
git commit -m "Remove Go bridge (replaced by Rust FFI)"
```

---

### Task 10: Update CI workflow

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Update build-framework job**

Replace the `build-framework` job in `.github/workflows/ci.yml`:

```yaml
  build-framework:
    name: Build Rust Framework
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive

      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-ios,aarch64-apple-ios-sim,x86_64-apple-ios

      - name: Cache Rust artifacts
        uses: actions/cache@v4
        with:
          path: |
            ~/.cargo/registry
            ~/.cargo/git
            Rust/mihomo-ffi/target
          key: ${{ runner.os }}-rust-${{ hashFiles('Rust/mihomo-ffi/Cargo.lock') }}
          restore-keys: ${{ runner.os }}-rust-

      - name: Build MihomoCore.xcframework
        run: make framework

      - name: Upload framework artifact
        uses: actions/upload-artifact@v4
        with:
          name: MihomoCore.xcframework
          path: Framework/MihomoCore.xcframework
          retention-days: 7
```

- [ ] **Step 2: Update build-app and test jobs to use submodules**

Add `submodules: recursive` to the checkout step in `build-app` and `test` jobs (they don't need it for the framework since they download the artifact, but it's good practice for consistency).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Update CI: Go toolchain -> Rust with iOS targets"
```

---

### Task 11: On-device verification

**Files:**
- No file changes — verification only

- [ ] **Step 1: Build and install on device**

```bash
# Find device UDID
xcrun xctrace list devices

# Build for device
xcodebuild build \
  -project BaoLianDeng.xcodeproj \
  -scheme BaoLianDeng \
  -configuration Debug \
  -destination 'id=00008150-001614340CEA401C'

# Install
xcrun devicectl device install app \
  --device 00008150-001614340CEA401C \
  ~/Library/Developer/Xcode/DerivedData/BaoLianDeng-*/Build/Products/Debug-iphoneos/BaoLianDeng.app
```

- [ ] **Step 2: Verify tunnel starts**

Open the app, enable VPN. Check that:
- VPN connects successfully
- Traffic flows (load a webpage)
- Traffic counters update in the Data tab
- No crash in the Network Extension

- [ ] **Step 3: Check diagnostics in tunnel log**

Look for the diagnostic test output in the tunnel log (Settings tab → View Log):
- `OK: connected to ...` (TCP test)
- `OK: HTTP/1.1 200` (HTTP proxy test)
- `DNS-TEST: OK fake-ip 198.18...` (DNS test)
- `PROXY-TEST: group=... selected=...` (proxy test)

---

### Task 12: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update build commands section**

Replace Go framework build commands with Rust equivalents. Update the Architecture section to reflect Rust instead of Go.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Update CLAUDE.md for Rust bridge"
```
