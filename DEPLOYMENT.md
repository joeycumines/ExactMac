# Deploying ExactMac Locally on macOS

ExactMac is not a conventional command-line service. Its Swift server needs
to use Accessibility, Core Graphics input, AppKit, and ScreenCaptureKit from the
logged-in desktop session. That changes the deployment design in three important
ways:

1. the server must have a stable, app-like identity for macOS privacy controls;
2. the SwiftPM resource bundle must travel with the executable; and
3. the process must run as a per-user LaunchAgent in the GUI domain.

This guide implements that design for a **single-user, same-Mac development
installation**. It builds the Swift gRPC server and Go MCP proxy, installs the
server as `~/Applications/ExactMacServer.app`, signs and registers the app, and
runs it behind an owner-only Unix socket.

> This is a local-development deployment, not a distribution pipeline. Shipping
> the app to other Macs requires a Developer ID workflow, Hardened Runtime,
> notarization, stapling, and an update strategy that are outside this guide.

All commands below are run from the repository root. All deployment targets are
implemented in [`make/exactmac.mk`](make/exactmac.mk). Run `gmake help` and
look for the `[ExactMac]` sections to list them.

## The resulting architecture

```text
┌──────────────┐     MCP over stdio      ┌──────────────────┐
│   OpenCode   │ ◄─────────────────────► │  exactmac mcp    │
│  MCP client  │                         │    Go process    │
└──────────────┘                         └────────┬─────────┘
                                                  │ gRPC
                                                  │ Unix socket (0600)
                                                  ▼
                                      ┌────────────────────────┐
                                      │ ExactMacServer.app     │
                                      │ Swift LaunchAgent      │
                                      │ GUI user session       │
                                      └───────────┬────────────┘
                                                  │
                           Accessibility / CGEvent / ScreenCaptureKit
```

The two executables have deliberately different responsibilities:

- **`ExactMacServer`** is the native Swift service. It receives the macOS TCC
  grants and runs from an application bundle under the user's GUI launchd
  domain.
- **`exactmac`** is the Go CLI. It speaks MCP to OpenCode (via `exactmac mcp`) and gRPC
  to the Swift server. It does not need Accessibility or screen-capture access.

For the local installation, the two processes communicate through
`~/Library/Caches/exactmac.sock`; no TCP listener is required.

## Prerequisites

Required versions come from the checked-in source:

- **macOS 15 or later** — `Server/Package.swift` declares `.macOS(.v15)`.
- **Swift 6 or later** — `Server/Package.swift` declares
  `// swift-tools-version: 6.0`.
- **Go matching `go.mod`** — the current module directive is `go 1.26.3`.
- **Buf CLI** — `exactmac.build-server` regenerates the descriptor set through
  the repository's `buf.descriptor-sets` target.
- **GNU Make 4 or later** — use Homebrew's `gmake`, not Apple's BSD `make`.
- **Xcode Command Line Tools** — supplies `swift`, `codesign`, `plutil`, and the
  other macOS development utilities.

A typical Homebrew setup is:

```sh
xcode-select --install
brew install go make bufbuild/buf/buf
```

`grpcurl` is useful for manual gRPC diagnostics but is not required by the
installation target:

```sh
brew install grpcurl
```

Check the machine and source tree before deploying:

```sh
gmake exactmac.doctor
```

## Quick start

The default installation uses an ad-hoc signature, which is convenient for a
one-off local build:

```sh
gmake exactmac.install
```

Then grant the app both privacy permissions in **System Settings → Privacy &
Security**:

1. **Accessibility** — add `~/Applications/ExactMacServer.app` and enable it.
2. **Screen & System Audio Recording** — add the same app and enable it. On some
   macOS releases this panel is labelled **Screen Recording**.

Restart the already-signed service so the new grants apply:

```sh
gmake exactmac.restart
gmake exactmac.verify
```

`exactmac.restart` does not build, replace, or re-sign the application.

## Prefer a stable signing identity

TCC tracks protected privileges using an app's code-signing identity. An ad-hoc
signature is adequate to execute a local app, but it is not a stable identity:
rebuilding and signing new bytes can cause Accessibility or screen-capture
approval to disappear.

List available code-signing identities:

```sh
security find-identity -v -p codesigning
```

For day-to-day development, install with a persistent Apple Development
identity:

```sh
gmake exactmac.install \
  EXACTMAC_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
```

