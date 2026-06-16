# llmdb

## What is llmdb?

llmdb is a macOS CLI tool and MCP server that wraps `lldb-dap` to give AI agents a structured, session-oriented debugger for macOS and iOS Simulator apps. Verbs return JSON; sessions persist across CLI invocations via a background daemon.

## Project Structure

```
llmdb/
├── Package.swift                    # SPM manifest (macOS 15+, Swift 6.2)
├── Sources/llmdb/
│   ├── llmdb.swift                  # @main entry point, registers all subcommands
│   ├── Version.swift
│   ├── Commands/                    # One file per CLI command
│   ├── Core/                        # DAP client, session manager, daemon client, sim resolver
│   ├── Models/                      # Session, StopReason, Frame, etc.
│   ├── MCP/
│   │   └── LlmdbTools.swift         # MCP tool definitions, mirror CLI 1:1
│   └── Utilities/                   # Output formatting, error types
└── Tests/llmdbTests/
```

## Build & Run

```bash
swift build
swift run llmdb <command> [options]
```

**Requirements:** macOS 15+, Swift 6.2, Xcode toolchain (for `lldb-dap`).

**Dependencies:**
- `swift-argument-parser` — CLI argument parsing
- `swift-cli-mcp` — MCP server framework
- `swift-subprocess` — async subprocess (for `lldb-dap` and `xcrun simctl`)
- `toon-swift` — token-optimized output format for LLM consumers

## Architecture

- **`llmdb daemon`** runs the background process. Lives at `~/Library/Caches/llmdb/llmdbd.sock`. Owns the set of active debug sessions and their `lldb-dap` children.
- **CLI commands** auto-spawn the daemon on first use, then JSON-RPC over the socket. Pass `--session <id>` when multiple are active.
- **`llmdb mcp`** is another client of the daemon (or embeds the same Core directly — TBD).
- **`Core/DAPClient`** speaks Debug Adapter Protocol (Content-Length-framed JSON over stdio) to `lldb-dap`.
- **`Core/SessionManager`** tracks sessions, multiplexes DAP events back to subscribers.
- **`Core/SimulatorResolver`** wraps `xcrun simctl` for iOS Simulator app-id → PID resolution.

## Version Management & Releases

**Version Source:** `.llmdb-version` file in repo root (when added).

- `Sources/llmdb/Version.swift` defines `llmdbVersion` (defaults to "dev" for local builds).
- GitHub Actions will read `.llmdb-version`, regenerate `Version.swift`, build a universal binary, publish a GitHub release, and bump the Homebrew formula. Workflow TBD.

**Distribution (planned):**

```bash
brew tap alexmx/tools
brew install llmdb

# or
mise use --global github:alexmx/llmdb
```

## Commands (v0.1 target)

All commands accept `--format json|toon|plain` (default JSON, matching agent-first orientation).

### Lifecycle
- **launch** — Launch a binary under `lldb-dap`. Returns `session_id`.
- **attach** — Attach by `--pid` or `--app <bundle-id>` (Simulator resolved via `xcrun simctl`).
- **stop** — Detach/terminate a session.
- **sessions** — List active sessions.

### Breakpoints
- **break set** — `<file>:<line>` or `--symbol <name>` or `--regex <pattern>`.
- **break list** / **break delete**.

### Execution
- **continue**, **step** (`--in`/`--over`/`--out`), **run-until** (set bp + continue + wait for hit), **interrupt**.

### Inspection
- **bt** — Structured backtrace (`--thread`, `--depth`).
- **locals** — Typed locals for a frame.
- **expr** — Evaluate an expression in the current frame.
- **threads** — List threads with state.

### System
- **daemon** — Run the background daemon (normally auto-spawned).
- **doctor** — Verify `lldb-dap` is available, socket is writable, no other daemon is running.
- **mcp** — Start MCP server. `--setup` prints integration instructions.

## Output contract

Every verb returns `{session_id, state, stop_reason?, thread?, frame?, ...payload}` so the agent always knows where it is without a follow-up call.

## Adding a New Command

1. Create `Sources/llmdb/Commands/NewCommand.swift` implementing `AsyncParsableCommand`.
2. Register it in `llmdb.swift`.
3. Put business logic in `Core/` (DAP/session-aware) or `Utilities/` (pure).
4. Mirror it as an MCP tool in `MCP/LlmdbTools.swift`.
5. Add any new model types under `Models/`.

## Formatting

```bash
swiftformat .
```

## Milestones

- **M1 (current):** daemon + `launch`, `break set`, `continue`, `bt`, `locals` working end-to-end on a Swift Debug build.
- **M2:** the rest of the v0.1 verb surface + iOS Simulator app-id resolver.
- **M3:** Brew tap + mise + release automation.
