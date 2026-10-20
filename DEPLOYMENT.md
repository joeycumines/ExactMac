# Deploying ExactMac on macOS

ExactMac automates the macOS desktop by driving Accessibility APIs, synthesizing Core Graphics input events, managing windows through AppKit, and capturing display frames through ScreenCaptureKit. Because these frameworks interface directly with the WindowServer and the system Privacy & Security (TCC) subsystem, ExactMac cannot run as a detached background daemon or root daemon. It requires a window-server session belonging to the logged-in user.

This guide provides deployment instructions across the full scope of configurations:

1. Interactive Menu-Bar Console (`ExactMacConsole.app`) (Primary): A single-process application that embeds the Swift gRPC server, displays native operator approval prompts, records a hash-chained audit decision log, and registers for start-at-login via `ServiceManagement`.
2. Background Service via LaunchAgent (`ExactMacServer.app`): A headless Swift gRPC service running as a per-user LaunchAgent in the GUI domain, designed for automated, unattended, or headless testing environments.
3. Standalone Manual Process and Loopback TCP: Direct command-line invocation of the server and MCP binaries, suitable for debugging, test harnesses, and CI pipelines.
4. Networked Streamable HTTP Transport (`exactmac http`): Model Context Protocol served over HTTP with bearer-token authentication for remote or containerized agent hosts.

> Scope: This documentation targets a single-user development or workstation installation on macOS. Distributing pre-built binaries to third-party Macs requires an Apple Developer ID, Hardened Runtime entitlements, notarization, and stapling.

All make targets execute from the repository root. The target catalogs are defined in [`make/exactmac.mk`](make/exactmac.mk) and [`make/macos.mk`](make/macos.mk). Run `gmake help` for the authoritative catalog.

## Architecture Overview

```text
┌───────────────────────┐            MCP over stdio            ┌───────────────────────┐
│  AI Agent Host        │ ◄──────────────────────────────────► │  exactmac mcp         │
│  (OpenCode / Claude)  │                                      │  (Go CLI Process)     │
└───────────────────────┘                                      └───────────┬───────────┘
                                                                           │ gRPC
                                                                           │ Unix socket (0600)
                                                                           ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ PRIMARY TARGET: ExactMacConsole.app (Single-Process Menu-Bar Application)            │
│                                                                                      │
│  ┌─────────────────────────┐   ┌─────────────────────────┐   ┌────────────────────┐  │
│  │ Swift gRPC Server       │   │ Interactive Consent UI  │   │ Audit Decision Log │  │
│  │ (Embedded Service)      │   │ (AppKit Operator Sheet) │   │ (Hash-Chained Log) │  │
│  └─────────────────────────┘   └─────────────────────────┘   └────────────────────┘  │
│                                                                                      │
│  Supervision: ServiceManagement (SMAppService.mainApp)                               │
│  Socket: ~/Library/Application Support/ExactMac/exactmac.sock (0600)                 │
└──────────────────────────────────────────┬───────────────────────────────────────────┘
                                           │
                                           │ Alternative Deployment Target
                                           ▼
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ SECONDARY TARGET: ExactMacServer.app (Headless Background Service)                   │
│                                                                                      │
│  ┌─────────────────────────┐   ┌─────────────────────────┐                           │
│  │ Swift gRPC Server       │   │ Headless Authorization  │                           │
│  │ (Standalone Binary)     │   │ (Fail-Closed Denials)   │                           │
│  └─────────────────────────┘   └─────────────────────────┘                           │
│                                                                                      │
│  Supervision: launchd (gui/<uid>/io.github.joeycumines.exactmac.server)              │
│  Socket: ~/Library/Application Support/ExactMac/exactmac.sock (0600)                 │
└──────────────────────────────────────────┬───────────────────────────────────────────┘
                                           │
                                           ▼
                       Accessibility / CGEvent / ScreenCaptureKit
```

### Component Roles

- `ExactMacConsole.app` (Primary): The unified desktop product. One application process hosts the gRPC server, the authorization engine, in-memory grant envelopes, the hash-chained decision audit log, and the native AppKit consent prompts presented to the operator. It runs as a menu-bar accessory (`LSUIElement`) with no Dock icon.
- `ExactMacServer.app` (Secondary): The headless background server. It houses the gRPC accessibility endpoints and authorization interceptor without any graphical user interface. When running headless, requests requiring operator consent fail closed.
- `exactmac`: The Go CLI binary. When invoked as `exactmac mcp`, it speaks Model Context Protocol over standard I/O with the agent host and proxies commands via gRPC to the Swift server over an owner-only Unix socket. It requires neither Accessibility nor Screen Recording permissions.