Keep the bundle identifier and signing identity consistent across builds. That
is the practical way to preserve TCC grants while iterating.

The Makefile does **not** use `codesign --deep` while signing.
Apple's signing model is to sign nested code from the inside out and then sign
the outer app. This bundle currently contains one main executable and
resource-only SwiftPM bundles, so signing the outer app is sufficient. The
verification phase does use `--deep --strict` to detect invalid nested content.
If executable helpers, frameworks, or plug-ins are added later, sign those
components explicitly before signing the app.

## What `exactmac.install` does

The installation target runs these phases in a fixed order rather than relying
on a parallel phony-prerequisite graph:

1. **Doctor** — validates macOS, GNU Make, required commands, and source files.
2. **Build server** — generates the protobuf descriptor set and performs a
   release Swift build.
3. **Build Go CLI** — installs `exactmac` into the resolved Go binary
   directory.
4. **Stop service** — unloads any existing LaunchAgent before replacing signed
   code on disk.
5. **Bundle** — creates a staged `.app`, copies the executable and all SwiftPM
   resource bundles, validates `Info.plist`, then moves the staged app into
   place.
6. **Sign** — clears extended attributes on the app bundle being signed, signs it,
   and performs strict verification.
7. **Register** — registers the signed app with LaunchServices.
8. **Launch** — writes and bootstraps the per-user LaunchAgent in
   `gui/$(id -u)`.
9. **Verify** — fails unless the bundle, descriptor resources, signature,
   LaunchAgent, running state, socket mode, and MCP binary are all valid.

The low-level targets are independent. For example,
`gmake exactmac.register` registers the app that is already installed; it does
not unexpectedly rebuild or re-sign it.

## Why the SwiftPM resource bundle matters

`Server/Package.swift` declares:

```swift
resources: [
    .copy("DescriptorSets"),
]
```

SwiftPM therefore emits a resource bundle named
`ExactMacServer_ExactMacServer.bundle`. The generated `Bundle.module` accessor
first looks for that bundle relative to `Bundle.main.bundleURL` and otherwise
falls back to the build-tree path embedded at compile time.

Copying only the executable is not a complete deployment. It leaves production
startup dependent on the source build directory and can trigger a fatal
resource-bundle lookup failure.

The bundle phase stores the real resource bundle under the standard
macOS location:

```text
ExactMacServer.app/Contents/Resources/ExactMacServer_ExactMacServer.bundle
```

The verifier checks the installed bundle and at least one packaged `*.pb`
descriptor file.

## Why this is a LaunchAgent

A LaunchDaemon runs outside the logged-in user's GUI context and is the wrong
execution domain for a service that talks to the accessibility server,
WindowServer, AppKit, and ScreenCaptureKit.

The generated plist is installed at:

```text
~/Library/LaunchAgents/io.github.joeycumines.exactmac.server.plist
```

It runs in the exact service domain:

```text
gui/<uid>/io.github.joeycumines.exactmac.server
```

Lifecycle commands use modern launchctl operations:

- `bootstrap` to load the plist;
- `bootout` to unload it;
- `kickstart -k` to restart the loaded service; and
- `launchctl print gui/<uid>/<label>` to inspect that exact service.

`KeepAlive=true` keeps the server resident and already implies `RunAtLoad`, so a
separate `RunAtLoad` key is unnecessary. The plist sets an integer `63` umask
(`0077` octal), which keeps files and directories owner-only while preserving
the execute/search bit required by macOS framework cache trees, and passes
`GRPC_UNIX_SOCKET`. There is deliberately **no `Sockets` key**: launchd
supervises the process, and the server binds its own socket.
`ThrottleInterval=10` bounds `KeepAlive` restarts so a repeated fatal error
cannot spin a tight crash loop.

### Why the server binds its own socket, and what that changes

Reading the caller's identity is the only way the server can know who is
calling, that read happens when a connection is accepted, and SwiftNIO can only
accept from a socket it bound itself. So the accept is the server's, and the
pathname with it.

The server's first step is to **claim** the pathname: it creates
`<socket>.owner` and takes an exclusive `flock(2)` on it. The kernel releases
that lock when the holder dies, which is what makes the claim a fact rather
than a guess:

- a node left behind by a crash is present and **unlocked**, so the next start
  reclaims it and no operator has to clear it by hand;
