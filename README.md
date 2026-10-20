[![CI](https://github.com/joeycumines/ExactMac/actions/workflows/ci.yaml/badge.svg)](https://github.com/joeycumines/ExactMac/actions/workflows/ci.yaml)
[![Go Coverage](https://img.shields.io/badge/Go%20Coverage-70%25+-blue?style=flat)](https://github.com/joeycumines/ExactMac)
[![Swift Coverage](https://img.shields.io/badge/Swift%20Coverage-see%20CI-blue?style=flat)](https://github.com/joeycumines/ExactMac/actions)

> Fork note: ExactMac was forked from [`mediar-ai/MacosUseSDK`](https://github.com/mediar-ai/MacosUseSDK) and is unaffiliated with mediar-ai. Upstream built an embedded SDK; ExactMac is a background service, a Go MCP proxy plus a Swift gRPC daemon, for OS-level automation. [macos-use.dev](https://macos-use.dev/) documents a different project, [`mediar-ai/mcp-server-macos-use`](https://github.com/mediar-ai/mcp-server-macos-use); a code-grounded comparison is in [docs/ai-artifacts/12-mcp-server-macos-use-analysis.md](docs/ai-artifacts/12-mcp-server-macos-use-analysis.md).

# ExactMac

macOS desktop automation for AI coding tools, over MCP.

Let the assistant you already code with operate your Mac: open apps, click the button called `"Send"`, type into fields, arrange windows, then check its work. ExactMac is one local [Model Context Protocol](https://modelcontextprotocol.io/) server, reached over stdio or Streamable HTTP.

It works with Claude Code, Codex CLI, the Codex app, Cursor, OpenCode, Gemini CLI, VS Code, Windsurf, and Claude Desktop. If the tool speaks MCP over stdio, it can use ExactMac.

## Why ExactMac

Built-in computer use (Claude Code `computer-use`, Codex background use) is screenshot-first: the full screen is re-described each step and clicks are guessed from pixels, with per-session approvals and one machine-wide lock. ExactMac reads the native Accessibility tree, the same structured data VoiceOver uses, so agents click by text.

Most macOS MCP servers wrap AppleScript (scriptable apps only), loop screenshots (vision tokens per click), or click raw coordinates with no ownership. ExactMac instead:

- **Accessibility first.** Structured roles, labels, and coordinates. Screenshots are for verification, canvas apps, and IDEs with Accessibility disabled (visual-grounding fallback in the skill).
- **Owned input.** Each click, keypress, drag, and scroll names one application, window, display, or explicit desktop target, brings it to focus before acting, and returns a delivery result rather than a bare `OK`.
- **29 tools, one server.** Capture, mouse, keyboard, element search and interaction, window and application management, clipboard, command execution, display grounding, and recorded macros. Stdio or Streamable HTTP, with TLS, API-key auth, rate limiting, and audit logging.
- **Local only.** A Swift gRPC service plus a Go MCP proxy on the machine. The server itself makes no network calls.

## Setup

Build from source with [CONTRIBUTING.md](CONTRIBUTING.md) (prerequisites, first build, tests). Deploy the menu-bar app and MCP server with [DEPLOYMENT.md](DEPLOYMENT.md) (app bundle, Unix socket, signing).

Point the proxy at the Swift backend with `EXACTMAC_SERVER_ADDR` (default `localhost:50051`; the socket deployment in [DEPLOYMENT.md](DEPLOYMENT.md) avoids TCP entirely).

Register it in the AI tool (snippets and checks for every client: [AI Tool Integration](docs/ai-artifacts/08-ai-tool-integration.md)):

| Tool | Where | Snippet |
|-----------|-------|---------|
| **Claude Code** | `claude mcp add` (project scope; `-s user` for global) | `claude mcp add exactmac -- /path/to/exactmac mcp` |
| **Codex CLI** | `~/.codex/config.toml` | `[mcp_servers.exactmac]` + `command = "/path/to/exactmac"` + `args = ["mcp"]` |
| **Cursor** | `~/.cursor/mcp.json` (global) or `.cursor/mcp.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **OpenCode** | `opencode.jsonc` / `opencode.json` | `"exactmac": { "type": "local", "command": ["/path/to/exactmac", "mcp"] }` |
| **Gemini CLI** | `~/.gemini/settings.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **Claude Desktop** | `~/Library/Application Support/Claude/claude_desktop_config.json` | `"exactmac": { "command": "/path/to/exactmac", "args": ["mcp"] }` |
| **VS Code / Windsurf** | MCP settings | same stdio command shape as above |

For repeatable GUI work, load the agent skill in `skills/exactmac/` (Claude Code plugin install: [AI Tool Integration](docs/ai-artifacts/08-ai-tool-integration.md#1-claude-code)): recovery steps, coordinate math, and workflow recipes.

## Components

- **ExactMac (Swift library):** Accessibility primitives (`AXUIElement`, CoreGraphics input, AppKit windows). Embedding notes under [Using the library](#using-the-library).
- **MCP server (Go CLI `cmd/exactmac`, `exactmac mcp`):** 29 MCP tools over stdio or Streamable HTTP (TCP or Unix socket), with rate limiting, API-key auth, and audit logging.
- **gRPC server (Swift, `Server/`):** Resource-oriented API following [Google's AIPs](https://google.aip.dev/): WindowRegistry, ObservationManager, SessionManager, LRO pattern for async operations. Automates several applications at once, streams observation changes, and is thread-safe under concurrency.

## Documentation

| Document | Contents |
|----------|-------------|
| [AI Tool Integration](docs/ai-artifacts/08-ai-tool-integration.md) | Per-client setup with snippets and verification steps |
| [Agent Skill](skills/exactmac/SKILL.md) | Workflow, recovery, and troubleshooting reference for agents |
| [Deployment Guide](DEPLOYMENT.md) | Local single-user deployment: app bundle, Unix socket, signing, TCC grants |
| [MCP Integration](docs/ai-artifacts/05-mcp-integration.md) | Protocol version, transports, security, tooling |
| [MCP Server Design](docs/ai-artifacts/11-mcp-server-design-for-computer-use-agents.md) | Design notes for the MCP surface |
| [Tool Design Review](docs/ai-artifacts/07-mcp-tool-design-review.md) | Tool surface review and rationale |

## Architecture

```
AI clients (Claude Code, Codex, Cursor, OpenCode, Gemini)
        |  JSON-RPC over Streamable HTTP or stdio
Go CLI (cmd/exactmac, `exactmac mcp`)
  29 MCP tools; rate limiting, API-key auth, audit logging
        |  gRPC (protobuf)
Swift gRPC server (Server/ExactMacServer)
  Resource-oriented API (Google AIPs); WindowRegistry,
  ObservationManager, SessionManager; LRO for async ops
        |  Native Swift APIs
Swift SDK (Sources/ExactMac)
  AXUIElement; CoreGraphics input; AppKit windows
```

Window and element reads use two authorities (see [window-state-management.md](docs/window-state-management.md)):

| Authority | API | Used for |
|-----------|-----|----------|
| **Quartz (CG)** | `CGWindowListCopyWindowInfo` | Fast enumeration, global list, metadata (may be stale) |
| **Accessibility (AX)** | `AXUIElement` | Fresh geometry, mutations, element interaction |

`ListWindows` reads Quartz; `GetWindow`, moves, and resizes use Accessibility; bridging uses `_AXUIElementGetWindow` with a 1000px heuristic fallback.

macOS keeps two coordinate systems:

| Coordinates | Origin | Y grows | Used by |
|-------------|--------|---------|---------|
| **Global Display (top-left origin)** | Main display, top-left | Down | Window bounds; CGWindowList, AX, CGEvent; every input position |
| **AppKit** | Main display, bottom-left | Up | NSWindow, NSScreen |

Window bounds and input positions share Global Display Coordinates, so no conversion is needed between them.
Display geometry is relative to the main display, and represents the physical layout of the displays.
The main display is always at (0,0).
This means secondary displays may sit at negative X (left of main), negative Y (above main), or any other position, relative to the main display.

## Configuration

Configuration is environment variables only. The defaults live in code: [internal/config/config.go](internal/config/config.go) for the Go proxy, [ServerConfig.swift](Server/Sources/ExactMacServer/ServerConfig.swift) for the Swift server. The documented reference is [Runtime configuration](DEPLOYMENT.md#runtime-configuration) in the deployment guide, with per-component settings repeated in [Server/README.md](Server/README.md) and [cmd/exactmac/README.md](cmd/exactmac/README.md).

## MCP tools

29 tools in 6 groups:

| Group | Tools | Covers |
|----------|-------|-------------|
| **Input** | `screenshot`, `click`, `double_click`, `type`, `keypress`, `scroll`, `drag`, `move`, `wait` | Capture, mouse, keyboard, wait |
| **Elements** | `find_elements`, `click_element`, `type_element`, `read_element` | Accessibility search and interaction |
| **Windows** | `focus_window`, `move_window`, `resize_window`, `list_windows` | Enumeration and manipulation |
| **Applications** | `open_app`, `list_apps`, `close_app` | Lifecycle management |
| **Utility** | `clipboard`, `run`, `get_display` | Clipboard, command execution, display grounding |
| **Macros** | `create_macro`, `get_macro`, `list_macros`, `update_macro`, `delete_macro`, `execute_macro` | Recorded multi-step sequences |

HTTP example (full protocol: [MCP Integration](docs/ai-artifacts/05-mcp-integration.md)). Initialize, then pass the session id back on each call:

```sh
curl -X POST http://localhost:8080/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"example","version":"1.0"}}}'

curl -X POST http://localhost:8080/mcp \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2025-11-25" \
  -H "MCP-Session-Id: <session-id-from-initialize>" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}'
```

`open_app` takes the exact application resource `list_apps` returns.

## Using the library

The root Swift package publishes only the `ExactMac` library. Use it as a local dependency in another Swift project:

```swift
dependencies: [
    .package(path: "../ExactMac"),
]
```

```swift
.target(
    name: "YourApp",
    dependencies: ["ExactMac"]),
```

```swift
import ExactMac
```

The SDK exposes process-local Accessibility and Core Graphics primitives. Those functions lack core the functionality which differentiates this computer use implementation from the rest.
Production automation should use the generated `ExactMac` client or the MCP server so each input names an exact target and returns a delivery result.
Note: Delivery of inputs may still be best-effort, dependent on the means of input.

## Fork history

ExactMac began as a fork of [`mediar-ai/MacosUseSDK`](https://github.com/mediar-ai/MacosUseSDK) and has since diverged; the shipped implementation is post-fork work. Development used AI-assisted coding with human review; the author is not a Swift specialist.

## License

MIT License; see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