## Prerequisites and Toolchain Verification

ExactMac requires modern macOS development tooling matching repository declarations:

- macOS 15.0 (Sequoia) or later: Declared in `Server/Package.swift` and `Console/Package.swift`.
- Swift 6.0 or later: Declared in `// swift-tools-version: 6.0`.
- Go 1.26+: Declared in `go.mod`.
- Buf CLI: Required to build protobuf descriptor sets for gRPC reflection (`buf.descriptor-sets`).
- GNU Make 4.0 or later (`gmake`): Homebrew GNU Make is required; BSD make is unsupported.
- Xcode Command Line Tools: Provides `swift`, `codesign`, `plutil`, `ditto`, `xattr`, and `spctl`.
- grpcurl (optional): Useful for low-level gRPC inspection and testing.

Install required dependencies via Homebrew:

```sh
xcode-select --install
brew install go make bufbuild/buf/buf grpcurl
```

Validate the development environment, toolchain versions, and repository paths:

```sh
gmake exactmac.doctor
```

## Primary Deployment: Interactive Menu-Bar Console

`ExactMacConsole.app` is the primary and recommended deployment mechanism for interactive workstation use. It combines the gRPC server and operator consent interface into a single application bundle.

### Quick Start Installation

Execute the unified installation target:

```sh
gmake exactmac.console-install
```

This single command executes the end-to-end installation sequence:

1. Builds the Swift console application: Compiles `ExactMacConsole` and its resource bundles in release mode.
2. Builds the Go MCP proxy: Compiles `exactmac` and installs it to `$(go env GOBIN)/exactmac`.
3. Packages the application bundle: Creates `ExactMacConsole.app` with `Info.plist`, resource bundles, application icons, and menu bar template glyphs.
4. Signs and verifies: Signs the bundle ad-hoc (or with `MACOS_SIGN_IDENTITY`) and executes strict recursive verification (`codesign --verify --deep --strict`).
5. Deploys to Applications: Copies the bundle to `~/Applications/ExactMacConsole.app` and registers it with LaunchServices (`lsregister -f`).
6. Configures state directory: Creates `~/Library/Application Support/ExactMac/` with owner-only `0700` permissions.
7. Retires legacy LaunchAgents: Unloads and removes any superseded launchd configurations (`io.github.joeycumines.exactmac.server` or legacy console plists).

### First Launch and Permissions

Launch the application:

```sh
open -a ~/Applications/ExactMacConsole.app
```

On first launch, macOS presents system prompts requesting required privacy grants:

1. Accessibility: Grants permission to query the AX tree and synthesize keyboard/mouse events.
2. Screen Recording: Grants permission to capture display frames and window contents via ScreenCaptureKit.

> One-Time Identity Migration: TCC permissions are keyed to an application bundle identity. If upgrading from a previous two-process deployment (`io.github.joeycumines.exactmac.server`), macOS will request grants for `com.exactmac.console` once.

To enable start-at-login:
Click the helmet icon in the macOS menu bar, and toggle Start at Login. ExactMac uses Apple's modern `ServiceManagement.SMAppService.mainApp` API. macOS may display a system notification confirming that login item registration in System Settings → General → Login Items.

### Menu Bar Status Indicators

The menu bar icon (`MenuBarGlyph.svg`) provides real-time operational feedback:

- Template Helmet: Normal operation. The gRPC server is listening and ready to prompt for consent.
- Dimmed Helmet (38% opacity): Server is stopped or inactive.
- Helmet with Amber Dot: Degraded or headless operation. The server cannot display interactive consent prompts (e.g. running in a headless SSH session or display sleep), causing all consent-requiring capabilities to deny fail-closed.

### The Decision Audit Log

Every RPC decision is recorded in `~/Library/Application Support/ExactMac/audit.log` prior to handler execution. The log uses forward SHA-256 hash chaining:

- Each record contains a cryptographic hash of the preceding entry.
- Modifying or removing any past entry invalidates all subsequent hashes in the chain.
- The log file is created with owner-only mode `0600` inside the `0700` state directory.
- Verification begins at the first record in the file, allowing audit continuity across application restarts.

### Console Lifecycle Commands

