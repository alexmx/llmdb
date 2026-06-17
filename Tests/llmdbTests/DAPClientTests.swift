import Foundation
import Testing
@testable import llmdb

@Suite("DAPClient against llmdb-fixture")
struct DAPClientIntegrationTests {

    /// Drives the full M1 path: initialize → launch → setBreakpoints →
    /// configurationDone → stopped → stackTrace → scopes → variables.
    /// Asserts the locals at fixture BP1 match the math.
    @Test("hits BP1 in compute() and reads the expected locals")
    func breakpointAndLocals() async throws {
        let paths = try fixturePaths()

        let client = try DAPClient()
        defer { Task { await client.terminate() } }

        // initialize
        _ = try await client.request("initialize", arguments: InitializeArgs(
            clientID: "llmdb-tests",
            clientName: "llmdb tests",
            adapterID: "lldb-dap",
            linesStartAt1: true,
            columnsStartAt1: true,
            pathFormat: "path"
        ))

        // launch
        _ = try await client.request("launch", arguments: LaunchArgs(
            program: paths.fixtureBinary,
            args: ["quick"],
            stopOnEntry: false
        ))

        // setBreakpoints
        _ = try await client.request("setBreakpoints", arguments: SetBreakpointsArgs(
            source: SourceArg(path: paths.fixtureSource),
            breakpoints: [BPLocation(line: 34)]
        ))

        // configurationDone — program will start running
        _ = try await client.request("configurationDone")

        // Wait for the stopped event
        let stopped = try await waitForEvent(client, named: "stopped", timeout: 10)
        let stoppedBody = try stopped.decodeBody(StoppedBody.self)
        #expect(stoppedBody.reason == "breakpoint")

        // stackTrace
        let stackResp = try await client.request("stackTrace", arguments: StackTraceArgs(
            threadId: stoppedBody.threadId,
            startFrame: 0,
            levels: 20
        ))
        let stack = try stackResp.decodeBody(StackTraceBody.self)
        #expect(!stack.stackFrames.isEmpty)
        let topFrame = stack.stackFrames[0]
        #expect(topFrame.name.contains("compute"))
        #expect(topFrame.line == 34)

        // scopes
        let scopesResp = try await client.request("scopes", arguments: ScopesArgs(
            frameId: topFrame.id
        ))
        let scopes = try scopesResp.decodeBody(ScopesBody.self)
        guard let localsScope = scopes.scopes.first(where: { $0.name == "Locals" }) else {
            Issue.record("no Locals scope")
            return
        }

        // variables
        let varsResp = try await client.request("variables", arguments: VariablesArgs(
            variablesReference: localsScope.variablesReference
        ))
        let vars = try varsResp.decodeBody(VariablesBody.self)

        // Build a name → value map and assert the fixture's arithmetic.
        var values: [String: String] = [:]
        for v in vars.variables { values[v.name] = v.value }
        #expect(values["x"] == "3")
        #expect(values["y"] == "4")
        #expect(values["sum"] == "7")
        #expect(values["product"] == "12")
        #expect(values["diff"] == "1")
        #expect(values["total"] == "20")
    }

    // MARK: - Helpers

    /// Wait for a specific DAP event by name. Drains intervening events.
    private func waitForEvent(
        _ client: DAPClient,
        named: String,
        timeout: TimeInterval
    ) async throws -> DAPEvent {
        try await withThrowingTaskGroup(of: DAPEvent.self) { group in
            group.addTask {
                for await event in client.events where event.event == named {
                    return event
                }
                throw DAPError.closed
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TestTimeout(seconds: timeout, waitingFor: named)
            }
            let event = try await group.next()!
            group.cancelAll()
            return event
        }
    }

    private func fixturePaths() throws -> (fixtureBinary: String, fixtureSource: String) {
        // The test binary lives somewhere under .build/debug/. Walk up to the
        // package root (where Package.swift lives) and resolve from there.
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
        throw TestSkip("could not locate Package.swift from test source location")
    }

    struct TestTimeout: Error, CustomStringConvertible {
        let seconds: TimeInterval
        let waitingFor: String
        var description: String { "timed out after \(seconds)s waiting for `\(waitingFor)` event" }
    }

    struct TestSkip: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }
}

// MARK: - DAP wire types used by the test

private struct InitializeArgs: Encodable, Sendable {
    let clientID: String
    let clientName: String
    let adapterID: String
    let linesStartAt1: Bool
    let columnsStartAt1: Bool
    let pathFormat: String
}

private struct LaunchArgs: Encodable, Sendable {
    let program: String
    let args: [String]
    let stopOnEntry: Bool
}

private struct SourceArg: Encodable, Sendable {
    let path: String
}

private struct BPLocation: Encodable, Sendable {
    let line: Int
}

private struct SetBreakpointsArgs: Encodable, Sendable {
    let source: SourceArg
    let breakpoints: [BPLocation]
}

private struct StackTraceArgs: Encodable, Sendable {
    let threadId: Int
    let startFrame: Int
    let levels: Int
}

private struct ScopesArgs: Encodable, Sendable {
    let frameId: Int
}

private struct VariablesArgs: Encodable, Sendable {
    let variablesReference: Int
}

private struct StoppedBody: Decodable, Sendable {
    let reason: String
    let threadId: Int
    let description: String?
    let hitBreakpointIds: [Int]?
}

private struct DAPFrame: Decodable, Sendable {
    let id: Int
    let name: String
    let line: Int?
    let column: Int?
}

private struct StackTraceBody: Decodable, Sendable {
    let stackFrames: [DAPFrame]
    let totalFrames: Int?
}

private struct Scope: Decodable, Sendable {
    let name: String
    let variablesReference: Int
}

private struct ScopesBody: Decodable, Sendable {
    let scopes: [Scope]
}

private struct DAPVariable: Decodable, Sendable {
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
}

private struct VariablesBody: Decodable, Sendable {
    let variables: [DAPVariable]
}
