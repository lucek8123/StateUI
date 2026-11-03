// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

final class RPCTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("rpc")
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk, .web])
    }

    override func tearDownWithError() throws {
        TestFixture.remove(root)
    }

    func testFrameReaderReadsBackToBackFrames() throws {
        let first = Data(#"{"jsonrpc":"2.0","id":1,"method":"one"}"#.utf8)
        let second = Data(#"{"jsonrpc":"2.0","id":2,"method":"two"}"#.utf8)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(RPCFraming.frame(first) + RPCFraming.frame(second))
        try pipe.fileHandleForWriting.close()

        var reader = RPCFrameReader()
        XCTAssertEqual(try reader.next(from: pipe.fileHandleForReading), first)
        XCTAssertEqual(try reader.next(from: pipe.fileHandleForReading), second)
        XCTAssertNil(try reader.next(from: pipe.fileHandleForReading))
    }

    func testFrameReaderRejectsATruncatedBody() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("Content-Length: 10\r\n\r\nshort".utf8))
        try pipe.fileHandleForWriting.close()
        var reader = RPCFrameReader()
        XCTAssertThrowsError(try reader.next(from: pipe.fileHandleForReading)) { error in
            XCTAssertEqual(error.toolingError.code, "protocolError")
        }
    }

    func testRequestAndResponseEncoding() throws {
        let request = try JSON.decoder().decode(
            RPCRequest.self,
            from: Data(#"{"jsonrpc":"2.0","id":"a","method":"version"}"#.utf8)
        )
        XCTAssertEqual(request.id, RPCID.string("a"))
        XCTAssertFalse(request.isNotification)
        let notification = try JSON.decoder().decode(
            RPCRequest.self,
            from: Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8)
        )
        XCTAssertTrue(notification.isNotification)

        let response = RPCResponse(id: .int(3), result: .object(["ok": .bool(true)]))
        let decoded = try JSON.decoder().decode(
            JSONValue.self, from: try JSON.encoder().encode(response)
        )
        XCTAssertEqual(decoded["id"], JSONValue.int(3))
        XCTAssertEqual(decoded["jsonrpc"], JSONValue.string("2.0"))
        XCTAssertEqual(decoded["result"]?["ok"], JSONValue.bool(true))
    }

    func testToolingRPCInitializeDescribesHostsAndApplications() async throws {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        let result = try await handler.handle(
            method: "initialize", params: .object(["protocolVersion": .int(ToolingVersion.protocolVersion)])
        )
        XCTAssertEqual(result["serverInfo"]?["name"], JSONValue.string("stateui"))
        XCTAssertEqual(result["applications"], JSONValue.array([.string("Gallery")]))
        let hosts = try XCTUnwrap(result["hosts"]?.arrayValue)
        XCTAssertTrue(hosts.contains { $0["id"] == .string("gtk") })
        XCTAssertEqual(result["capabilities"]?["cancellation"], JSONValue.bool(true))
    }

    func testToolingRPCRejectsAFutureProtocolVersion() async {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        do {
            _ = try await handler.handle(
                method: "initialize",
                params: .object(["protocolVersion": .int(ToolingVersion.protocolVersion + 1)])
            )
            XCTFail("Expected a protocol version error.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "protocolVersionMismatch")
        }
    }

    func testToolingRPCConfigurationAndDryRunBuild() async throws {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        let saved = try await handler.handle(
            method: "config/set",
            params: .object([
                "host": .string("gtk"), "application": .string("Gallery"),
                "configuration": .string("release"),
            ])
        )
        XCTAssertEqual(saved["defaultHost"], JSONValue.string("gtk"))
        XCTAssertEqual(saved["configuration"], JSONValue.string("release"))

        let plan = try await handler.handle(
            method: "build",
            params: .object([
                "host": .string("gtk"), "application": .string("Gallery"),
                "configuration": .string("release"), "dryRun": .bool(true),
            ])
        )
        XCTAssertEqual(plan["host"], JSONValue.string("gtk"))
        XCTAssertEqual(plan["configuration"], JSONValue.string("release"))
        let steps = try XCTUnwrap(plan["steps"]?.arrayValue)
        XCTAssertFalse(steps.isEmpty)
        // A GTK build may stop a running head before it compiles, so the build
        // step is named rather than taken as the first.
        let build = try XCTUnwrap(steps.first(where: { ($0["label"]?.stringValue ?? "").hasPrefix("Build ") }))
        let command = try XCTUnwrap(build["arguments"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertEqual(command.first, "build")
        XCTAssertTrue(command.contains("--scratch-path"))
        XCTAssertTrue(command.contains(root.appendingPathComponent("apps/Gallery/.build/gtk").path))
        XCTAssertFalse(command.joined(separator: " ").contains(".scripts"))

        // A run of the RPC speaks nothing of the repository's old scripts.
        for step in steps {
            let arguments = step["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertFalse(arguments.contains { $0.contains(".scripts") }, "\(step["label"]?.stringValue ?? "") names a script")
        }
    }

    /// The same rule the CLI applies: an editor may name only an application the
    /// checkout answers, so `config/set` refuses a name nothing builds.
    func testToolingRPCRefusesAnApplicationThatStandsNowhere() async {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        do {
            _ = try await handler.handle(
                method: "config/set", params: .object(["application": .string("NoSuchApp")])
            )
            XCTFail("a name nothing answers was stored")
        } catch {
            let structured = error.toolingError
            XCTAssertEqual(structured.code, "applicationNotFound")
            XCTAssertTrue(structured.message.contains("NoSuchApp"))
        }
    }

    /// The Web host's size budgets are reached over the same protocol the
    /// editor speaks, and a host that ships nothing a page downloads is refused
    /// in the structured shape an editor can read.
    func testToolingRPCSizeBudgetsRefusesAHostWithNothingToWeigh() async {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        do {
            _ = try await handler.handle(method: "size/budgets", params: .object(["host": .string("gtk")]))
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "unsupportedHost")
        }
    }

    /// A native suite is planned over RPC too: it names the machine's packages,
    /// and asks no host driver, so nothing of a host is probed.
    func testToolingRPCNativeSuitePlansTheMachinePackages() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery", "HelloWorld"], hosts: [.gtk])
        let executor = ScriptedProcessExecutor()
        let handler = ToolingRPC(
            tooling: Tooling.fixture(
                at: root, executor: executor,
                environment: Environment(["SWIFT_BIN": "/bin/sh"]),
                platform: Platform(operatingSystem: .linux, architecture: .x86_64)
            )
        )
        let plan = try await handler.handle(
            method: "test",
            params: .object([
                "host": .string("gtk"), "suite": .string("native"), "dryRun": .bool(true),
            ])
        )
        // A dry run answers with the plan itself, which names the machine's packages.
        let suites = try XCTUnwrap(plan["suites"]?.arrayValue)
        XCTAssertEqual(
            suites.compactMap { $0["name"]?.stringValue },
            ["the repository's own packages", "apps/Gallery", "apps/HelloWorld"]
        )
        let recorded = await executor.recorded()
        XCTAssertEqual(recorded.count, 0)
    }

    /// A plan is an immediate answer; running one is a task an editor follows.
    func testToolingRPCClassifiesRunsAsTasksButPlansAsAnswers() {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        XCTAssertTrue(handler.isLongRunning(method: "build", params: nil))
        XCTAssertFalse(handler.isLongRunning(
            method: "build", params: .object(["dryRun": .bool(true)])
        ))
        XCTAssertTrue(handler.isLongRunning(method: "debug/prepare", params: nil))
        XCTAssertFalse(handler.isLongRunning(method: "version", params: nil))
    }

    func testToolingRPCUnknownMethodIsStructured() async {
        let handler = ToolingRPC(tooling: Tooling.fixture(at: root))
        do {
            _ = try await handler.handle(method: "no/such", params: nil)
            XCTFail("Expected an error.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "protocolError")
        }
    }

    /// `group/releases` answers with the releases the floor the editor declares leaves
    /// standing: the extension forwards a version and the binary compares it.
    func testToolingRPCGroupReleasesAppliesTheFloor() async throws {
        let git = try TestFixture.fakeTool(named: "git", in: root.appendingPathComponent("fakebin", isDirectory: true))
        let handler = ToolingRPC(tooling: Tooling.fixture(
            at: root,
            executor: ScriptedProcessExecutor(answers: [
                "reading the checkout's release branches": ScriptedProcessExecutor.Answer(
                    result: ProcessResult(exitCode: 0, standardOutput: "origin/1.2.0-release\norigin/0.5.0-release\n")
                ),
            ]),
            environment: Environment(["PATH": git.deletingLastPathComponent().path])
        ))
        let offered = try await handler.handle(method: "group/releases", params: .object(["minimum": .string("1.0")]))
        XCTAssertEqual(offered.arrayValue, [.string("1.2.0")])

        do {
            _ = try await handler.handle(method: "group/releases", params: .object(["minimum": .string("next")]))
            XCTFail("Expected a floor naming no version to be refused.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "invalidArguments")
        }
    }

    func testServerAnswersOverContentLengthFramedStdio() async throws {
        let input = Pipe()
        let output = Pipe()
        let server = RPCServer(
            handler: ToolingRPC(tooling: Tooling.fixture(at: root)),
            input: input.fileHandleForReading, output: output.fileHandleForWriting,
            logger: Logger(level: .quiet)
        )
        let running = Task.detached { try await server.run() }

        let initialize = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":\#(ToolingVersion.protocolVersion)}}"#.utf8
        )
        input.fileHandleForWriting.write(RPCFraming.frame(initialize))
        var reader = RPCFrameReader()
        let body = try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        let response = try JSON.decoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(response["id"], JSONValue.int(1))
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"], JSONValue.string("stateui"))

        input.fileHandleForWriting.write(
            RPCFraming.frame(Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8))
        )
        try? input.fileHandleForWriting.close()
        try await running.value
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
    }

    /// A long-running method answers at once, streams its progress, and reports
    /// its result in a completion notification rather than the reply.
    func testServerRunsATaskAndReportsProgress() async throws {
        let input = Pipe()
        let output = Pipe()
        let server = RPCServer(
            handler: ReportingHandler(), input: input.fileHandleForReading,
            output: output.fileHandleForWriting, logger: Logger(level: .quiet)
        )
        let running = Task.detached { try await server.run() }
        var reader = RPCFrameReader()

        input.fileHandleForWriting.write(RPCFraming.frame(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"slow"}"#.utf8)
        ))
        let started = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        let taskID = try XCTUnwrap(started["result"]?["taskId"]?.stringValue)
        XCTAssertEqual(started["result"]?["status"], JSONValue.string("started"))

        let first = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        XCTAssertEqual(first["method"], JSONValue.string("task.progress"))
        XCTAssertEqual(first["params"]?["taskId"]?.stringValue, taskID)
        XCTAssertEqual(first["params"]?["message"], JSONValue.string("first\n"))

        let second = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        XCTAssertEqual(second["method"], JSONValue.string("task.progress"))
        XCTAssertEqual(second["params"]?["message"], JSONValue.string("second\n"))

        let completed = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        XCTAssertEqual(completed["method"], JSONValue.string("task.completed"))
        XCTAssertEqual(completed["params"]?["taskId"]?.stringValue, taskID)
        XCTAssertEqual(completed["params"]?["result"]?["ok"], JSONValue.bool(true))

        input.fileHandleForWriting.write(RPCFraming.frame(Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8)))
        try? input.fileHandleForWriting.close()
        try await running.value
        try? output.fileHandleForWriting.close()
    }

    /// Cancelling by the request id stops the task the reply named, and the
    /// failure names the task rather than answering the original request twice.
    func testServerCancelsATask() async throws {
        let input = Pipe()
        let output = Pipe()
        let server = RPCServer(
            handler: ReportingHandler(), input: input.fileHandleForReading,
            output: output.fileHandleForWriting, logger: Logger(level: .quiet)
        )
        let running = Task.detached { try await server.run() }
        var reader = RPCFrameReader()

        input.fileHandleForWriting.write(RPCFraming.frame(
            Data(#"{"jsonrpc":"2.0","id":7,"method":"verySlow"}"#.utf8)
        ))
        let started = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        XCTAssertEqual(started["result"]?["status"], JSONValue.string("started"))

        input.fileHandleForWriting.write(RPCFraming.frame(
            Data(#"{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}"#.utf8)
        ))
        let failed = try JSON.decoder().decode(
            JSONValue.self, from: try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        )
        XCTAssertEqual(failed["method"], JSONValue.string("task.failed"))
        XCTAssertEqual(failed["params"]?["error"]?["code"], JSONValue.int(-32800))

        input.fileHandleForWriting.write(RPCFraming.frame(Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8)))
        try? input.fileHandleForWriting.close()
        try await running.value
        try? output.fileHandleForWriting.close()
    }

    func testServerReportsAParseErrorAndKeepsServing() async throws {
        let input = Pipe()
        let output = Pipe()
        let server = RPCServer(
            handler: ToolingRPC(tooling: Tooling.fixture(at: root)),
            input: input.fileHandleForReading, output: output.fileHandleForWriting,
            logger: Logger(level: .quiet)
        )
        let running = Task.detached { try await server.run() }

        input.fileHandleForWriting.write(RPCFraming.frame(Data("not json".utf8)))
        input.fileHandleForWriting.write(
            RPCFraming.frame(Data(#"{"jsonrpc":"2.0","id":2,"method":"version"}"#.utf8))
        )
        var reader = RPCFrameReader()
        let first = try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        let error = try JSON.decoder().decode(JSONValue.self, from: first)
        XCTAssertEqual(error["error"]?["code"], JSONValue.int(-32700))
        let second = try XCTUnwrap(try reader.next(from: output.fileHandleForReading))
        let version = try JSON.decoder().decode(JSONValue.self, from: second)
        XCTAssertEqual(version["result"]?["name"], JSONValue.string("stateui"))

        input.fileHandleForWriting.write(
            RPCFraming.frame(Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8))
        )
        try? input.fileHandleForWriting.close()
        try await running.value
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForWriting.close()
    }
}

/// A handler whose methods report progress and wait, so the server's task
/// lifecycle is exercised without a toolchain.
private struct ReportingHandler: RPCHandling {
    func isLongRunning(method: String, params: JSONValue?) -> Bool {
        method == "slow" || method == "verySlow"
    }

    func handle(
        method: String, params: JSONValue?, context: RPCContext
    ) async throws -> JSONValue {
        if method == "verySlow" {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return .object(["done": .bool(true)])
        }
        context.progress("first\n")
        try await Task.sleep(nanoseconds: 5_000_000)
        context.progress("second\n")
        return .object(["ok": .bool(true)])
    }
}
