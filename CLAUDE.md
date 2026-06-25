# llmdb

macOS CLI + MCP server wrapping `lldb-dap` to give AI agents a structured, session-oriented debugger. Verbs return JSON; sessions persist across invocations via a background daemon. See `README.md` for the user-facing verb reference.

## Project structure

```
llmdb/
├── Package.swift              # SPM manifest (macOS 15+, Swift 6.2)
├── .llmdb-version             # release version; CI reads this on push to main
├── Sources/
│   ├── llmdb/
│   │   ├── llmdb.swift        # @main, registers subcommands
│   │   ├── Version.swift      # CI-generated on release; "dev" locally
│   │   ├── Commands/          # One file per CLI verb
│   │   ├── Core/              # DAPClient, SessionManager, Daemon, DaemonClient, SimulatorResolver, AppBundleLauncher
│   │   ├── Models/            # Session, StopReason, Frame, Breakpoint, Thread, …
│   │   ├── MCP/LlmdbTools.swift  # MCP tools, 1:1 with CLI
│   │   └── Utilities/         # OutputFormat, JSONOutput, error types, WaitSpec
│   ├── Fixture/main.swift     # llmdb-fixture — see Fixture below
│   └── ThrowFixture/main.swift # llmdb-throw-fixture — throws a Swift error (exception-BP tests)
└── Tests/llmdbTests/
```

## Build & test

```bash
swift build
swift test
swift run llmdb <command> [options]
```

Requirements: macOS 15+, Swift 6.2, Xcode toolchain (for `lldb-dap`).

Deps: `swift-argument-parser`, `swift-cli-mcp`, `swift-subprocess`, `toon-swift`.

## Architecture

- **`llmdbd`** — Unix-socket JSON-RPC server at `~/Library/Caches/llmdb/llmdbd.sock`. Owns sessions and their `lldb-dap` children. Auto-spawned by CLI/MCP on first call. Set `LLMDB_SOCKET_PATH=…` to give an agent its own daemon (e.g. per-MCP-server isolation).
- **`DAPClient`** speaks DAP (Content-Length JSON over stdio) to one `lldb-dap` per session. Event fan-out lives here: each subscriber gets its own `AsyncStream` via `client.events()` / `client.waitForEvent(...)`. Do not re-introduce a single-consumer model — the listener and per-call waiters share the stream.
- **`SessionManager`** orchestrates the DAP handshake, tracks the most recent stop, exposes the high-level verbs.
- **`SimulatorResolver`** wraps `xcrun simctl` for `bundle-id → host PID`.
- **`AppBundleLauncher`** routes `.app` paths through `NSWorkspace.openApplication` and attaches by PID instead of `exec`ing the inner binary directly. Without this, AppKit/AX-driven tools can't see the launched process.

Every verb returns `{sessionId, state, stopReason?, …}` so the agent always knows where it is. Execution verbs (continue/step/interrupt/run-until) accept `wait` (seconds, default per-verb; `0` = fire-and-forget — pair with the `wait` verb).

## Fixture

`Sources/Fixture/main.swift` is a deterministic guinea-pig binary used by tests + the smoke harness. Five canonical breakpoint targets are documented at the top of the file. **Do not renumber** — tests hard-code the line numbers, and the file is pinned with `// swiftformat:disable all` because the formatter was collapsing `let x = …; return x` patterns and shifting lines.

```bash
swift run llmdb-fixture quick    # <100ms, launch/break/continue path
swift run llmdb-fixture attach   # 30s sleep with PID printed, attach path
```

`Sources/ThrowFixture/main.swift` (`llmdb-throw-fixture`) is a separate binary that throws a Swift error — used by exception-breakpoint tests. It's separate because adding a throw path to `llmdb-fixture` perturbs that file's debug line tables and breaks its pinned breakpoint line numbers.

## Smoke harness

`scratch/mcp-smoke.py` drives the full MCP surface end-to-end via stdio JSON-RPC. Run after touching the MCP layer or adding/renaming a tool. Updates `tools/list` count assertion if the tool set changes.

## Adding a new command

1. `Sources/llmdb/Commands/NewCommand.swift` implementing `AsyncParsableCommand`.
2. Register in `llmdb.swift`.
3. Business logic in `Core/` (DAP/session-aware) or `Utilities/` (pure).
4. Mirror in `MCP/LlmdbTools.swift` — keep descriptions tight, agent-actionable, standard `session_id` hint.
5. Add models under `Models/`.
6. Update `scratch/mcp-smoke.py`.

## Releases

`.llmdb-version` is the source of truth. Pushing a change to `main` triggers `.github/workflows/release.yml`:

1. regenerates `Sources/llmdb/Version.swift` from `.llmdb-version`
2. builds a universal macOS binary (arm64 + x86_64)
3. tags `v<version>`, publishes a GitHub release with the zip + SHA256
4. updates `alexmx/homebrew-tools/Formula/llmdb.rb` with the new URL + SHA256

Users install via `brew install alexmx/tools/llmdb` or `mise use github:alexmx/llmdb`.

## Formatting

`swiftformat .` — fixture is excluded via in-file directive (do not remove).