| Target | Description |
|---|---|
| `gmake exactmac.console-install` | Full build, sign, installation, LaunchServices registration, and legacy agent retirement. |
| `gmake exactmac.console-status` | Reports bundle location, signature validity, server socket, state directory, and MCP binary status. |
| `gmake exactmac.console-stop` | Gracefully terminates running `ExactMacConsole` instances via AppleScript with process polling fallback. |
| `gmake exactmac.console-uninstall` | Stops app, unregisters bundle, removes `~/Applications/ExactMacConsole.app`, removes MCP binary, and deletes active socket. |
| `gmake exactmac.retire-launchagents-status` | Inspects whether legacy LaunchAgents are currently installed or loaded without making changes. |
| `gmake exactmac.retire-launchagents` | Unloads and removes legacy launchd LaunchAgent plists directly. |

## Alternative Deployment 1: Background Service via LaunchAgent

For headless servers, automated CI test runners, or developer environments requiring pure background operation without a menu-bar UI, ExactMac provides `ExactMacServer.app` managed by launchd.

### Installation and Bootstrapping

Install the LaunchAgent deployment:

```sh
gmake exactmac.install
```

This target runs an ordered pipeline:

1. `exactmac.doctor`: Validates the environment and toolchain dependencies.
2. `exactmac.build-server`: Builds the release `exactmac-server` binary and generates protobuf descriptor sets.
3. `exactmac.build-mcp`: Builds and installs the Go MCP proxy binary.
4. `exactmac.stop`: Unloads any existing LaunchAgent instance from launchd.
5. `exactmac.bundle`: Packages `~/Applications/ExactMacServer.app` including SwiftPM resource bundles.
6. `exactmac.sign`: Clears extended attributes, signs the bundle, and verifies the signature.
7. `exactmac.register`: Registers `ExactMacServer.app` with LaunchServices.
8. `exactmac.launchd`: Writes `~/Library/LaunchAgents/io.github.joeycumines.exactmac.server.plist` and bootstraps it into `gui/$(id -u)`.
9. `exactmac.verify`: Validates runtime health, socket permissions, descriptor presence, and process state.

### LaunchAgent Supervision Semantics

The LaunchAgent configuration adheres to macOS daemon design principles:

- Target Domain: Runs in the user GUI domain `gui/<uid>/io.github.joeycumines.exactmac.server`.
- KeepAlive and Restart Protection: `KeepAlive=true` keeps the server resident. `ThrottleInterval=10` prevents rapid restart loops if fatal errors occur.
- Umask: `Umask=63` (octal `0077`) ensures that created files and directories remain strictly owner-private.
- Socket Ownership and Locking: The server binds its own Unix socket at `~/Library/Application Support/ExactMac/exactmac.sock` using an atomic lockfile (`exactmac.sock.owner`). A socket left by an abnormal process termination is safely reclaimed; a socket held by an active process causes startup to fail cleanly.

### LaunchAgent Lifecycle Commands

| Target | Description |
|---|---|
| `gmake exactmac.status` | Inspects launchd service status, running PID, socket file permissions, code signature, and MCP binary. |
| `gmake exactmac.start` | Bootstraps and starts the LaunchAgent service without rebuilding code. |
| `gmake exactmac.restart` | Restarts the running service via `launchctl kickstart -k`. |
| `gmake exactmac.stop` | Unloads the service from launchd while preserving the installed bundle and TCC grants. |
| `gmake exactmac.logs` | Streams recent stdout, stderr, and OSLog unified logging entries. |
| `gmake exactmac.verify` | Executes strict assertions across bundle files, resources, signatures, launchd status, and socket mode. |
| `gmake exactmac.uninstall` | Unloads LaunchAgent, removes plist, application bundle, logs, MCP binary, and resets TCC records. |

## Alternative Deployment 2: Standalone Manual Process and Loopback TCP

For debugging with breakpoints, running under LLDB, or continuous integration environments where macOS application bundles and LaunchAgents are unwieldy, the server and proxy can run directly from the terminal.

### Standalone Server via Loopback TCP

Run the compiled server executable directly:

```sh
GRPC_LISTEN_ADDRESS=127.0.0.1 GRPC_PORT=50051 Server/.build/release/exactmac-server
```

Connect the Go MCP proxy using matching TCP settings:

```sh
EXACTMAC_SERVER_ADDR=127.0.0.1:50051 $(go env GOBIN)/exactmac mcp
```

