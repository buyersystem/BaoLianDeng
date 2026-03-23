# Replace Go Mihomo Bridge with mihomo-rust

**Date:** 2026-03-23
**Motivation:** Memory efficiency. The Go runtime consumes ~5-8MB in the 15MB Network Extension limit, requiring aggressive GC hacks (5% GC threshold, 8MB heap limit, GOMAXPROCS=1, periodic ForceGC). Rust eliminates the GC entirely.

**Constraint:** The mihomo-rust codebase is read-only. It is included as a git submodule at `Rust/mihomo` (from `https://github.com/madeye/mihomo-rust.git`). All new code lives in the BaoLianDeng repo, depending on mihomo-rust crates via path dependencies relative to the submodule.

## Architecture

### Current (Go)
```
Swift (PacketTunnel) → MihomoCore.xcframework (gomobile/ObjC) → Go mihomo engine
```

### Target (Rust)
```
Swift (PacketTunnel) → MihomoCore.xcframework (C FFI/ObjC wrapper) → Rust mihomo engine
```

The framework name stays `MihomoCore` so the Xcode project config and Swift `import MihomoCore` statements don't change.

## Components

### 1. New crate: `mihomo-ffi` (in BaoLianDeng repo)

**Location:** `Rust/mihomo-ffi/` (replaces `Go/mihomo-bridge/`)

A standalone Rust crate (not part of mihomo-rust workspace) that:
- Declares `crate-type = ["staticlib"]` in Cargo.toml
- Depends on mihomo-rust crates via path dependencies relative to the submodule:
  ```toml
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
  ```
- Exports `extern "C"` functions matching the existing Bridge* ObjC signatures
- Manages a global `OnceLock<Runtime>` for the tokio async runtime
- Manages global state: home dir, config path, TUN fd, running flag, log file
- Contains the `TunFdListener` (fd-based TUN for iOS) since we can't modify mihomo-listener

**Tokio runtime:** Use `tokio::runtime::Builder::new_multi_thread().worker_threads(2)` rather than `new_current_thread()`. Several transitive dependencies (`reqwest` with `rustls-tls`, `hickory-resolver`) use `spawn_blocking` internally, which deadlocks on a single-threaded runtime. Two worker threads keeps overhead low while avoiding deadlocks.

**Source files:**
- `Rust/mihomo-ffi/Cargo.toml`
- `Rust/mihomo-ffi/src/lib.rs` — FFI exports, global state, engine lifecycle
- `Rust/mihomo-ffi/src/tun_fd.rs` — `TunFdListener` for iOS fd injection
- `Rust/mihomo-ffi/src/diagnostics.rs` — test functions (TCP, HTTP, DNS, proxy)
- `Rust/mihomo-ffi/src/logging.rs` — log file + tracing subscriber setup
- `Rust/mihomo-ffi/objc/MihomoCore.h` — ObjC header
- `Rust/mihomo-ffi/objc/MihomoCore.m` — ObjC wrapper implementation

**Exported C functions (22 total):**

```rust
// Setup
#[no_mangle] extern "C" fn bridge_set_home_dir(path: *const c_char)
#[no_mangle] extern "C" fn bridge_set_config(yaml: *const c_char) -> i32  // 0=ok, -1=error
#[no_mangle] extern "C" fn bridge_set_log_file(path: *const c_char) -> i32
#[no_mangle] extern "C" fn bridge_set_tun_fd(fd: i32) -> i32

// Lifecycle
#[no_mangle] extern "C" fn bridge_start_proxy() -> i32
#[no_mangle] extern "C" fn bridge_start_with_external_controller(addr: *const c_char, secret: *const c_char) -> i32
#[no_mangle] extern "C" fn bridge_stop_proxy()
#[no_mangle] extern "C" fn bridge_is_running() -> bool

// Config
#[no_mangle] extern "C" fn bridge_read_config() -> *mut c_char  // returns null + sets error on failure
#[no_mangle] extern "C" fn bridge_validate_config(yaml: *const c_char) -> i32
#[no_mangle] extern "C" fn bridge_update_log_level(level: *const c_char)

// Traffic
#[no_mangle] extern "C" fn bridge_get_upload_traffic() -> i64
#[no_mangle] extern "C" fn bridge_get_download_traffic() -> i64

// Runtime
#[no_mangle] extern "C" fn bridge_force_gc()   // no-op, kept for Swift compatibility
#[no_mangle] extern "C" fn bridge_version() -> *const c_char  // returns static string, do NOT free

// Diagnostics (all return heap-allocated strings, caller must free via bridge_free_string)
#[no_mangle] extern "C" fn bridge_test_direct_tcp(host: *const c_char, port: i32) -> *mut c_char
#[no_mangle] extern "C" fn bridge_test_proxy_http(url: *const c_char) -> *mut c_char
#[no_mangle] extern "C" fn bridge_test_dns_resolver(addr: *const c_char) -> *mut c_char
#[no_mangle] extern "C" fn bridge_test_selected_proxy(api_addr: *const c_char) -> *mut c_char

// iOS-specific (dead code — not called from Swift, but kept for API parity)
#[no_mangle] extern "C" fn bridge_generate_tun_config(fd: i32, dns_addr: *const c_char) -> *mut c_char

// Memory management (called by ObjC wrapper only, never by Swift directly)
#[no_mangle] extern "C" fn bridge_free_string(ptr: *mut c_char)
#[no_mangle] extern "C" fn bridge_get_last_error() -> *const c_char  // returns static thread-local error msg
```