- a pathname a live server holds is present and **locked**, so a second server
  refuses — and refusing removes nothing, because a server that never claimed
  the pathname also never unlinks it.

`lstat` describes the node itself and `O_NOFOLLOW` refuses to open through a
symlink, so a symlink, a regular file, a directory, or another user's node is
reported rather than removed. The node the bind creates is `chmod`-ed to `0600`
immediately afterwards, so it is owner-only from the moment it exists.

What this does **not** buy is a persistent pathname lease. A same-user process
can still unlink and rebind a pathname, so clients that connect by pathname
must trust the protected deployment directory and the same-user operator
boundary. The verifier rejects symlink endpoints and checks owner and mode, but
those are point-in-time observations. If that same-user boundary is not
acceptable, use loopback TCP — which has no principal at all and therefore
denies every consent-requiring capability by design — or a separately managed
endpoint. To run manually outside the LaunchAgent, set `GRPC_UNIX_SOCKET` to a
short path and start the server directly; it binds and cleans up on `SIGTERM`:
```sh
GRPC_LISTEN_ADDRESS=127.0.0.1 GRPC_PORT=50051 \
  Server/.build/release/ExactMacServer &
EXACTMAC_SERVER_ADDR=127.0.0.1:50051 \
  $(go env GOPATH)/bin/exactmac mcp
```

(The MCP binary path is `$GOBIN/exactmac` when `GOBIN` is set.)
The Swift server's standalone default is `127.0.0.1:8080`; explicit matching
values avoid relying on different defaults in the two processes.

All pre-existing unmanaged paths are preserved. Operators must remove stale
paths only after stopping the owning LaunchAgent; the server does not reclaim
or mutate them.

The lifecycle targets preserve that guarantee: they boot out the exact
LaunchAgent identity, wait for that identity to disappear, and fail closed
before loading a replacement if it remains registered. They never unlink the
configured path. `exactmac.stop` waits for the exact LaunchAgent identity to
disappear. The server also leaves its pathname untouched during shutdown so a
concurrent replacement cannot be deleted. If a stale path remains, do not
remove it through this target. First prove the prior service identity has
exited and use a separately controlled maintenance procedure with an
independently verified path; otherwise choose a new socket path.

## Installed paths

| Artifact | Default path |
|---|---|
| Application bundle | `~/Applications/ExactMacServer.app` |
| Server executable | `~/Applications/ExactMacServer.app/Contents/MacOS/ExactMacServer` |
| SwiftPM resources | `~/Applications/ExactMacServer.app/Contents/Resources/*.bundle` |
| LaunchAgent plist | `~/Library/LaunchAgents/io.github.joeycumines.exactmac.server.plist` |
| gRPC Unix socket | `~/Library/Caches/exactmac.sock` |
| Standard output log | `~/Library/Logs/exactmac.log` |
| Standard error log | `~/Library/Logs/exactmac.error.log` |
| MCP binary | `$GOBIN/exactmac` (MCP served via `exactmac mcp`), otherwise the first `$GOPATH/bin` |
| Build logs | `.build-logs/exactmac-server.log` and `.build-logs/exactmac.log` |

Go's usual default is `~/go/bin`, but the Makefile resolves `GOBIN` and
`GOPATH` instead of assuming that location.

## Granting and resetting TCC permissions

The server needs these grants:

| Permission | Representative operation | Why it is needed |
|---|---|---|
| Accessibility | `find_elements`, element reads, clicks, typing, window mutations | Read and control other apps through AX APIs |
| Screen & System Audio Recording | `screenshot` | Capture displays and windows with ScreenCaptureKit |

OpenCode may display MCP tools with the configured server-name prefix, such as
`exactmac_screenshot`.

After changing either permission, restart the process:

```sh
gmake exactmac.restart
```

To remove denied or stale records during development:

```sh
gmake exactmac.tcc-reset
```

Then re-enable both permissions in System Settings and restart again. The reset
target reports missing records as warnings rather than pretending a record was
removed.

## Verifying the deployment

Run the strict structural and runtime verifier at any time:

```sh
gmake exactmac.verify
```

Unlike a status display, verification returns a non-zero exit status when a
required condition fails. It checks:

