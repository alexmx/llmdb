import ArgumentParser
import Foundation
import SwiftMCP

struct MCPServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Start an MCP server for AI tool integration"
    )

    @Flag(help: "Print setup instructions for popular AI coding agents")
    var setup = false

    func run() async {
        if setup {
            printSetup()
            return
        }

        let server = MCPServer(
            name: "llmdb",
            version: llmdbVersion,
            description: "Drive lldb-dap for macOS and iOS Simulator debugging. Start with llmdb_launch or llmdb_attach to open a session, then llmdb_break_set + llmdb_continue to run until a hit; inspect with llmdb_bt and llmdb_locals. All verbs return JSON with session_id, state, and stop_reason so you always know where the target is.",
            tools: LlmdbTools.all
        )
        await server.run()
    }

    private func printSetup() {
        print("""
        Add llmdb as an MCP server to your AI coding agent:

          Claude Code:          claude mcp add --transport stdio llmdb -- llmdb mcp
          Codex CLI:            codex mcp add llmdb -- llmdb mcp
          VS Code / Copilot:    code --add-mcp '{"name":"llmdb","command":"llmdb","args":["mcp"]}'
          Cursor:               cursor --add-mcp '{"name":"llmdb","command":"llmdb","args":["mcp"]}'
        """)
    }
}