**Error convention:** Functions that can fail return `i32` (0 = success, -1 = error). The error message is stored in a thread-local `static` and retrieved via `bridge_get_last_error()`. This avoids heap-allocated error objects.

**String ownership rules:**
- `bridge_version()` returns `*const c_char` pointing to a `static` string. Do NOT free.
- `bridge_read_config()`, `bridge_test_*()`, `bridge_generate_tun_config()` return heap-allocated `*mut c_char`. Caller MUST free via `bridge_free_string()`.
- `bridge_get_last_error()` returns a thread-local static. Do NOT free.

### 2. ObjC wrapper layer

**Location:** `Rust/mihomo-ffi/objc/`
- `MihomoCore.h` — public header matching the existing gomobile-generated `Bridge.objc.h`
- `MihomoCore.m` — implementation bridging Foundation types ↔ C FFI

The ObjC wrapper converts between Foundation types and the C FFI so Swift call sites don't change. Complete ObjC header:

```objc
// MihomoCore.h
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void BridgeSetHomeDir(NSString * _Nullable path);
FOUNDATION_EXPORT BOOL BridgeSetConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL BridgeSetLogFile(NSString * _Nullable path, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL BridgeSetTUNFd(int32_t fd, NSError * _Nullable * _Nullable error);

FOUNDATION_EXPORT BOOL BridgeStartProxy(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL BridgeStartWithExternalController(NSString * _Nullable addr, NSString * _Nullable secret, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BridgeStopProxy(void);
FOUNDATION_EXPORT BOOL BridgeIsRunning(void);

FOUNDATION_EXPORT NSString * _Nonnull BridgeReadConfig(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL BridgeValidateConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void BridgeUpdateLogLevel(NSString * _Nullable level);

FOUNDATION_EXPORT int64_t BridgeGetUploadTraffic(void);
FOUNDATION_EXPORT int64_t BridgeGetDownloadTraffic(void);

FOUNDATION_EXPORT void BridgeForceGC(void);
FOUNDATION_EXPORT NSString * _Nonnull BridgeVersion(void);

FOUNDATION_EXPORT NSString * _Nonnull BridgeTestDirectTCP(NSString * _Nullable host, int32_t port);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestProxyHTTP(NSString * _Nullable targetURL);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestDNSResolver(NSString * _Nullable dnsAddr);
FOUNDATION_EXPORT NSString * _Nonnull BridgeTestSelectedProxy(NSString * _Nullable apiAddr);

FOUNDATION_EXPORT NSString * _Nonnull BridgeGenerateTUNConfig(int32_t fd, NSString * _Nullable dnsAddr);
```

**Example ObjC wrapper implementation** (demonstrates the BOOL + NSError pattern):

