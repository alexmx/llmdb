# llmdb

> Debug any Mac or iOS Simulator app from your terminal or your AI agent.

Wraps `lldb-dap` (Apple's Debug Adapter Protocol shim over LLDB) and gives AI agents a structured, session-oriented debugger. Launch a binary, set a breakpoint, step through code, inspect locals, evaluate expressions — all returning JSON, all driven by the same 22 verbs from the command line or over MCP.

## See it in action

A complete debug session — launch, break, continue, inspect, evaluate, step — in seven calls. Run it yourself against the bundled Swift fixture (`swift build` first).

### 1. Launch — start the binary under the debugger

```bash
llmdb launch ./.build/debug/llmdb-fixture quick
{
  "sessionId" : "2649sk",
  "state" : "stopped",
  "stopReason" : { "reason" : "exception", "description" : "signal SIGSTOP", ... }
}
```

The daemon auto-spawns on first call. The binary stops on entry so the next call has a quiescent target.

### 2. Set a breakpoint and run until it hits — one call

```bash
llmdb run-until ./Sources/Fixture/main.swift:35
{
  "breakpoint" : { "id" : 1, "line" : 35, "verified" : true, ... },
  "snapshot"   : {
    "state" : "stopped",
    "stopReason" : { "reason" : "breakpoint", "hitBreakpointIDs" : [1], ... }
  }
}
```

`run-until` composes `break set` + `continue` for the most common agent flow. Use the two separately when you want to inspect between. For interactive UI apps where the user might take any amount of time to trigger the breakpoint, pass `--wait none` to fire and return immediately, then call `llmdb wait` to block until the stop arrives.

### 3. Inspect — backtrace and typed locals

```bash
llmdb bt --depth 3
{ "frames" : [
    { "name" : "compute(x:y:)", "line" : 35, "source" : ".../main.swift", ... },
    { "name" : "llmdb_fixture_main", "line" : 63, ... },
    { "name" : "start", "source" : "/usr/lib/dyld`start", ... }
]}
```

```bash
llmdb locals
{ "locals" : [
    { "name" : "x",       "type" : "Int", "value" : "3"  },
    { "name" : "y",       "type" : "Int", "value" : "4"  },
    { "name" : "sum",     "type" : "Int", "value" : "7"  },
    { "name" : "product", "type" : "Int", "value" : "12" },
    { "name" : "diff",    "type" : "Int", "value" : "1"  },
    { "name" : "total",   "type" : "Int", "value" : "20" }
]}
```

Values are lldb-formatted strings — agents can read them directly without parsing memory layouts. A local with a non-zero `variablesReference` is structured (struct, array, object) — drill into it with `expand`:

```bash
llmdb expand 4
{ "children" : [
    { "name" : "[0]", "type" : "String", "value" : "\"alpha\"", "variablesReference" : 9 },
    { "name" : "[1]", "type" : "String", "value" : "\"beta\"",  "variablesReference" : 10 }
]}
```

Each child carries its own `variablesReference`, so you can keep drilling into nested values. `locals` only reads the **Locals** scope; to reach globals/statics or registers, list the frame's scopes and `expand` the one you want:

```bash
llmdb scopes
{ "scopes" : [
    { "name" : "Locals",    "variablesReference" : 1, "expensive" : false },
    { "name" : "Globals",   "variablesReference" : 2, "expensive" : false },
    { "name" : "Registers", "variablesReference" : 3, "expensive" : false }
]}
llmdb expand 2   # read the Globals scope
```

### 4. Evaluate — ask lldb anything

```bash
llmdb expr "sum + diff"
{ "type" : "Int", "value" : "8", "variablesReference" : 0 }
```

`expr` runs in the context of the current frame. Use it when `locals` isn't enough — for property access (`self.state.count`), method calls, or arithmetic over locals.

`set-var` goes the other way — it changes a variable mid-run so you can test a hypothesis without recompiling. `target` is any assignable expression (a local, `self.x`, `arr[0]`); it returns the variable's new value:

```bash
llmdb set-var counter 100
{ "variable" : { "name" : "counter", "type" : "Int", "value" : "100", "variablesReference" : 0 } }
```

`output` returns whatever the target wrote to stdout/stderr while running — so you can see what the program printed, not just its state:

```bash
llmdb output
{ "output" : [
    { "category" : "stdout", "text" : "compute(3, 4) = 20\n" },
    { "category" : "stdout", "text" : "fib(8) = 21\n" }
]}
```

Pass `--clear` to drain the buffer so the next call returns only output produced after this one.

### 5. Step — and verify you moved

```bash
llmdb step --over
{ "state" : "stopped", "stopReason" : { "reason" : "step", "description" : "step over", ... } }
```

```bash
llmdb bt --depth 1
{ "frames" : [{ "name" : "llmdb_fixture_main", "line" : 62, ... }] }
```

`--over` / `--in` / `--out` are mutually exclusive flags; default is `--over`.

### 6. Tear down

```bash
llmdb stop
{ "ok" : true }
```

## Install

### Homebrew

```bash
brew install alexmx/tools/llmdb
```

### Mise

```bash
mise use --global github:alexmx/llmdb
```

## Requirements

- macOS 15 or later
- Xcode or Command Line Tools (provides `lldb-dap`)
- A debuggable target — debug builds with `get-task-allow=true` (the Xcode default). Release builds with Hardened Runtime can't be attached without re-signing.

Run `llmdb doctor` to verify the toolchain and the daemon socket:

```bash
llmdb doctor
{ "checks" : [
    { "name" : "lldb-dap",   "ok" : true, "detail" : "/Applications/Xcode.app/.../lldb-dap" },
    { "name" : "socket-dir", "ok" : true, "detail" : "~/Library/Caches/llmdb" },
    { "name" : "daemon",     "ok" : true, "detail" : "~/Library/Caches/llmdb/llmdbd.sock" }
]}
```

Exits non-zero on any failure so it fits in shell scripts.

## More examples

```bash
# Attach to a running process by PID
llmdb attach --pid 12345

