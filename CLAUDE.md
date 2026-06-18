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

- **`llmdb daemon`** runs the background process. Lives at `~/Library/Caches/llmdb/llmdbd.sock` by default; override with `LLMDB_SOCKET_PATH=…` for isolated daemons (e.g., two MCP-driven agents that shouldn't share sessions — set a distinct path in each agent's environment and they each get their own daemon, with full session/state isolation). Owns the set of active debug sessions and their `lldb-dap` children.
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
- **launch** — Launch a binary under `lldb-dap`. Stops on entry; returns `sessionId`, `state`, `stopReason`.
- **attach** — `--pid N` (host PID) or `--app <bundle-id>` (resolves a bundle ID running in the booted iOS Simulator to a host PID via `xcrun simctl`). lldb-dap pauses on attach.
- **stop** — Detach/terminate a session.
- **sessions** — List active sessions.

### Breakpoints
- **break set** — `<file>:<line>`. `--symbol`/`--regex` deferred.
- **break list** — All breakpoints in the session.
- **break delete <id>** — Remove one; returns the surviving breakpoints.

### Execution
- **continue** — Resume until next stop. `--wait <seconds|none>` (default 60s); `--wait none` is fire-and-forget.
- **run-until `<file>:<line>`** — Set a breakpoint and continue in one call. Returns the stop snapshot and the breakpoint that was set. `--wait` as above.
- **step** — `--in` / `--over` (default) / `--out`. `--wait` (default 30s).
- **interrupt** — Pause a running session. `--wait` (default 10s).
- **wait** — Block until the session leaves `running` (stops or terminates). Pair with the fire-and-forget verbs. `--timeout <seconds>` (default 60).

### Inspection
- **bt** — Structured backtrace (`--thread`, `--depth`).
- **locals** — Typed locals for a frame.
- **threads** — List threads.
- **expr `<expression>`** — Evaluate in the context of a frame. Uses lldb's `watch` formatting (clean value, not REPL prefix).

### System
- **daemon** — Run the background daemon (normally auto-spawned).
- **doctor** — Diagnose env: `lldb-dap` resolves via xcrun, socket dir is writable, daemon socket is reachable (does NOT auto-spawn). Exits non-zero on any failure so it fits in shell scripts.
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

## Fixture

`Sources/Fixture/main.swift` builds as the `llmdb-fixture` executable — a deterministic guinea-pig binary used to exercise the debugger from tests and during manual development. Five canonical breakpoint targets are documented at the top of `main.swift`; **do not renumber** without updating the comment (and any tests that reference them).

```bash
swift build
swift run llmdb-fixture quick    # exits in <100ms, for launch/break/continue tests
swift run llmdb-fixture attach   # sleeps 30s mid-run, for attach --pid tests
```

## Milestones

- **M1 ✓:** daemon + `launch`, `break set`, `continue`, `bt`, `locals` end-to-end on the fixture binary.
- **M2 ✓:** full v0.1 verb surface shipped — `attach` (incl. `--app <bundle-id>` for the booted iOS Simulator via `xcrun simctl`), `interrupt`, `threads`, `step`, `expr`, `break list/delete`, `run-until`, `wait`, Simulator resolver. All execution verbs accept `--wait <seconds|none>` with fire-and-forget mode for interactive UI debugging.
- **M3:** Brew tap + mise + release automation.