```objc
// MihomoCore.m
#import "MihomoCore.h"

// C FFI declarations (from Rust staticlib)
extern void bridge_set_home_dir(const char *path);
extern int32_t bridge_set_config(const char *yaml);
extern int32_t bridge_start_proxy(void);
extern int32_t bridge_start_with_external_controller(const char *addr, const char *secret);
extern const char *bridge_get_last_error(void);
extern char *bridge_read_config(void);
extern const char *bridge_version(void);
extern char *bridge_test_direct_tcp(const char *host, int32_t port);
extern void bridge_free_string(char *ptr);
// ... etc

static NSError *makeError(void) {
    const char *msg = bridge_get_last_error();
    NSString *desc = msg ? [NSString stringWithUTF8String:msg] : @"Unknown error";
    return [NSError errorWithDomain:@"MihomoCore" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

void BridgeSetHomeDir(NSString * _Nullable path) {
    bridge_set_home_dir([path UTF8String]);
}

BOOL BridgeSetConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_set_config([yamlContent UTF8String]);
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

BOOL BridgeStartProxy(NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_start_proxy();
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

BOOL BridgeStartWithExternalController(NSString * _Nullable addr, NSString * _Nullable secret, NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_start_with_external_controller([addr UTF8String], [secret UTF8String]);
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

void BridgeStopProxy(void) {
    bridge_stop_proxy();
}

BOOL BridgeIsRunning(void) {
    return bridge_is_running() ? YES : NO;
}

NSString * _Nonnull BridgeReadConfig(NSError * _Nullable * _Nullable error) {
    char *result = bridge_read_config();
    if (!result) {
        if (error) *error = makeError();
        return @"";
    }
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

BOOL BridgeValidateConfig(NSString * _Nullable yamlContent, NSError * _Nullable * _Nullable error) {
    int32_t rc = bridge_validate_config([yamlContent UTF8String]);
    if (rc != 0) {
        if (error) *error = makeError();
        return NO;
    }
    return YES;
}

void BridgeUpdateLogLevel(NSString * _Nullable level) {
    bridge_update_log_level([level UTF8String]);
}

int64_t BridgeGetUploadTraffic(void) {
    return bridge_get_upload_traffic();
}

int64_t BridgeGetDownloadTraffic(void) {
    return bridge_get_download_traffic();
}

void BridgeForceGC(void) {
    bridge_force_gc();
}

NSString * _Nonnull BridgeVersion(void) {
    const char *v = bridge_version();
    return [NSString stringWithUTF8String:v];  // static string, no free needed
}

NSString * _Nonnull BridgeTestDirectTCP(NSString * _Nullable host, int32_t port) {
    char *result = bridge_test_direct_tcp([host UTF8String], port);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestProxyHTTP(NSString * _Nullable targetURL) {
    char *result = bridge_test_proxy_http([targetURL UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestDNSResolver(NSString * _Nullable dnsAddr) {
    char *result = bridge_test_dns_resolver([dnsAddr UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeTestSelectedProxy(NSString * _Nullable apiAddr) {
    char *result = bridge_test_selected_proxy([apiAddr UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}

NSString * _Nonnull BridgeGenerateTUNConfig(int32_t fd, NSString * _Nullable dnsAddr) {
    char *result = bridge_generate_tun_config(fd, [dnsAddr UTF8String]);
    NSString *str = [NSString stringWithUTF8String:result];
    bridge_free_string(result);
    return str;
}
```

This means **zero changes to Swift call sites**.

### 3. iOS fd-based TUN listener (in mihomo-ffi)

**Location:** `Rust/mihomo-ffi/src/tun_fd.rs`

Since we cannot modify mihomo-listener, the `TunFdListener` lives in the mihomo-ffi crate. It reuses mihomo-listener's netstack-smoltcp processing pattern but accepts a raw fd:

```rust
use std::os::fd::FromRawFd;

pub struct TunFdListener {
    tunnel: Tunnel,
    fd: i32,
    mtu: u16,
    dns_hijack: Vec<SocketAddr>,
    resolver: Arc<Resolver>,
}
```

**fd → async I/O path:**
Use raw fd I/O directly (avoids dependency on `tun-rs` fd support on iOS):
```rust
use std::os::unix::io::FromRawFd;
let file = unsafe { std::fs::File::from_raw_fd(fd) };
let async_fd = tokio::io::unix::AsyncFd::new(file)?;
// read/write raw IP packets via async_fd
```

This works because the iOS TUN fd is a standard file descriptor that accepts raw IP packets. The `async_fd` feeds packets into the same netstack-smoltcp stack (TCP reassembly, UDP handling, DNS hijack) that `TunListener` uses.

**Wiring through the FFI layer:**

1. `bridge_set_tun_fd(fd)` stores the fd in global state: `static TUN_FD: Mutex<Option<i32>>`
2. `bridge_start_proxy()` / `bridge_start_with_external_controller()`:
   - Loads config via `mihomo_config::load_config()`
   - Checks `TUN_FD` — if `Some(fd)`:
     - Spawns `TunFdListener::new(tunnel, fd, mtu, dns_hijack, resolver).run()` instead of the normal `TunListener`
     - The TUN section of config is ignored (fd overrides device creation)
   - If `None`: proceeds normally (desktop behavior, creates TUN device)
3. No changes needed to mihomo-rust's `TunConfig` or `RawConfig` — the fd injection is handled entirely at the FFI layer

### 4. Build system

**Location:** `Makefile` at BaoLianDeng repo root (replaces Go build)

