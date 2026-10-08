# Deploying ExactMac on macOS

ExactMac drives the logged-in desktop through the Accessibility APIs, so it
cannot be an ordinary background daemon: Accessibility, Core Graphics input,
AppKit, and ScreenCaptureKit all need a window-server session belonging to the
user. That shapes the whole deployment.

**ExactMac is one macOS application.** `ExactMacConsole.app` hosts the gRPC
server in its own process, presents the operator's consent prompt itself, and
registers itself for start-at-login through `ServiceManagement`. There is no
separate server process and no LaunchAgent to install or keep alive.

> This is a local installation for one user on one Mac. Shipping the app to
> other machines needs a Developer ID, the Hardened Runtime, notarization and
> stapling — see [Signing](#signing) — plus an update strategy that is outside
> this guide.

All commands run from the repository root. `gmake help` is the authoritative
target list; the sections are `[ExactMac]`, `[macOS]` and `[Console]`.

## Architecture

```text
┌──────────────┐     MCP over stdio      ┌──────────────────┐
│   OpenCode   │ ◄─────────────────────► │  exactmac mcp    │
│  MCP client  │                         │    Go process    │
└──────────────┘                         └────────┬─────────┘
                                                  │ gRPC over
                                                  │ Unix socket (0600)
                                                  ▼
                                      ┌────────────────────────────────────┐
                                      │ ExactMacConsole.app                │
                                      │                                    │
                                      │  gRPC server                       │
                                      │  authorization + audit             │
                                      │  consent prompt  ◄── the operator  │
                                      └───────────┬────────────────────────┘
                                                  │
                           Accessibility / CGEvent / ScreenCaptureKit
```

Two executables, three processes' worth of work:

- **`ExactMacConsole.app`** is the product. One process holds the gRPC listener,
  the authorization interceptor, the grant store, the hash-chained decision
  log, and the window that asks the operator for consent. It runs as a
  menu-bar accessory with no Dock icon.
- **`exactmac`** is the Go MCP proxy. It speaks MCP to the agent host and gRPC
  to the app over `~/Library/Caches/exactmac.sock`. It needs neither
  Accessibility nor Screen Recording.

The socket is owner-only (`srw-------`) and lives in the user's cache
directory. No TCP listener is used.

## Prerequisites

- **macOS 15 or later.** `Console/Package.swift` declares `.macOS(.v15)`.
- **Swift 6** and **Go 1.27+**, per `.swift-version` and `go.mod`.
- **A signed app bundle.** Hand-assembled and ad-hoc signed is enough to run
  locally; see [Signing](#signing).
- **Two privacy grants**, granted to the app after it first launches:
  Accessibility and Screen Recording. They are independent, and losing one
  degrades the app partially and silently — Accessibility gates the AX tree and
  input synthesis, Screen Recording gates capture. The app never prompts
  programmatically; macOS does, once per grant.

`gmake exactmac.doctor` checks the toolchain and prints the resolved source
layout.

## Install

```sh
gmake exactmac.console-install
```

One command, because an upgrade that needs a second command is an upgrade
someone does not finish. It builds the release binary, assembles and signs the
bundle, verifies the bundle, copies it to `~/Applications/ExactMacConsole.app`,
verifies the **installed** copy, registers it with LaunchServices, creates the
state directory at `0700`, and retires any superseded LaunchAgents left by an
older installation.

Then launch it. It appears in the menu bar.

The first launch asks macOS for Accessibility and Screen Recording, and offers
to register itself as a login item. macOS may put that second request in front
of you in System Settings → General → Login Items; that is the system
mediating, not the app.

> **One-time re-grant.** The Accessibility and Screen Recording grants are keyed
> to a bundle identity, and this installation changes identity — two bundle ids
> become one. macOS will ask for both grants again the first time you launch the
> new bundle. That happens once.

### If you are upgrading from the two-process installation

`exactmac.console-install` runs `exactmac.retire-launchagents` for you, which
unloads `com.exactmac.console` and `io.github.joeycumines.exactmac.server` and
**archives** their plists under `~/.exactmac/retired-launchagents/` rather than
deleting them. The order is deliberate: boot out, confirm the job is gone, then
move the file. A plist left in place is re-bootstrapped at the next login, so a
retirement that only removed the file would look finished and bring the old
server back on the next reboot.

To undo it:

```sh
gmake exactmac.restore-launchagents
```

To look without changing anything:

```sh
gmake exactmac.retire-launchagents-status
```

## Signing

The bundle is signed ad-hoc by default, which is enough to run locally.
`codesign --verify --deep --strict` passes and `spctl --assess` is *rejected* —
that is the expected verdict for an ad-hoc signature, and `gmake macos.verify`
asserts exactly that rather than leaving it as a surprise.

Start-at-login is registered through `ServiceManagement.SMAppService.mainApp`,
which requires the app to be signed. **An ad-hoc signature is accepted** — this
was measured, not assumed: a hand-assembled ad-hoc bundle registered
successfully (`status` moved `notFound` → `enabled`) and unregistered cleanly.

To sign with a real identity instead:

```sh
gmake macos.all MACOS_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
```

`MACOS_SIGN_IDENTITY` also decides what `macos.verify` expects from Gatekeeper:
`rejected` for `-`, `accepted` for anything else. The expectation is derived
from the identity rather than hard-coded, so a Developer ID build that
Gatekeeper refuses fails the build.

## Why the resource bundle matters

SwiftPM puts resources — the protobuf descriptor sets, the design tokens — in a
`.bundle` directory beside the executable, not next to it. A bundle assembled
without them builds, installs, and then reads an empty descriptor set at
runtime, which looks like every RPC being unknown. `macos.bundle` copies every
`*.bundle` it finds and fails if none were copied, and
`gmake exactmac.verify` asserts the required one is present in the assembled
app.

## Console Targets and Assets

The console application targets build, package, sign, and install the menu-bar app.

### Make Targets

| Target | Action |
|---|---|
| `gmake exactmac.console-build` | Builds the release binary at `Console/.build/release/ExactMacConsole`. |
| `gmake exactmac.console-app` | Packages `ExactMacConsole.app`, copies SwiftPM resource bundles, writes `Info.plist`, and installs icons and glyphs into `Contents/Resources`. |
| `gmake exactmac.console-sign` | Signs the bundle ad-hoc (or with `MACOS_SIGN_IDENTITY`) and runs `codesign --verify --deep --strict`. |
| `gmake exactmac.console-install` | Runs the full build, package, sign, verify, and install sequence to `~/Applications/ExactMacConsole.app`, registers with `lsregister -f`, sets up `~/.exactmac/`, and archives legacy LaunchAgents. |
| `gmake exactmac.console-stop` | Terminates running `ExactMacConsole` instances via `pkill -x ExactMacConsole`. |
| `gmake exactmac.console-uninstall` | Stops the running app, removes `~/Applications/ExactMacConsole.app`, and deletes the socket. |

### Icon and Asset Pipeline

The console bundle packages two visual assets:

- **Application Icon (`AppIcon.icns`)**: Generated from `Console/Resources/AppIcon-2048.png`. The background outside the shield emblem is transparent; the dark tile container and white rounded corners are removed. The `.icns` file is built from `Console/Resources/AppIcon.iconset/` and installed to `Contents/Resources/AppIcon.icns`. `Info.plist` declares `CFBundleIconFile = AppIcon.icns`.
  - **Optical scaling per size class**: list-style consumers (System Settings panes, Finder list views) composite transparent artwork inset on a system plate, so the small representations (`icon_16x16` through `icon_32x32@2x`, ≤ 32 pt) are exported full-bleed — the emblem cropped to its alpha bounds and scaled to the full canvas — which keeps the emblem at visual parity with peer icons in those lists. Representations ≥ 128 px retain the emblem's natural padding for the Dock, Get Info, and Launchpad, where full-bleed would read oversized against squircle artwork.
- **Menu Bar Status Item (`MenuBarGlyph.svg`)**: Vector stencil traced from the emblem geometry and sized for an 18x18pt status bar bounding box (16x16pt glyph with 1pt padding). Rendered via AppKit with `isTemplate = true` for native appearance matching macOS menu bar items.
  - **Running / Pending**: Template emblem matching system menu bar items.
  - **Stopped**: Drawn at 38% opacity (`fraction: 0.38`), matching inactive macOS status items.
  - **Degraded / Reduced / Cannot Ask**: Template emblem with a 5pt amber badge dot (`#A04A00` light / `#FF9F0A` dark) and a 0.75pt transparent knockout separating the badge from the emblem boundary.

Source assets live in `Console/Resources/` (`MenuBarGlyph.svg`, `MenuBarGlyph.png` at 18x18, and `MenuBarGlyph@2x.png` at 36x36) and are staged to `Contents/Resources/` by `exactmac.console-app`.

## Installed paths

| What | Where | Mode |
|---|---|---|
| App bundle | `~/Applications/ExactMacConsole.app` | — |
| gRPC socket | `~/Library/Caches/exactmac.sock` | `srw-------` |
| State directory | `~/.exactmac/` | `0700` |
| Grant store | `~/.exactmac/grants.json` | `0600` |
| Decision log | `~/.exactmac/audit.log` | `0600` |
| Retired plists | `~/.exactmac/retired-launchagents/` | `0700` |
| MCP binary | `$(go env GOBIN)/exactmac` | — |

The state directory is created at `0700` and the two files inside it at `0600`,
by the server, not by make. A state directory that exists with the wrong mode or
owner is **refused at startup** rather than repaired: it holds the operator's
grants, and silently widening it would be the wrong repair.

## Connecting an agent

Build the Go proxy and point the agent host at it:

```sh
gmake exactmac.build-mcp
```

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

Both paths must be absolute. `EXACTMAC_SERVER_SOCKET_PATH` is required for the
Unix-socket variant; the proxy falls back to `EXACTMAC_SERVER_ADDR`
(default `localhost:50051`) without it, and a TCP listener denies every
consent-requiring capability by design, so a missing socket path shows up as
"everything is denied" rather than as a connection error.

`timeout` is in milliseconds and bounds the tool-list fetch. The proxy's own
per-request timeout is `EXACTMAC_REQUEST_TIMEOUT`, in seconds.

## Runtime configuration

The app reads no environment variables in normal use. It sets its own socket
path to `~/Library/Caches/exactmac.sock` when one is not already set, and
leaves an existing `GRPC_UNIX_SOCKET` alone so a diagnostic run can point it
elsewhere.

`EXACTMAC_HEADLESS=1` forces the headless posture, in which the app installs no
operator interface and every consent-requiring capability is denied. It exists
for diagnosis. A value other than `1` or `true` is ignored, so a typo cannot
silently strip the consent interface off a running app.

The app classifies itself at launch and logs which way it went:

```sh
log show --last 5m --predicate 'subsystem == "io.github.joeycumines.exactmac.console"'
```

`application` means it can put a prompt in front of the operator. `headless`
means it cannot, and everything requiring consent denies. The classification
needs both an app bundle and a window-server session; anything unrecognised is
treated as headless, because the failure mode of guessing otherwise is a
request that waits for a prompt nobody can see.

## Verifying the deployment

```sh
gmake exactmac.verify
```

Checks the bundle, its resources, its signature, the service, the socket, and
the MCP binary, and fails with a specific line rather than a summary.

`gmake exactmac.status` reports the same things without failing, and
`gmake exactmac.logs` shows recent output.

To confirm the whole path end to end:

```sh
go build -o /tmp/exactmac ./cmd/exactmac
EXACTMAC_SERVER_SOCKET_PATH=~/Library/Caches/exactmac.sock /tmp/exactmac health
```

`server health: SERVING` means the app is listening and answering.

## The decision log

Every decision is recorded to `~/.exactmac/audit.log` before any handler runs,
and each entry carries its own hash chained to the previous one. Editing any
entry breaks every hash after it; removing an entry from the middle is caught
too. **Removing the last entry is not detected** — a process that can truncate
can also renumber, so claiming the tail is protected would be false.

The log survives a restart, and verification walks from the log's own first
entry rather than from anything the current process invents, so relaunching does
not report a chain that was never broken.

`gmake exactmac.tcc-reset` clears the privacy records for both the app's
identifier and the retired server identifier, for machines that still hold one
from the old installation.

## Uninstalling

```sh
gmake exactmac.console-uninstall
```

Stops the app, unregisters the bundle, and removes the app and the socket. It
deliberately leaves two things and says so:

- **The state directory**, `~/.exactmac/`, which holds your grants and your
  decision history. Remove it deliberately if you mean to:
  `rm -rf ~/.exactmac/`.
- **The login item**, which belongs to the bundle that registered it. macOS
  removes it with the bundle; it can also be turned off in System Settings →
  General → Login Items.

`gmake exactmac.uninstall` also removes the old server bundle, its plist, the
MCP binary and the TCC records, and is the fuller teardown for a machine that
had the two-process installation.

## Troubleshooting

**Every consent-requiring call is denied.** The app is not running, or it is
running without an operator interface. Check the launch line from the log
command above. If it says `headless`, the process has no window-server session
— over SSH, or with the screen locked.

**`no such file or directory` on the socket.** The app is not running. Launch
it. If the socket exists but nothing connects, check the mode: it must be
`srw-------`.

**The app is running but there is no socket.** The app holds the pathname under
a lock, and a socket that has been *deleted* while the process still holds it
leaves a server listening on a name nothing can reach: the process is alive,
`open -a` on it just activates the window that already exists, and every
connection fails with `no such file or directory`. Something that removed the
pathname — a cleanup script, an over-eager `rm` — caused it. Quit the app and
launch it again rather than re-running the install:

```sh
pkill -x ExactMacConsole
rm -f ~/Library/Caches/exactmac.sock ~/Library/Caches/exactmac.sock.owner
open -a ~/Applications/ExactMacConsole.app
```

The app only removes a socket node after checking that the node is a socket,
so a symlink or a file at that path is refused rather than unlinked.

**The app exits immediately after launching.** Run the bundle's executable
directly and read stderr:

```sh
~/Applications/ExactMacConsole.app/Contents/MacOS/ExactMacConsole
```

The likeliest cause is a socket pathname another server still holds, which the
app reports as a sentence rather than a trap.

**Rebuilding `exactmac` did not take effect in the MCP host (stale MCP process).**
The agent host (IDE or MCP runner) spawns `exactmac mcp` as a long-lived child
process at session start. Rebuilding the Go binary (`gmake exactmac.build-mcp`)
replaces the binary file on disk but does not reload running processes, so the
MCP client continues communicating with the old in-memory image. Check process
attribution against the binary's modification time:

```sh
gmake exactmac.check-mcp-host
```

If stale processes are reported, restart the MCP host (IDE / agent session) or
terminate the stale processes so the host spawns the fresh binary:

```sh
pkill -f "exactmac mcp"
```

**A TCC grant disappears after rebuilding.** An ad-hoc signature changes on
every rebuild, and the grant is keyed to the signature. This is expected; a
Developer ID signature does not have the problem. See [Signing](#signing).

**The app icon looks stale or padded after a reinstall.** macOS icon services caches per-bundle thumbnails outside the bundle, so replacing `Contents/Resources/AppIcon.icns` can leave System Settings, the Dock, and Finder showing the previous artwork until the cache invalidates. The bundle on disk is authoritative: `gmake exactmac.console-register` re-registers it, and a logout or restart clears any residual thumbnail. The small representations (≤ 32 pt) are intentionally full-bleed; see [Icon and Asset Pipeline](#icon-and-asset-pipeline).

**The privacy prompt does not appear.** The product never prompts
programmatically — macOS does, and only once per grant. If the prompt has
already been dismissed it will not return. Reset and relaunch:

```sh
gmake exactmac.tcc-reset
```

**Screen capture stays denied.** Screen Recording is a separate grant from
Accessibility and is granted separately. Enabling one does not enable the
other.

**`Could not find service` from `launchctl`.** Nothing to fix: that is what
retiring a LaunchAgent looks like, and it is the expected result of
`gmake exactmac.retire-launchagents`.

**`gmake exactmac.launchd` or `exactmac.console-start` refuse.** They are
retired. Installing or starting a server process is the two-process
architecture this product no longer has, and a target that quietly succeeded
would be how it came back.

## Security boundaries

- The gRPC socket is owner-only. The intended consumer is an agent running as
  the same user, so the boundary is the owning user, not the socket.
- The app derives each request's capability and scope from the request bytes.
  Nothing the operator is shown becomes an authorization input.
- With no operator interface, every consent-requiring capability denies. There
  is no path from that to allow.
- A grant is bound to the calling code's identity — path, bundle identifier and
  signing requirement — and never to a pid. Because the socket peer is the
  `exactmac` proxy, a grant bound to the peer is inherited by every agent that
  spawns that binary, which is why the prompt shows the resolved process tree on
  every request.
- A TCP listener has no principal to authenticate, so it never enters the
  consent path and every consent-requiring capability is denied on it.

`threat-model/RISKS.md` holds the full model, including the same-uid residual
that is accepted rather than claimed away.

## References

- `AGENTS.md` — the standing invariants the server and console must not break.
- `blueprint.json` — the design decisions and their reasoning.
- `threat-model/` — the threat model and its validated risk register.
- `make/exactmac.mk` — install, lifecycle, and the LaunchAgent retirement.
- `make/macos.mk` — bundle assembly, signing and verification.
