# AGENTS.md / CLAUDE.md

This file provides guidance to AI agents.

## Project Overview

ExactMac is a macOS accessibility automation framework consisting of:

- **Swift library**: Core SDK using Accessibility APIs for UI traversal and input simulation
- **Swift gRPC server**: Production server backing the CUA-aligned MCP tools for AI agent integration
- **Go MCP server**: MCP proxy layer exposing functionality via Model Context Protocol

## Build Interface

`gmake help` is the authoritative catalog of available targets and their behavior. A bare `gmake` selects `check`: the complete `all` build/check path followed by permission-dependent macOS integration tests. Read the help output before choosing specialized targets; do not duplicate its recipes here.

## Key Directories

- `Server/` - Swift gRPC server with Accessibility API integration
- `Sources/` - Swift SDK
- `internal/` - Go modules for config, server, transport
- `proto/` - Protocol buffer definitions (must mirror package structure)
- `integration/` - Integration tests (target Calculator, TextEdit, Finder)
- `make/` - Make build system modules
- `docs/` - Documentation

## Important Files

- `WIP.md` - Interruption guard and current execution state
- `CONTRIBUTING.md` - Development guidelines
- `Makefile` - Build orchestration
- `config.mk` - Custom build targets (create your own here)
- `docs/window-state-management.md` - Window state architecture (living document)

## Testing Philosophy

- **Atomic Testing**: All new behavior includes tests
- **Golden Applications**: Integration tests target TextEdit, Calculator, Finder
- **PollUntil Pattern**: Never use `time.Sleep` in tests; use `PollUntil` for async verification
- **State-Difference Assertions**: Verify state changes, not just "OK" status
- **Fixture Lifecycle**: Clean state (SIGKILL apps) before, aggressive cleanup after

## Proto API Structure

- Location: `proto/exactmac/v1/`
- Common types: `proto/exactmac/type/`
- Resource definitions separate from service definitions
- Naming follows Google AIPs 121, 190, 191
- Use `buf` for generation, `api-linter` for design validation

## Implementation Constraints

### Strict Mandates

- AVOID and REPLACE ad-hoc `fputs` or unannotated `print` with `Logger` and `OSLogPrivacy` for any message emitted from Swift server components or SDK helpers in `Server/Sources/ExactMacServer` and `Sources/ExactMac`.
- `fputs` is forbidden in these server/SDK directories for diagnostic logs — it bypasses OS unified logging and cannot mark privacy. Use `Logger` with explicit `privacy` annotations for every interpolated value. For user-facing CLI help text (static strings) `print` is allowed only outside `Server/Sources/ExactMacServer` and `Sources/ExactMac`.

### Standing Invariants (Server & Console)

These properties must hold across all changes to `Server/Sources/ExactMacServer` and `Console/Sources/ExactMacConsole`. Each is a single falsifiable statement backed by automated tests:

1. No RPC reaches a handler without a decision recorded in the decision audit log.
2. Every consent failure mode denies: an unreachable console, a timeout, a cancelled, failed, or locked-out biometric, a corrupt or unreadable grant store, an unauthenticated channel peer, and an absent or locked operator. There is no path on which any of these produces allow.
3. A biometric success authorizes exactly one decision, is bound to a per-decision nonce, and never downgrades silently to a weaker check.
4. Capability and scope are re-derived by the server from the request bytes at enforcement time. The console's classification is for display only and is never an authorization input.
5. A pre-authorization envelope can never confer a global-persistent grant, and expires as a unit on a monotonic clock.
6. A grant binds to a caller's code identity — executable path, bundle identifier, and signing designated requirement — and never to a pid.
7. App and process verification exists only in the Unix-socket variant, and is graded evidence surfaced to the operator, never an authentication gate. An unsigned caller is escalated, not silently rejected.
8. A TCP-configured server never enters the consent or verification path. It denies every consent-requiring capability and reports that posture through the health service.
9. A transaction is authorized as a scope with a declared operation count, and exceeding that count is denied rather than extended. A single approval is never amortised across an unbounded batch.
10. Every growing server-side resource is bounded per resolved caller identity, and the quota survives reconnection.
11. The decision audit log is hash-chained, and the console verifies the chain before displaying it rather than presenting unverified bytes as authoritative.
12. The console persists no decision state, so there is nothing on disk for a same-uid process to forge.
13. A prompt never truncates a command, script, path, or argument. It wraps and scrolls.
14. Text the caller supplied is visually distinguished in the prompt from text the system derived.
15. Payloads, command text, and target paths never appear in a notification.
16. No UI change lands before the corresponding design exists in `docs/design.fig`.

### Core Directives

Constraints in this section describe *requirements*, not current status.

The gRPC server MUST:

- Strictly follow **Google's AIPs** (2025 standards). When in doubt between `buf lint` and Google's AIPs, Google's AIPs take precedence.
- Support configuration via environment variables (socket paths, addresses).
- Maintain the **State Store** architecture: `AppStateStore` (copy-on-write view for queries), `WindowRegistry`, `ObservationManager`, and `SessionManager`.

Previously violated requirements (now corrected):

- **Pagination (AIP-158):** You MUST implement `page_size`, `page_token`, and `next_page_token` for ALL List/Find RPCs, and `page_token`/`next_page_token` MUST be treated as opaque by clients (no reliance on internal structure such as `"offset:N"`).
- **State-Difference Assertions:** Tests MUST NOT rely on "Happy Path" OK statuses. Every mutator RPC (Click, Move, Resize) MUST be followed by an accessor RPC to verify the *delta* in state.
- **Wait-For-Convergence:** Integration and state-convergence tests MUST use a `PollUntil` pattern. Lower-level transport tests may use controlled timing primitives when testing timeout/deadline behavior.
- **NSPasteboard Correctness (2025-11-30):** Public clipboard write paths clear the pasteboard before writing. Keep that invariant at the public manager boundary; the lower-level pasteboard adapter is not itself the policy boundary.