Build steps:
1. Cross-compile `mihomo-ffi` as `staticlib` for three targets:
   - `aarch64-apple-ios` (device)
   - `aarch64-apple-ios-sim` (Apple Silicon simulator)
   - `x86_64-apple-ios` (Intel simulator)
2. Compile the ObjC wrapper (`MihomoCore.m`) into object files for each target
3. Create combined static libraries with `libtool` (Rust .a + ObjC .o per target)
4. Create fat library for simulator targets with `lipo`
5. Assemble into `MihomoCore.xcframework` via `xcodebuild -create-xcframework`
6. Output to `Framework/MihomoCore.xcframework` (same location as Go build)

```makefile
RUST_FFI_DIR = Rust/mihomo-ffi
FFI_OBJC = $(RUST_FFI_DIR)/objc
FRAMEWORK_DIR = Framework
FRAMEWORK_NAME = MihomoCore

# Rust build flags for iOS
CARGO_FLAGS = --release
RUSTFLAGS_IOS = -C strip=symbols -C lto=thin

.PHONY: framework framework-arm64 clean

framework:
	# Build Rust staticlib for each target
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios-sim
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target x86_64-apple-ios
	# Compile ObjC wrapper for each arch
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o /tmp/mihomo-objc-device.o \
		-target arm64-apple-ios17.0 -fobjc-arc -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o /tmp/mihomo-objc-sim-arm64.o \
		-target arm64-apple-ios17.0-simulator -fobjc-arc -I$(FFI_OBJC)
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o /tmp/mihomo-objc-sim-x86.o \
		-target x86_64-apple-ios17.0-simulator -fobjc-arc -I$(FFI_OBJC)
	# Combine Rust .a + ObjC .o into single .a per target
	xcrun libtool -static -o /tmp/mihomo-device.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios/release/libmihomo_ffi.a /tmp/mihomo-objc-device.o
	xcrun libtool -static -o /tmp/mihomo-sim-arm64.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios-sim/release/libmihomo_ffi.a /tmp/mihomo-objc-sim-arm64.o
	xcrun libtool -static -o /tmp/mihomo-sim-x86.a \
		$(RUST_FFI_DIR)/target/x86_64-apple-ios/release/libmihomo_ffi.a /tmp/mihomo-objc-sim-x86.o
	# Fat library for simulator (arm64 + x86_64)
	lipo -create /tmp/mihomo-sim-arm64.a /tmp/mihomo-sim-x86.a -output /tmp/mihomo-sim.a
	# Create xcframework
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library /tmp/mihomo-device.a -headers $(FFI_OBJC) \
		-library /tmp/mihomo-sim.a -headers $(FFI_OBJC) \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework

framework-arm64:
	cd $(RUST_FFI_DIR) && RUSTFLAGS="$(RUSTFLAGS_IOS)" cargo build $(CARGO_FLAGS) --target aarch64-apple-ios
	xcrun clang -c $(FFI_OBJC)/MihomoCore.m -o /tmp/mihomo-objc-device.o \
		-target arm64-apple-ios17.0 -fobjc-arc -I$(FFI_OBJC)
	xcrun libtool -static -o /tmp/mihomo-device.a \
		$(RUST_FFI_DIR)/target/aarch64-apple-ios/release/libmihomo_ffi.a /tmp/mihomo-objc-device.o
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
	xcodebuild -create-xcframework \
		-library /tmp/mihomo-device.a -headers $(FFI_OBJC) \
		-output $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework

clean:
	rm -rf $(FRAMEWORK_DIR)/$(FRAMEWORK_NAME).xcframework
```

### 5. Config validation

The Go bridge's `ValidateConfig` calls the Go mihomo parser. The Rust FFI implements `bridge_validate_config()` by writing the YAML string to a temp file and calling `mihomo_config::load_config()`, then discarding the result. This avoids modifying mihomo-config to add a `load_config_from_str()` function.

### 6. Swift changes

**None required.** The ObjC wrapper preserves the exact same Foundation-type API signatures. All Bridge* functions have identical signatures to the gomobile-generated versions.

Optional follow-up: remove the 10-second `BridgeForceGC()` timer in `PacketTunnelProvider.swift` since it's now a no-op.

### 7. Git submodule setup

Add mihomo-rust as a git submodule:
```bash
git submodule add https://github.com/madeye/mihomo-rust.git Rust/mihomo
```

This creates:
- `Rust/mihomo/` — the mihomo-rust checkout (read-only, pinned to a commit)
- `.gitmodules` — submodule configuration

