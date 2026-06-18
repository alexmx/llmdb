import Foundation
@testable import llmdb
import Testing

@Suite("DAPClient against llmdb-fixture")
struct DAPClientIntegrationTests {
    /// Drives the full M1 path: initialize → launch → setBreakpoints →
    /// configurationDone → stopped → stackTrace → scopes → variables.
    /// Asserts the locals at fixture BP1 match the math.
    @Test
    func breakpointAndLocals() async throws {
        let paths = try fixturePaths()

        let client = try await DAPClient.spawn()
        defer { Task { await client.terminate() } }

        _ = try await client.request("initialize", arguments: InitializeArgs(
            clientID: "llmdb-tests",
            clientName: "llmdb tests",
            adapterID: "lldb-dap",
            linesStartAt1: true,
            columnsStartAt1: true,
            pathFormat: "path",
            supportsRunInTerminalRequest: false
        ))

        _ = try await client.request("launch", arguments: LaunchArgs(
            program: paths.fixtureBinary,
            args: ["quick"],
            stopOnEntry: false
        ))

        _ = try await client.request("setBreakpoints", arguments: SetBreakpointsArgs(
            source: SourceArg(path: paths.fixtureSource),
            breakpoints: [BPLine(line: 35)]
        ))

        _ = try await client.request("configurationDone")

        let stopped = try await waitForEvent(client, named: "stopped", timeout: 10)
        let stoppedBody = try stopped.decodeBody(StoppedEventBody.self)
        #expect(stoppedBody.reason == "breakpoint")
        guard let threadId = stoppedBody.threadId else {
            Issue.record("stopped event had no threadId")
            return
        }

        let stackResp = try await client.request("stackTrace", arguments: StackTraceArgs(
            threadId: threadId, startFrame: 0, levels: 20
        ))
        let stack = try stackResp.decodeBody(StackTraceBody.self)
        #expect(!stack.stackFrames.isEmpty)
        let topFrame = stack.stackFrames[0]
        #expect(topFrame.name.contains("compute"))
        #expect(topFrame.line == 35)

        let scopesResp = try await client.request("scopes", arguments: ScopesArgs(frameId: topFrame.id))
        let scopes = try scopesResp.decodeBody(ScopesBody.self)
        guard let localsScope = scopes.scopes.first(where: { $0.name == "Locals" }) else {
            Issue.record("no Locals scope")
            return
        }

        let varsResp = try await client.request("variables", arguments: VariablesArgs(
            variablesReference: localsScope.variablesReference
        ))
        let vars = try varsResp.decodeBody(VariablesBody.self)

        var values: [String: String] = [:]
        for v in vars.variables {
            values[v.name] = v.value
        }
        #expect(values["x"] == "3")
        #expect(values["y"] == "4")
        #expect(values["sum"] == "7")
        #expect(values["product"] == "12")
        #expect(values["diff"] == "1")
        #expect(values["total"] == "20")
    }

    /// Wait for a specific DAP event by name. Uses DAPClient's built-in waiter.
    private func waitForEvent(
        _ client: DAPClient,
        named: String,
        timeout: TimeInterval
    ) async throws -> DAPEvent {
        let waiter = await client.waitForEvent(timeout: timeout) { $0.event == named }
        return try await waiter.value
    }

    private func fixturePaths() throws -> (fixtureBinary: String, fixtureSource: String) {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                let fixture = dir.appendingPathComponent(".build/debug/llmdb-fixture").path
                let source = dir.appendingPathComponent("Sources/Fixture/main.swift").path
                guard FileManager.default.fileExists(atPath: fixture) else {
                    throw TestSkip("llmdb-fixture not built — run `swift build` before testing")
                }
                return (fixture, source)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw TestSkip("could not locate Package.swift")
    }

    struct TestTimeout: Error, CustomStringConvertible {
        let seconds: TimeInterval
        let waitingFor: String
        var description: String {
            "timed out after \(seconds)s waiting for `\(waitingFor)` event"
        }
    }

    struct TestSkip: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) {
            self.message = m
        }

        var description: String {
            message
        }
    }
}