> Security Mandate (Standing Invariant 8): A TCP listener has no access to local Unix peer process credentials (`LOCAL_PEERPID`). Because the caller's code identity cannot be cryptographically verified over TCP, the server operates in a headless/unauthenticated posture: every capability requiring operator consent is denied fail-closed. Only non-privileged inspection methods operate over TCP.

### Standalone Server via Manual Unix Socket

Run the server with a dedicated Unix socket path:

```sh
GRPC_UNIX_SOCKET=/tmp/exactmac.sock Server/.build/release/exactmac-server &
EXACTMAC_SERVER_SOCKET_PATH=/tmp/exactmac.sock $(go env GOBIN)/exactmac mcp
```

When started outside of an application bundle and window-server context, the server classifies itself as `headless`.

## Alternative Deployment 3: Streamable HTTP Transport

When AI agent hosts reside inside containers, virtual machines, or remote environments where standard I/O piping is unavailable, the Go proxy can serve Model Context Protocol over HTTP (Streamable HTTP / SSE):

```sh
MCP_HTTP_ADDRESS=127.0.0.1:8080 \
MCP_API_KEY="secret-token-here" \
MCP_RATE_LIMIT=50 \
$(go env GOBIN)/exactmac http
```

### HTTP Transport Security Directives

- Loopback Enforcement: Bind `MCP_HTTP_ADDRESS` strictly to `127.0.0.1`. Never expose raw HTTP endpoints to public or shared networks without a reverse proxy providing TLS termination and mutual authentication.
- Authentication: `MCP_API_KEY` enforces HTTP Bearer token authentication on all endpoints.
- Rate Limiting: `MCP_RATE_LIMIT` bounds incoming requests per second to defend against denial-of-service.
- Audit Logging: `MCP_AUDIT_LOG_FILE` logs transport-level HTTP request metadata without recording sensitive payloads.

## Code Signing and Identity Management

macOS Privacy & Security (TCC) binds granted permissions to an application's cryptographic code identity: specifically, its designated requirement and code hash.

### Ad-Hoc Signing vs. Persistent Apple Development Identity

- Ad-Hoc Signing (`-`) (Default):
  - Requires no Apple Developer account or provisioning profile.
  - Generates an ad-hoc signature valid for local execution.
  - Trade-off: Rebuilding or re-linking modifies the binary's code hash (`cdhash`). Under ad-hoc signatures, macOS treats modified binaries as different applications, frequently requiring the operator to re-grant Accessibility and Screen Recording permissions after recompilation.
  - Gatekeeper: `spctl --assess` rejects ad-hoc signatures by default (`rejected`), which `macos.verify` verifies as expected behavior.
  - Login Item Support: `ServiceManagement.SMAppService.mainApp` accepts ad-hoc signatures for start-at-login.

- Apple Development Identity (Recommended for Iteration):
  - Binds the build to a consistent team identifier and designated requirement.
  - Preserves Accessibility and Screen Recording permissions across iterative code modifications.
  - Discover available signing identities:
    ```sh
    security find-identity -v -p codesigning
    ```
  - Install with a persistent identity:
    ```sh
    gmake exactmac.console-install MACOS_SIGN_IDENTITY="Apple Development: Developer Name (TEAMID)"
    ```
    (For LaunchAgent deployments, use `EXACTMAC_SIGN_IDENTITY="Apple Development: ..."`).

### Signing Rules and Extended Attributes

Extended attributes (`com.apple.quarantine`, resource forks) can invalidate signatures. The makefiles strip attributes via `xattr -cr` prior to signing.
Do not use `codesign --deep` when signing; nested resource bundles and code structures must be signed from the inside out. Strict verification (`codesign --verify --deep --strict`) is used during post-build validation.

## Why the SwiftPM Resource Bundle Matters

Both `ExactMacServer` and `ExactMacConsole` depend on generated protobuf descriptor sets (`DescriptorSets`) and application resources. `Package.swift` bundles these via:

```swift
resources: [
    .copy("DescriptorSets"),
]
```

SwiftPM compiles these resources into a standalone `.bundle` directory:
- `ExactMacConsole_ExactMacConsole.bundle` (Console application)
- `ExactMacServer_ExactMacServer.bundle` (Server application)