Directory layout after migration:
```
Rust/
  mihomo/          ← git submodule (mihomo-rust, read-only)
  mihomo-ffi/      ← new FFI crate (BaoLianDeng repo)
    Cargo.toml
    src/
      lib.rs
      tun_fd.rs
      diagnostics.rs
      logging.rs
    objc/
      MihomoCore.h
      MihomoCore.m
```

### 8. Files to remove

- `Go/mihomo-bridge/` — entire directory (bridge.go, tun_ios.go, go.mod, go.sum, patches/, Makefile)
- `Go/` directory if empty after removal

### 9. CI changes

`.github/workflows/ci.yml`:
- Replace `build-framework` job: Go 1.25 + gomobile → Rust stable + iOS targets
- Add checkout step with `submodules: recursive` (or `git submodule update --init`)
- Add `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios`
- Change build command from `make framework` (gomobile) to `make framework` (cargo + xcodebuild)
- Keep `macos-15` runner (needed for Xcode SDK)

## Key Design Decisions

1. **Static lib + ObjC wrapper** over `cdylib`: iOS doesn't support dynamic loading of third-party dylibs. Static linking is the standard approach. The ObjC wrapper provides Foundation type conversion that Swift expects.

2. **Multi-thread tokio with 2 workers**: `tokio::runtime::Builder::new_multi_thread().worker_threads(2)`. A single-threaded runtime risks deadlocks from `spawn_blocking` calls in `reqwest` (rustls-tls) and `hickory-resolver`. Two threads keeps overhead low (~2MB stack) while being safe.

3. **Global state via `static`**: Mirrors the Go approach. A `Mutex<Option<EngineState>>` holds the running tunnel, listeners, and statistics. `bridge_start_proxy` initializes it; `bridge_stop_proxy` takes and drops it.

4. **Keep framework name `MihomoCore`**: Zero Xcode project changes. The framework is a drop-in replacement.

5. **`BridgeForceGC()` is a no-op**: Swift calls it every 10 seconds. Rather than changing Swift code, we just make it do nothing.

6. **Thread-local error messages**: Instead of heap-allocated `BridgeError` structs, failable functions return `i32` and store error messages in a `thread_local! { static LAST_ERROR: RefCell<String> }`. The ObjC wrapper reads it via `bridge_get_last_error()` and converts to `NSError`.

7. **fd injection bypasses config**: The TUN fd from iOS is stored in FFI global state and passed directly to `TunFdListener`. No changes needed to mihomo-rust's `TunConfig` struct.

8. **`BridgeGenerateTUNConfig` kept as dead code**: Not called from Swift. Kept for API parity. Returns YAML with `stack: gvisor` (not `system` as in the Go version, matching the app's `sanitizeConfig` behavior).

9. **mihomo-rust as git submodule**: Added at `Rust/mihomo/` via `git submodule add`. The mihomo-ffi crate at `Rust/mihomo-ffi/` references it via relative path dependencies (`../mihomo/crates/...`). The submodule is pinned to a specific commit and never modified.

10. **Config validation via temp file**: `bridge_validate_config()` writes YAML to a temp file and calls `mihomo_config::load_config()` rather than modifying mihomo-config. Avoids touching the upstream crate.

## Testing Strategy

1. **Unit tests in mihomo-ffi**: Test FFI functions with mock state (home dir, config parsing)
2. **Integration test**: Build the xcframework, link into a test harness, verify all Bridge* functions work
3. **On-device test**: Install on iPhone, verify tunnel starts, traffic flows, diagnostics pass
4. **Memory profiling**: Compare RSS in Network Extension (Go vs Rust) using Instruments — expect ~5-8MB reduction

## Risk Mitigation

- **`tun-rs` fd support on iOS**: Use raw `std::fs::File::from_raw_fd()` + `tokio::io::unix::AsyncFd` directly, avoiding `tun-rs` for the iOS fd path. The netstack-smoltcp layer only needs raw IP packets.
- **ring crate on iOS**: `ring` has established iOS support (used by many iOS Rust projects). Verify compilation for all three targets in CI.
- **Binary size**: Rust staticlib may be larger than Go xcframework. Mitigate with `-C strip=symbols -C lto=thin`. Monitor in CI.
- **Config compatibility**: The Rust YAML parser (`serde_yaml`) may differ from Go's on edge cases. Test with the app's actual subscription configs.
- **Linker flags**: The Rust staticlib may need additional system frameworks linked (e.g., `Security.framework` for ring, `Network.framework`). Add to Xcode project's "Other Linker Flags" or embed in the xcframework's Info.plist.
- **Submodule in CI**: CI checkout must use `submodules: recursive` or run `git submodule update --init`. The path dependencies (`../mihomo/crates/...`) are relative to `Rust/mihomo-ffi/` and resolve within the repo.