- the app and executable;
- `Info.plist` syntax and bundle identifier;
- the installed SwiftPM bundle and protobuf descriptor resources;
- strict recursive code-signing validity;
- the LaunchAgent plist;
- the exact launchd service and its running state;
- the Unix socket and its `0600` mode; and
- the installed MCP executable.

For an end-to-end permission check, exercise the MCP surface in this order:

1. Basic transport and enumeration: `get_display`, `list_apps`, `list_windows`.
2. Accessibility: `open_app`, then `find_elements` for the returned application.
3. Screen capture: `screenshot`.

The Makefile does not automate TCC interaction or treat a missing
privacy grant as an installation failure; those decisions require the logged-in
user.

## Configuring OpenCode

Keep this MCP server project-scoped by creating `opencode.jsonc` in the
repository root. OpenCode searches upward from the working directory to the
nearest Git root, and its project configuration overrides standard global
configuration.

First determine the actual MCP binary path:

```sh
GOBIN_PATH="$(go env GOBIN)"
if [ -z "$GOBIN_PATH" ]; then
  GOPATH_PATH="$(go env GOPATH)"
  GOBIN_PATH="${GOPATH_PATH%%:*}/bin"
fi
printf '%s\n' "$GOBIN_PATH/exactmac"
printf '%s\n' "$HOME/Library/Caches/exactmac.sock"
```

Use those absolute paths in the project configuration:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "exactmac": {
      "type": "local",
      "command": ["/Users/YOU/go/bin/exactmac", "mcp"],
      "enabled": true,
      "environment": {
        "EXACTMAC_SERVER_SOCKET_PATH": "/Users/YOU/Library/Caches/exactmac.sock"
      },
      "timeout": 10000
    }
  }
}
```

OpenCode's `timeout` is expressed in milliseconds and controls how long it waits
to fetch tools from the MCP server. The proxy's own gRPC request timeout is a
separate setting, `EXACTMAC_REQUEST_TIMEOUT`, expressed in seconds.

Do not add the entry to the global OpenCode configuration unless the tools
should be available in every project.

## Runtime configuration

### Swift gRPC server

The LaunchAgent sets only `GRPC_UNIX_SOCKET`, so the local deployment never
opens a TCP port.

| Variable | Source default | Meaning |
|---|---:|---|
| `GRPC_LISTEN_ADDRESS` | `127.0.0.1` | TCP bind address when no socket is configured |
| `GRPC_PORT` | `8080` | TCP port when no socket is configured |
| `GRPC_UNIX_SOCKET` | empty | Launchd-activated Unix socket path; takes precedence over TCP. Leave unset for manual Swift runs. |

### Go MCP proxy

| Variable | Default | Meaning |
|---|---:|---|
| `EXACTMAC_SERVER_SOCKET_PATH` | empty | Launchd-activated Swift server Unix socket; when set, the TCP address is ignored |
| `EXACTMAC_SERVER_ADDR` | `localhost:50051` | TCP fallback used only when no socket path is set |
| `EXACTMAC_REQUEST_TIMEOUT` | `30` | gRPC request timeout in seconds |
| `EXACTMAC_DEBUG` | `false` | Enable proxy debug logging |
| `MCP_HTTP_ADDRESS` | `127.0.0.1:8080` | Listener for `exactmac http` (Streamable HTTP) |
| `MCP_HTTP_SOCKET` | empty | Unix socket for HTTP transport |
| `MCP_API_KEY` | empty | Bearer-token authentication for HTTP transport |
| `MCP_RATE_LIMIT` | `0` | Requests per second; zero disables limiting |
| `MCP_AUDIT_LOG_FILE` | empty | Optional owner-private non-content audit-log destination |
| `MCP_SHELL_COMMANDS_ENABLED` | `false` | Enables shell execution; leave disabled unless explicitly required |

The Swift TCP default and the MCP TCP fallback are different. The deployment
avoids that ambiguity by configuring both sides with the same Unix socket.

## Screenshot implementation

Screenshot operations use ScreenCaptureKit's single-frame API,
`SCScreenshotManager.captureImage(contentFilter:configuration:)`.

The stream configuration receives explicit non-zero pixel dimensions derived
from the content filter:

```swift
let scale = CGFloat(filter.pointPixelScale)
config.width = Int(filter.contentRect.width * scale)
config.height = Int(filter.contentRect.height * scale)
```

`contentRect` is measured in points and `pointPixelScale` is the conversion from
points to pixels for the filtered content. This is preferable to setting width
and height to zero, and it respects user-selected scaled display modes better
than deriving capture size from a raw display mode.

## Updating without losing permissions unnecessarily

To rebuild and reinstall everything:

```sh
gmake exactmac.install
```

This replaces and re-signs the application. With the default ad-hoc identity,
expect to re-grant TCC permissions. With a stable Apple Development identity,
TCC should normally recognize the new build as the same app, provided the
bundle identifier and designated requirement remain stable.

To restart the same installed code after a configuration or TCC change:

```sh
gmake exactmac.restart
```

That target does not touch the app's bytes or signature.

## Lifecycle and diagnostic targets

| Target | Purpose |
|---|---|
| `exactmac.doctor` | Validate the host tools and expected source layout |
| `exactmac.build-server` | Generate descriptors and build the release Swift server |
| `exactmac.build-mcp` | Build and install the Go MCP proxy |
| `exactmac.build` | Run both builds in a deterministic order |
| `exactmac.bundle` | Stage and install the app, including SwiftPM resources |
| `exactmac.sign` | Sign the existing app and verify it strictly |
| `exactmac.register` | Register the existing signed app with LaunchServices |
| `exactmac.launchd` | Write and bootstrap the per-user LaunchAgent |
| `exactmac.install` | Run the complete ordered local installation |
| `exactmac.verify` | Fail unless every required installed/runtime check passes |
| `exactmac.status` | Print launchd, socket, signature, and MCP status (informational only) |
| `exactmac.start` | Start a loaded or installed service without rebuilding |
| `exactmac.restart` | Force-restart the service without rebuilding or signing |
| `exactmac.stop` | Stop and unload the service while preserving installed files and TCC |
| `exactmac.tcc-reset` | Reset Accessibility and ScreenCapture TCC records |
| `exactmac.logs` | Show stdout, stderr, and recent unified-log entries |
| `exactmac.uninstall` | Remove installed app, service, plist, logs, MCP binary, and matching TCC records; socket cleanup remains ownership-controlled |

## Troubleshooting

### The server reports a missing resource bundle

Run:

```sh
ls -ld \
  ~/Applications/ExactMacServer.app/Contents/Resources/ExactMacServer_ExactMacServer.bundle
