# llmdb

> Debug any Mac or iOS Simulator app from your terminal or your AI agent.

A macOS CLI tool and MCP server that wraps `lldb-dap` to give AI agents a structured, session-oriented debugger. Launch a binary, set breakpoints, walk the stack, inspect locals — all returning JSON, all driven by the same verbs from the command line or over MCP.

## Status

Pre-alpha. v0.1 verb surface complete (M1 + M2). 15 CLI verbs / 15 MCP tools wired through the `llmdbd` Unix-socket daemon. iOS Simulator app debugging works via `llmdb attach --app <bundle-id>`. Next up: M3 — Brew tap + mise + release automation.

## Install

Coming soon via Homebrew tap and mise.

## Quick start

```bash
# Launch a Swift binary under the debugger
llmdb launch ./build/MyApp

# Set a breakpoint and run until it hits
llmdb break set MyApp/main.swift:42
llmdb continue

# Inspect
llmdb bt
llmdb locals
```

## Architecture

```
┌─ llmdb CLI ──┐  unix socket   ┌─ llmdbd ──────────┐  DAP/stdio  ┌─ lldb-dap ─┐
│ one-shot     │ ─────────────► │ owns sessions     │ ──────────► │ per session│
│ commands     │ ◄───────────── │ JSON-RPC surface  │ ◄────────── │            │
└──────────────┘                └───────────────────┘             └────────────┘
        ▲                              ▲
   ┌─ llmdb mcp ──┐                    │
   │ MCP server   │ ───────────────────┘
   └──────────────┘
```

- `llmdb daemon` runs the background process that owns active debug sessions. Socket lives at `~/Library/Caches/llmdb/llmdbd.sock`; set `LLMDB_SOCKET_PATH=…` in an agent's environment to give it an isolated daemon (handy when two MCP agents shouldn't share sessions).
- The CLI and MCP server are both thin clients; first invocation auto-spawns the daemon.
- Each session backs onto its own `lldb-dap` child process.

## v0.1 scope

**In:** macOS + iOS Simulator targets, Debug builds of your own apps, `launch`/`attach`/`stop`, breakpoints (file:line / symbol), step/continue/run-until/interrupt, backtrace, locals, expressions, threads. JSON output by default.

**Out:** watchpoints, conditional breakpoints, memory/registers/disasm, core dumps, on-device iOS, custom formatters, multi-process, reverse debugging.

## License

MIT