# Attach to a SwiftUI app in the booted iOS Simulator
llmdb attach --app com.example.MyApp

# List all sessions across all agents talking to this daemon
llmdb sessions

# Manage breakpoints
llmdb break set ./Sources/Fixture/main.swift:34
llmdb break set ./Sources/Fixture/main.swift:49 --condition "index == 2"
llmdb break exception                 # list available filters (swift_throw, …)
llmdb break exception swift_throw     # stop when the target throws a Swift error
llmdb break list
llmdb break delete 1

# Pause a running session
llmdb interrupt

# Inspect threads
llmdb threads
```

## Command reference

All commands return JSON by default (`--format json`). Pass `--session <id>` when more than one session is active.

### Lifecycle

| Command | Description | Key options |
|---|---|---|
| `launch <binary> [-- args…]` | Launch a binary or `.app` bundle under `lldb-dap`. Stops on entry. | `.app` bundles (or paths inside one) route via LaunchServices so the app registers with AppKit — needed for accessibility / UI-automation tools to see the process |
| `attach` | Attach to a running process or Simulator app | `--pid N` OR `--app <bundle-id>` (exactly one) |
| `stop` | Detach / terminate the session | `--session ID` |
| `sessions` | List active debug sessions | — |

### Breakpoints

| Command | Description | Key options |
|---|---|---|
| `break set <file>:<line>` | Set a source breakpoint; returns the verified BP and a session snapshot | `--condition <expr>`, `--hit-condition <expr>` |
| `break list` | List breakpoints in the session | — |
| `break delete <id>` | Remove a breakpoint by id; returns the survivors | — |
| `break exception [filters…]` | Stop on thrown exceptions; pass adapter filter ids (e.g. `swift_throw`), or none to clear and list available | — |

### Execution

All four blocking verbs accept `--wait <seconds|none>`. Default timeouts: `continue` 60s, `step` 30s, `interrupt` 10s, `run-until` 60s. `--wait none` (or `--wait 0`) is fire-and-forget — the target starts running and the call returns immediately; pair with `wait` to block later.

| Command | Description | Key options |
|---|---|---|
| `continue` | Resume until the next stop | `--wait <seconds\|none>` |
| `run-until <file>:<line>` | `break set` + `continue` in one call | `--wait <seconds\|none>` |
| `step` | Step one source line | `--over` (default), `--in`, `--out`; `--wait` |
| `interrupt` | Pause a running session | `--wait <seconds\|none>` |
| `wait` | Block until the session leaves `running` | `--timeout <seconds>` (default 60) |

### Inspection

| Command | Description | Key options |
|---|---|---|
| `bt` | Structured backtrace for the stopped thread | `--thread N`, `--depth N` |
| `locals` | Typed locals for a stack frame | `--frame N` (default 0) |
| `expand <ref>` | Drill into a structured value by its `variablesReference` | — |
| `scopes` | List a frame's scopes (Locals, Globals, Registers) with refs to `expand` | `--frame N`, `--thread N` |
| `threads` | List threads in the session | — |
| `expr <expression>` | Evaluate in the context of a frame | `--frame N` |
| `set-var <target> <value>` | Assign a new value to a variable (or lvalue like `self.x`) during a stop | `--frame N` |
| `output` | Captured stdout/stderr/console output from the target | `--clear` (drain the buffer) |

### System

| Command | Description | Key options |
|---|---|---|
| `doctor` | Verify lldb-dap, socket dir, daemon reachability. `daemon: ok+idle` on a fresh machine; only an unreachable stale socket counts as a failure. Exits 1 on any failure. | — |
| `daemon` | Run `llmdbd` (normally auto-spawned). | `--socket PATH` to override |
| `mcp` | Start the stdio MCP server. | `--setup` prints client config snippets |

## MCP server

llmdb runs as a stdio MCP server. Every CLI verb is exposed as an `llmdb_*` tool (`llmdb_launch`, `llmdb_break_set`, `llmdb_run_until`, …) mirroring the CLI 1:1.

```bash
llmdb mcp --setup   # prints config for Claude Code, Cursor, Codex CLI, etc.
```

Manual configuration:

```json
{
  "mcpServers": {
    "llmdb": { "command": "llmdb", "args": ["mcp"] }
  }
}
```

### Multi-agent isolation

Two agents driving llmdb at the same time share a single daemon by default — convenient, but they see each other's sessions and the "default session when only one is active" shortcut stops working. Give each agent its own daemon via the `LLMDB_SOCKET_PATH` env var:

```json
{
  "mcpServers": {
    "llmdb": {
      "command": "llmdb",
      "args": ["mcp"],
      "env": { "LLMDB_SOCKET_PATH": "/tmp/llmdb-agent-a.sock" }
    }
  }
}
```

Set a distinct path per agent — auto-spawn picks up the override automatically and each agent gets a fully isolated daemon, sessions, and `lldb-dap` children.

## License

Released under the [MIT License](LICENSE).