At runtime, SwiftPM's generated `Bundle.module` accessor locates resources relative to `Bundle.main.bundleURL` inside `Contents/Resources/`. If only the raw executable binary is moved or deployed, resource lookups fall back to compile-time source tree paths, causing fatal lookup errors or blank descriptor tables if the build tree is modified or cleaned.

The makefile bundling targets (`macos.bundle` and `exactmac.bundle`) stage all `*.bundle` directories into `Contents/Resources/`, and `exactmac.verify` asserts descriptor presence before installation completes.

## Installed Artifacts and Path Reference

| Artifact | Primary (Console) Path | Secondary (Server) Path | Permissions / Notes |
|---|---|---|---|
| Application Bundle | `~/Applications/ExactMacConsole.app` | `~/Applications/ExactMacServer.app` | Standard application bundle directory |
| Main Executable | `.../Contents/MacOS/ExactMacConsole` | `.../Contents/MacOS/ExactMacServer` | Mach-O 64-bit executable |
| Resource Bundles | `.../Contents/Resources/*.bundle` | `.../Contents/Resources/*.bundle` | Contains protobuf `*.pb` descriptor sets |
| Application Icons | `.../Contents/Resources/AppIcon.icns` | N/A | Bundled with optical size classes |
| Menu Bar Glyphs | `.../Contents/Resources/MenuBarGlyph.svg` | N/A | Vector stencil template for status item |
| Go MCP Binary | `$(go env GOBIN)/exactmac` | `$(go env GOBIN)/exactmac` | Resolved via `go env GOBIN` or `GOPATH/bin` |
| gRPC Unix Socket | `~/Library/Application Support/ExactMac/exactmac.sock` | `~/Library/Application Support/ExactMac/exactmac.sock` | Mode `srw-------` (`0600`) |
| Socket Lockfile | `.../exactmac.sock.owner` | `.../exactmac.sock.owner` | Prevents split-brain process binding |
| Application State Dir | `~/Library/Application Support/ExactMac/` | `~/Library/Application Support/ExactMac/` | Mode `0700` (refused if permissions loose) |
| Audit Decision Log | `~/Library/Application Support/ExactMac/audit.log` | `~/Library/Application Support/ExactMac/audit.log` | Mode `0600` (forward hash-chained) |
| LaunchAgent Plist | N/A | `~/Library/LaunchAgents/io.github.joeycumines.exactmac.server.plist` | Mode `0600` |
| Standard Diagnostics | OSLog (`io.github.joeycumines.exactmac.console`) | `~/Library/Logs/exactmac.log` / `exactmac.error.log` | Console streams to unified logging; LaunchAgent writes to log files |

## Connecting an AI Agent via MCP

Configure AI agent hosts (OpenCode, Claude Code, Cursor) to communicate with ExactMac via the Go MCP proxy.

### Locating Binaries and Socket Endpoints

Determine the absolute paths on your workstation:

```sh
GOBIN_PATH="$(go env GOBIN)"
[ -z "$GOBIN_PATH" ] && GOBIN_PATH="$(go env GOPATH | cut -d: -f1)/bin"
printf 'MCP Binary: %s/exactmac\n' "$GOBIN_PATH"
printf 'Socket:     %s/Library/Application Support/ExactMac/exactmac.sock\n' "$HOME"
```

### OpenCode Configuration (`opencode.jsonc`)