find ~/Applications/ExactMacServer.app -name '*.pb' -print
gmake exactmac.verify
```

A correct deployment contains the real bundle under `Contents/Resources`.
Re-run `gmake exactmac.install` if it is absent.

### A TCC grant disappears after rebuilding

The usual cause is ad-hoc signing. Install with a persistent Apple Development
identity, then grant the permission once more:

```sh
gmake exactmac.install \
  EXACTMAC_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
```

### The privacy prompt does not appear

Confirm that the installed app is signed and registered, and that launchd is
running the executable from inside that app:

```sh
gmake exactmac.status
codesign -dvvv ~/Applications/ExactMacServer.app
gmake exactmac.register
```

`exactmac.register` does not rebuild or re-sign. If the app is still absent
from the relevant System Settings panel, add
`~/Applications/ExactMacServer.app` manually.

### Screen capture remains denied after enabling it

Apple's ScreenCaptureKit guidance requires restarting the app after approval.
Run:

```sh
gmake exactmac.restart
gmake exactmac.logs
```

### The socket is missing or the client cannot connect

```sh
gmake exactmac.status
gmake exactmac.logs
gmake exactmac.verify
```

Confirm that the path in `opencode.jsonc` exactly matches:

```text
~/Library/Caches/exactmac.sock
```

OpenCode configuration requires an absolute path; a literal `~` is not a safe
substitute.

### OpenCode cannot find `exactmac`

Do not assume `~/go/bin`. Resolve the active Go install directory and use that
absolute path in `opencode.jsonc`:

```sh
go env GOBIN
go env GOPATH
```

The Makefile prints the final MCP path during installation and in
`gmake exactmac.status`.

### `launchctl bootstrap` reports that the service is already loaded

Use the exact lifecycle targets rather than loading the plist manually:

```sh
gmake exactmac.stop
gmake exactmac.launchd
```

They address the service as `gui/<uid>/io.github.joeycumines.exactmac.server`, boot out the
exact LaunchAgent identity, and wait for that identity to disappear before
bootstrapping. launchd supervises the process; the server binds its own socket;
server receives it through socket activation. The targets never unlink the
configured path.

### The service restarts repeatedly (`KeepAlive` backoff / crash loop)

A failed pathname claim is treated as a startup failure: inspect the
crash reason and service state rather than deleting the socket by hand. The
LaunchAgent owns the declared socket and recreates it when the service is
reloaded. If the server is started manually with `GRPC_UNIX_SOCKET` set, it
reports that the pathname is held by a running server; stop the other server and configure
matching loopback TCP settings instead. If restarts persist, inspect the crash reason:

```sh
gmake exactmac.status
gmake exactmac.logs
gmake exactmac.verify
```

If an unmanaged object occupies the configured `GRPC_UNIX_SOCKET` path,
another server's claim fails rather than replacing it. Stop the owning process
before any separately controlled maintenance. Do not unlink the path from the
server or deployment targets. `ThrottleInterval=10` in the LaunchAgent bounds
the restart rate while the underlying error is fixed.

### Screenshot capture reports zero width or height

The current implementation computes explicit dimensions from
`SCContentFilter.contentRect` and `pointPixelScale`. Rebuild the installed app to
ensure it contains that source:

```sh
gmake exactmac.install
```

### Quarantine or extended attributes interfere with signing

The sign target runs `xattr -cr` against the app bundle being signed. The full
install target signs a newly staged local app, while the standalone sign target
operates on the already-installed bundle. A locally built application normally should not need a separate
quarantine workaround. Diagnose unexpected attributes before applying broader
changes:

```sh
xattr -lr ~/Applications/ExactMacServer.app
```

## Security boundaries

Accessibility and screen recording are high-impact permissions. Grant them only
to an app you built from source and whose signature you inspected.

The default local design keeps the trust boundary narrow:

- the server binds the Unix socket itself and holds the pathname under a lock
  the kernel releases when the process dies;
- the process runs under an owner-only `0077` umask, preserving directory
  traversal for macOS framework caches, and the socket node is `0600`;
- the server claims the pathname under a lock and hardens the node it creates,
  so a crash is recoverable and a live holder is never displaced;
- the service runs as the logged-in user, not as root;
- the MCP proxy runs over stdio via `exactmac mcp` (HTTP is the separate `exactmac http` subcommand); and
- shell-command execution is disabled by default.

Do not expose the MCP Streamable HTTP transport or the Swift gRPC TCP listener
beyond loopback without adding authentication, TLS, rate limiting, and an
explicit threat model.

## Uninstallation

```sh
gmake exactmac.uninstall
```

This removes installed runtime artifacts, including the app, LaunchAgent plist,
logs, and resolved `exactmac` binary. It preserves the
configured socket pathname because the server and deployment targets cannot
safely unlink a path that may have been replaced. It also attempts to remove
the matching LaunchServices registration and TCC records; macOS may report no
matching record, and those cleanup commands are intentionally non-fatal. It does
not delete source files or Swift/Go build caches in the repository.

## Primary references

- Apple, *Code Signing Tasks*:
  <https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html>
- Apple, *Technical Note TN2206: macOS Code Signing In Depth*:
  <https://developer.apple.com/library/archive/technotes/tn2206/_index.html>
- Apple, *Placing content in a bundle*:
  <https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle>
- Apple, *Embedding nonstandard code structures in a bundle*:
  <https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle>
- Apple, *Hardened Runtime*:
  <https://developer.apple.com/documentation/security/hardened_runtime>
- Apple, *Notarizing macOS software before distribution*:
  <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Apple, `launchctl(1)` and `launchd.plist(5)` man pages as shipped with Xcode:
  <https://keith.github.io/xcode-man-pages/launchctl.1.html>
  and <https://keith.github.io/xcode-man-pages/launchd.plist.5.html>
- Apple, *SCScreenshotManager*:
  <https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager>
- Apple, *SCContentFilter.contentRect*:
  <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/contentrect>
- Apple, *SCContentFilter.pointPixelScale*:
  <https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale>
- Apple, *Capturing screen content in macOS*:
  <https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos>
- Swift Package Manager, *Bundling resources with a Swift package*:
  <https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package>
- OpenCode, *MCP servers*:
  <https://opencode.ai/docs/mcp-servers/>
- OpenCode, *Config*:
  <https://opencode.ai/docs/config/>
- Go, *How to Write Go Code*:
  <https://go.dev/doc/code>