**API Scope:**

- Expose ALL functionality via the `ExactMac` service (consolidated service).
- Include all resources: Window, Element, Observation, Session, Macro, Screenshot, Clipboard, File, Script, **Display**.
- Support advanced inputs: Modifiers, Special Keys, Mouse Operations (drag, right-click).
- Support VS Code integration patterns (multi-window, advanced targeting).
- **Display API (2025-11-30):** Must expose display/screen enumeration via `ListDisplays` RPC. Each Display resource must include:
    - Display ID (CGDirectDisplayID)
    - Frame (position and size in global coordinate space)
    - Visible frame (excluding menu bar and dock)
    - Whether it is the main display
    - Scale factor (Retina)
      This is critical for multi-monitor setups where window coordinates are in global coordinate space.

**Coordinate System Documentation (CRITICAL 2025-11-30):**

- macOS uses **multiple coordinate systems** that clients MUST understand:
    - **Global Display Coordinates** (used by CGWindowList, AX, CGEvent): Origin at **top-left of the main display**. Y increases downward. Secondary displays can have negative X (left of main) or negative Y (above main).
    - **AppKit Coordinates** (used by NSWindow, NSScreen.frame): Origin at **bottom-left of the main display**. Y increases upward.
- Window bounds returned by `ListWindows` and `GetWindow` use **Global Display Coordinates** (top-left origin).
- Input coordinates (clicks, mouse moves) sent via `CreateInput` are interpreted as **Global Display Coordinates** (top-left origin).
- The proto API documentation MUST clearly specify which coordinate system is used for each field.
- NO coordinate conversion is needed between Window bounds and Input positions (both use the same coordinate system).

**Authoring Guidance:** When writing code comments or documentation, always state explicitly which coordinate system is referenced. Use the phrases "Global Display Coordinates (top-left origin)" for AX/CGEvent/CGWindowList and "AppKit Coordinates (bottom-left origin)" for NSWindow/NSScreen. Avoid ambiguous shorthand such as "CGEvent coordinates" without the origin direction.

**Core Graphics/Cocoa/Accessibility Race Condition Mitigation:** Do not rely on `NSRunningApplication(processIdentifier:)` or `CGWindowListCopyWindowInfo` (and related `CGWindow*` APIs) for process/window liveness or existence checks when performing AX actions. These APIs can lag behind the real-time state of the Accessibility server. Always attempt AX actions (e.g., `AXUIElementCreateApplication(pid)`, `AXUIElementCopyAttributeValue`) directly, then handle invalid process/element errors if they occur. Using CG/NS APIs as a "guard" or "pre-check" introduces a race condition where valid AX targets are rejected because the slower API hasn't updated yet.

### Testing and Tooling

- **Atomic Testing:** ALL new behavior and ALL modifications MUST be accompanied by automated tests in the SAME change set.
- **Golden Applications:** Integration tests must strictly target `TextEdit`, `Calculator`, or `Finder` as defined in the plan.
- **CI Integrity:** Tests and CI checks MUST be kept green. Disabling tests is forbidden without a documented fix plan.
- **Test Fixture Lifecycle:** Every test suite must ensure a clean state (SIGKILL target apps) before running and perform aggressive cleanup (`CloseApplication` with exact resource identity and observed process exit) after running.

### Documentation and Planning

- **Execution State:** Record current execution state and interruptions in `WIP.md`.
- **Verify before claiming completion:** Before treating any item as complete, verify the implementation and its tests. If there is any doubt, treat the item as not done.
- **Living Documents:** Keep `WIP.md` and `docs/window-state-management.md` aligned with the actual code reality.

### Master (LIVING) Documents

**MUST BE KEPT UP TO DATE.** Must be analytical, terse, and precise.

- [docs/window-state-management.md](docs/window-state-management.md)

### MCP Specification References

MCP compliance requirements are documented in docs/ai-artifacts/05-mcp-integration.md. Refer to that document for:

- Protocol version requirements (2025-11-25)
- Transport specifications and compliance status
- Security and tooling details

### Proto API Structure

- **Path:** Proto files MUST be located at `proto/exactmac/v1/` and mirror package structure.
- **Common Types:** Use `proto/exactmac/type` for shared definitions.
- **Separation:** Resource definitions MUST be in separate files from service definitions.
- **Naming:** Follow https://google.aip.dev/121, 190, and 191.
- **Linting:** Use `buf` for generation but `api-linter` (Google's linter) for design validation.

### Google API Linter Configuration

- `api-linter` MUST be run via a dedicated Go module in `hack/google-api-linter/`.
- Logic MUST be encapsulated in `./hack/google-api-linter.sh` (executable via `gmake`).
- Configuration MUST be in `./google-api-linter.yaml` with:
  ```yaml
  ---
  - included_paths:
      - 'google/**/*.proto'
    disabled_rules:
      - 'all'
  ```
- You MUST NOT ignore linting for anything except `googleapis` protos.

### CI/CD Workflows

- CI workflow policy applies when workflow files are present; verify the checked-out workflow set before referring to an entry point or reusable workflow.
- For trusted and first-party GitHub Actions, including `bufbuild/buf-action`, use the latest major version tag. Do not use an older major or a commit-SHA pin for these actions; re-check the current latest major before editing workflows.
- Scripts MUST NOT use `set -e`; use explicit chaining (`&&`) or condition checks.