To configure OpenCode, place `opencode.jsonc` in the root of your project:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "exactmac": {
      "type": "local",
      "command": ["/Users/YOU/go/bin/exactmac", "mcp"],
      "enabled": true,
      "environment": {
        "EXACTMAC_SERVER_SOCKET_PATH": "/Users/YOU/Library/Application Support/ExactMac/exactmac.sock"
      },
      "timeout": 10000
    }
  }
}
```

> Path Note: Paths must be absolute. The `~` tilde expansion is not resolved by MCP host process executors. `timeout` is specified in milliseconds and sets the deadline for tool discovery.

### Stale MCP Host Process Detection

When recompiling the Go MCP proxy (`gmake exactmac.build-mcp`), agent hosts often keep existing `exactmac mcp` subprocesses running in memory. Test for running processes that do not match the on-disk binary timestamp:

```sh
gmake exactmac.check-mcp-host
```

If stale processes are detected, terminate them so the agent host respawns the fresh binary:

```sh
pkill -f "exactmac mcp"
```

## Runtime Configuration Reference

### Swift Server and Console Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `GRPC_UNIX_SOCKET` | `~/Library/Application Support/ExactMac/exactmac.sock` | Filesystem path for the gRPC Unix listener. Takes precedence over TCP settings. |
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | Loopback bind address when running without a Unix socket. |
| `GRPC_PORT` | `8080` (Standalone) | TCP port when running without a Unix socket. |
| `EXACTMAC_HEADLESS` | `0` | Set to `1` or `true` to force headless mode, disabling the interactive operator UI. |

### Go MCP Proxy Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `EXACTMAC_SERVER_SOCKET_PATH` | `~/Library/Application Support/ExactMac/exactmac.sock` (when `EXACTMAC_SERVER_ADDR` unset) | Unix socket path to connect to the Swift server. Takes precedence over TCP. |
| `EXACTMAC_SERVER_ADDR` | `127.0.0.1:50051` | Fallback gRPC TCP endpoint used only when no Unix socket path is provided. |
| `EXACTMAC_REQUEST_TIMEOUT` | `135` | gRPC deadline timeout in seconds for individual tool calls (provides 45s headroom over 90s server consent timeout). |
| `EXACTMAC_DEBUG` | `false` | Enables verbose debug logging to stderr in the Go proxy. |
| `MCP_HTTP_ADDRESS` | `127.0.0.1:8080` | Bind address when running in Streamable HTTP mode (`exactmac http`). |
| `MCP_HTTP_SOCKET` | empty | Unix socket path for Streamable HTTP transport. |
| `MCP_API_KEY` | empty | Bearer token authentication key for HTTP transport. |
| `MCP_RATE_LIMIT` | `0` | Maximum requests per second (0 disables rate limiting). |
| `MCP_AUDIT_LOG_FILE` | empty | File path for transport-level HTTP request audit logging. |
| `MCP_SHELL_COMMANDS_ENABLED` | `false` | Controls whether arbitrary shell execution tools are enabled in the proxy. |

## Screen Capture and Display Coordinate Systems

### ScreenCaptureKit Dimension Calculation

ExactMac captures screenshots using ScreenCaptureKit's single-frame API (`SCScreenshotManager.captureImage`). To avoid capture distortion across high-DPI Retina screens and display arrangements, capture frame dimensions are computed explicitly from the content filter:

```swift
let scale = CGFloat(filter.pointPixelScale)
config.width = Int(filter.contentRect.width * scale)
config.height = Int(filter.contentRect.height * scale)
```

Deriving dimensions from `contentRect` and `pointPixelScale` accounts for fractional display scaling and menu-bar exclusions more reliably than querying raw screen resolutions.

### Coordinate Systems

macOS uses two distinct coordinate systems:

1. Global Display Coordinates (Top-Left Origin):
   - Used by Accessibility (`AXUIElement`), Core Graphics events (`CGEvent`), and `CGWindowList`.
   - Origin `(0, 0)` is at the top-left corner of the primary display. Y values increase downward.
   - Secondary monitors located above or to the left of the primary screen have negative coordinates.
   - All bounds returned by ExactMac APIs and all input coordinates passed to ExactMac use Global Display Coordinates.
2. AppKit Coordinates (Bottom-Left Origin):
   - Used by `NSWindow`, `NSScreen`, and Cocoa views. Origin is at the bottom-left of the primary display.
   - ExactMac handles AppKit coordinate translation internally; clients should never submit AppKit coordinates.

## TCC Privacy Permissions Lifecycle

### Required Privileges

| Permission | System Settings Panel | Subsystem Used | Why It Is Needed |
|---|---|---|---|
| Accessibility | Privacy & Security → Accessibility | `AXUIElement`, `CGEvent` | Inspecting UI hierarchy, simulating clicks, keyboard input, window actions |
| Screen Recording | Privacy & Security → Screen & System Audio Recording | `ScreenCaptureKit` | Capturing screenshots of displays, applications, and windows |

### Granting and Revoking Permissions

macOS enforces TCC permissions at the kernel level. An application cannot programmatically grant itself permissions.
When an application first attempts an AX or capture operation, macOS displays an authorization dialog.
If a permission grant is toggled off or modified, restart the application for changes to take effect:

```sh
gmake exactmac.console-stop
open -a ~/Applications/ExactMacConsole.app
```

### Resetting Stale TCC Records

During development, changing bundle signatures can leave invalid or orphaned entries in macOS TCC databases. To reset TCC entries for both the Console and legacy Server identifiers:

```sh
gmake exactmac.tcc-reset
```

After resetting, re-enable permissions in System Settings and relaunch the application.

## Makefile Target Catalog

### Console Targets

| Target | Description |
|---|---|
| `gmake exactmac.console-build` | Compiles the release Swift console executable. |
| `gmake exactmac.console-app` | Packages `ExactMacConsole.app`, copying resources, Info.plist, and icons. |
| `gmake exactmac.console-sign` | Signs the console bundle and verifies signature integrity. |
| `gmake exactmac.console-register` | Registers `ExactMacConsole.app` with LaunchServices. |
| `gmake exactmac.console-install` | Ordered build, sign, packaging, registration, and MCP installation target. |
| `gmake exactmac.console-status` | Displays console bundle, socket, signature, and MCP executable status. |
| `gmake exactmac.console-stop` | Quits active console instances gracefully. |
| `gmake exactmac.console-uninstall` | Removes installed console application, socket, and Go MCP binary. |
| `gmake exactmac.retire-launchagents-status` | Reports presence of legacy LaunchAgents without making changes. |
| `gmake exactmac.retire-launchagents` | Unloads and removes superseded legacy LaunchAgent plists. |

### Server and LaunchAgent Targets

| Target | Description |
|---|---|
| `gmake exactmac.doctor` | Checks local development environment, tools, and repository layout. |
| `gmake exactmac.build-server` | Builds the release headless Swift server and generates descriptor sets. |
| `gmake exactmac.build-mcp` | Builds and installs the Go MCP proxy CLI. |
| `gmake exactmac.bundle` | Packages `ExactMacServer.app` with descriptor resource bundles. |
| `gmake exactmac.sign` | Signs `ExactMacServer.app` and verifies signature recursively. |
| `gmake exactmac.register` | Registers `ExactMacServer.app` with LaunchServices. |
| `gmake exactmac.launchd` | Writes, bootstraps, and starts the LaunchAgent service. |
| `gmake exactmac.install` | Complete automated installation sequence for the headless LaunchAgent service. |
| `gmake exactmac.verify` | Strict assertion runner validating app, bundle, signature, service, socket, and MCP. |
| `gmake exactmac.status` | Inspects LaunchAgent service, running state, socket permissions, and MCP binary. |
| `gmake exactmac.start` | Starts the LaunchAgent without rebuilding. |
| `gmake exactmac.restart` | Forces a restart of the running LaunchAgent. |
| `gmake exactmac.stop` | Unloads the LaunchAgent while preserving application files. |
| `gmake exactmac.logs` | Tail stdout, stderr, and unified log output. |
| `gmake exactmac.tcc-reset` | Clears TCC records for Accessibility and ScreenCapture. |
| `gmake exactmac.uninstall` | Complete removal of Server app, LaunchAgent plist, logs, and TCC records. |

## Troubleshooting and Diagnostic Procedures

### Every Consent-Requiring Call Is Denied

- Symptom: Calling `click_element`, `open_app`, or `type` returns permission denied or fail-closed refusal.
- Cause: The server is operating in a headless posture. The process either lacks an active WindowServer session (e.g. running over SSH or screen locked), is running in headless mode (`EXACTMAC_HEADLESS=1`), or is communicating over loopback TCP without peer credentials.
- Remedy:
  1. Verify the console app is running in the user's GUI desktop session:
     ```sh
     gmake exactmac.console-status
     ```
  2. Inspect the operational posture logged by the console:
     ```sh
     log show --last 5m --predicate 'subsystem == "io.github.joeycumines.exactmac.console"'
     ```
     If the posture reports `headless`, ensure the workstation display is awake and unlocked.

### Socket Missing or `no such file or directory`

- Symptom: MCP proxy fails to connect to `~/Library/Application Support/ExactMac/exactmac.sock`.
- Cause: The server application is not running, or an external script removed the active socket node.
- Remedy:
  1. Launch the console app:
     ```sh
     open -a ~/Applications/ExactMacConsole.app
     ```
  2. If the process is alive but the socket file is missing from disk (e.g. unlinked by an over-eager cleanup script), quit the app and restart it to re-bind the socket:
     ```sh
     gmake exactmac.console-stop
     rm -f ~/Library/Application\ Support/ExactMac/exactmac.sock*
     open -a ~/Applications/ExactMacConsole.app
     ```

### Stale MCP Host Process

- Symptom: Updates made to Go MCP tools do not take effect when called from the AI agent.
- Cause: The agent host (IDE or MCP client) keeps a spawned `exactmac mcp` process resident across edits.
- Remedy:
  ```sh
  gmake exactmac.check-mcp-host
  pkill -f "exactmac mcp"
  ```

### Missing Protobuf Descriptor Bundle

- Symptom: Server starts, but incoming gRPC calls fail with unrecognized method errors or reflection lookups fail.
- Cause: The SwiftPM resource bundle containing `*.pb` descriptor files was omitted during assembly.
- Remedy: Check that the resource bundle exists inside the application:
  ```sh
  find ~/Applications/ExactMacConsole.app -name '*.pb' -print
  ```
  Rebuild and reinstall using the unified make target:
  ```sh
  gmake exactmac.console-install
  ```

### TCC Privacy Prompts Fail to Appear

- Symptom: Running ExactMac actions fails with accessibility or screen recording errors, but macOS displays no approval dialog.
- Cause: macOS presents the consent prompt only once per application identity. If previously denied or dismissed, macOS silently drops future requests.
- Remedy:
  1. Open System Settings → Privacy & Security → Accessibility and manually add `~/Applications/ExactMacConsole.app`.
  2. Open System Settings → Privacy & Security → Screen & System Audio Recording and manually add the same app.
  3. Alternatively, reset the system database:
     ```sh
     gmake exactmac.tcc-reset
     ```

### Secure Event Input Timeouts on Password Fields

- Symptom: Typing into password inputs (`AXSecureTextField` or web password fields) produces `type failed: timed out waiting for routed input token`.
- Cause: When secure fields gain focus, macOS activates `EnableSecureEventInput`, intentionally suppressing all keyboard `CGEventTap` callbacks system-wide to block keyloggers.
- Remedy: Use clipboard staging and AppleScript keystroke dispatch instead of raw event taps:
  1. Set clipboard content: `clipboard(action="set", text="<secret>")`.
  2. Click the password field to focus.
  3. Dispatch paste via AppleScript:
     ```applescript
     tell application "System Events" to keystroke "v" using command down
     ```

## Security Architecture and Trust Boundaries

1. User execution boundary: The server and MCP proxy execute under the logged-in user account. The application state directory (`~/Library/Application Support/ExactMac/`) is enforced at mode `0700`, and the gRPC socket is created at mode `0600`. Same-user processes can interact with the socket, while other system accounts are barred at the filesystem boundary.
2. Dynamic capability derivation: The server derives required capabilities and operation counts directly from incoming request bytes. The client's claimed intent is treated as advisory; authorization decisions are enforced on re-derived scopes.
3. Fail-closed consent architecture: When running unattended, headless, over loopback TCP, or when an operator prompt times out, the authorization engine denies access. There is no fallback path that converts an unauthenticated or unanswered request into an allow.
4. Caller identity verification: For Unix socket connections, the server resolves the caller's process tree, code signing designated requirements, and bundle identifier via kernel audit credentials (`LOCAL_PEERPID`). Grants attach to the verified code identity rather than transient process IDs.
5. Audit chain immutability: All decisions are committed to the forward-hashed decision audit log before any operational handler executes.

## Primary References

- Apple Developer Documentation, *Accessibility for macOS*:
  <https://developer.apple.com/documentation/accessibility>
- Apple Developer Documentation, *ScreenCaptureKit*:
  <https://developer.apple.com/documentation/screencapturekit>
- Apple Developer Documentation, *Service Management (SMAppService)*:
  <https://developer.apple.com/documentation/servicemanagement/smappservice>
- Apple Technical Note TN2206, *macOS Code Signing In Depth*:
  <https://developer.apple.com/library/archive/technotes/tn2206/_index.html>
- Apple Developer Documentation, *Embedding Nonstandard Code Structures in a Bundle*:
  <https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle>
- Swift Package Manager, *Bundling Resources with a Swift Package*:
  <https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package>
- Model Context Protocol (MCP) Specification:
  <https://modelcontextprotocol.io/>
- OpenCode MCP Configuration:
  <https://opencode.ai/docs/config/>
- ExactMac Architectural Invariants and Specifications:
  - Standing Invariants: [`AGENTS.md`](AGENTS.md)
  - Security Threat Model: [`threat-model/RISKS.md`](threat-model/RISKS.md)
  - Makefile Implementations: [`make/exactmac.mk`](make/exactmac.mk) and [`make/macos.mk`](make/macos.mk)
