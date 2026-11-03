// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

#if !os(Windows)
import Foundation
import XCTest
@testable import StateUITooling

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The JSON-RPC server as a client sees it: a real `stateui rpc --stdio`
/// subprocess, with framed requests on its stdin and frames on its stdout.
final class SubprocessTests: XCTestCase {
    private var fixture: URL!
    private var process: Process?
    private var input: Pipe!
    private var output: Pipe!
    private var errors: Pipe!
    private var reader = RPCFrameReader()

    override func setUpWithError() throws {
        fixture = try TestFixture.temporaryDirectory("rpc-subprocess")
        try TestFixture.makeCheckout(at: fixture, applications: ["Gallery"], hosts: [.gtk])
    }

    override func tearDownWithError() throws {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        TestFixture.remove(fixture)
    }

    /// Framing, request correlation, notifications, malformed input, unknown
    /// methods, mistyped parameters, a clean shutdown, and stdout that carries
    /// frames and nothing else.
    func testFramedRequestsNotificationsAndErrors() throws {
        try start()

        try send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": ToolingVersion.protocolVersion],
        ])
        let initialized = try XCTUnwrap(try next())
        XCTAssertEqual(initialized["id"], JSONValue.int(1))
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], JSONValue.string("stateui"))
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["protocolVersion"], JSONValue.int(1))

        // Two requests written together are answered separately, each with its own id.
        try send(["jsonrpc": "2.0", "id": "a", "method": "version"])
        try send(["jsonrpc": "2.0", "id": "b", "method": "version"])
        let first = try XCTUnwrap(try next())
        let second = try XCTUnwrap(try next())
        XCTAssertEqual(
            Set([first["id"]?.stringValue, second["id"]?.stringValue]),
            Set(["a", "b"])
        )

        // A notification is handled and never answered.
        try send(["jsonrpc": "2.0", "method": "no/such"])
        XCTAssertNil(try next(timeout: 0.3))

        try send(["jsonrpc": "2.0", "id": 2, "method": "no/such"])
        let unknown = try XCTUnwrap(try next())
        XCTAssertEqual(unknown["error"]?["code"], JSONValue.int(-32000))
        XCTAssertEqual(unknown["error"]?["data"]?["code"], JSONValue.string("protocolError"))

        // A frame that is not JSON is a parse error, and the session survives it.
        try sendRaw(Data("not json".utf8))
        let parse = try XCTUnwrap(try next())
        XCTAssertEqual(parse["error"]?["code"], JSONValue.int(-32700))
        try send(["jsonrpc": "2.0", "id": 3, "method": "version"])
        let survived = try XCTUnwrap(try next())
        XCTAssertEqual(survived["id"], JSONValue.int(3))

        // A mistyped parameter is an immediate refusal, not a started task.
        try send([
            "jsonrpc": "2.0", "id": 4, "method": "build",
            "params": ["application": 123],
        ])
        let mistyped = try XCTUnwrap(try next())
        XCTAssertEqual(mistyped["id"], JSONValue.int(4))
        XCTAssertNil(mistyped["result"])
        XCTAssertEqual(mistyped["error"]?["data"]?["code"], JSONValue.string("invalidArguments"))

        try send(["jsonrpc": "2.0", "id": 5, "method": "shutdown"])
        let shutdown = try XCTUnwrap(try next())
        XCTAssertEqual(shutdown["id"], JSONValue.int(5))
        XCTAssertEqual(shutdown["result"], JSONValue.null)

        try send(["jsonrpc": "2.0", "method": "exit"])
        input.fileHandleForWriting.closeFile()
        let status = waitForExit()
        XCTAssertEqual(status, 0)

        // Nothing but frames reached stdout, and diagnostics stayed on stderr.
        XCTAssertNil(try reader.next(from: output.fileHandleForReading))
        let diagnostics = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        XCTAssertFalse(diagnostics.contains("Content-Length"))
        XCTAssertFalse(diagnostics.contains("\"jsonrpc\""))
    }

    /// A real long-running task answers at once, can be cancelled by the request
    /// id, and reports the cancellation as `task.failed` with `-32800`.
    func testCancellationOfARealTask() throws {
        let bin = fixture.appendingPathComponent("bin", isDirectory: true)
        try TestFixture.write(
            """
            #!/bin/sh
            case "$1" in
              branch) printf 'origin/1.0-release\\n' ;;
              remote) printf 'https://example.invalid/StateUI.git\\n' ;;
              clone) exec sleep 30 ;;
              *) exit 0 ;;
            esac
            """,
            to: bin.appendingPathComponent("git")
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("git").path
        )
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        try start(environment: environment)

        try send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": ToolingVersion.protocolVersion],
        ])
        _ = try XCTUnwrap(try next())

        try send([
            "jsonrpc": "2.0", "id": 7, "method": "group/create",
            "params": [
                "name": "Group", "releases": ["1.0"],
                "destination": fixture.appendingPathComponent("Group").path,
                "checkout": fixture.path,
            ],
        ])
        let started = try XCTUnwrap(try next())
        XCTAssertEqual(started["id"], JSONValue.int(7))
        XCTAssertEqual(started["result"]?["status"], JSONValue.string("started"))
        let taskID = try XCTUnwrap(started["result"]?["taskId"]?.stringValue)

        try send([
            "jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": 7],
        ])
        var cancelled = false
        for _ in 0..<20 {
            guard let notification = try next() else { break }
            if notification["method"] == JSONValue.string("task.failed"),
               notification["params"]?["taskId"]?.stringValue == taskID,
               notification["params"]?["error"]?["code"] == JSONValue.int(-32800) {
                cancelled = true
                break
            }
        }
        XCTAssertTrue(cancelled)

        try send(["jsonrpc": "2.0", "method": "exit"])
        input.fileHandleForWriting.closeFile()
        XCTAssertEqual(waitForExit(), 0)
    }

    // MARK: - Process

    private func start(environment: [String: String]? = nil) throws {
        let executable = try Self.executable()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["rpc", "--stdio"]
        process.currentDirectoryURL = fixture
        if let environment { process.environment = environment }
        input = Pipe()
        output = Pipe()
        errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        self.process = process
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try sendRaw(data)
    }

    private func sendRaw(_ body: Data) throws {
        input.fileHandleForWriting.write(RPCFraming.frame(body))
    }

    private func next(timeout: TimeInterval = 10) throws -> JSONValue? {
        var descriptor = pollfd(
            fd: output.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN), revents: 0
        )
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        guard let body = try reader.next(from: output.fileHandleForReading) else { return nil }
        return try JSON.decoder().decode(JSONValue.self, from: body)
    }

    private func waitForExit(timeout: TimeInterval = 15) -> Int32 {
        guard let process else { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Build

    /// The package under test is `tools/stateui/`. A `swift build` before
    /// `swift test` leaves the executable beside the test bundle; if it is
    /// missing, build it once so the test is self-contained.
    private static func executable() throws -> URL {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StateUIToolingTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // tools/stateui
        for configuration in ["debug", "release"] {
            let candidate = package.appendingPathComponent(".build/\(configuration)/stateui")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--package-path", package.path, "--product", "stateui"]
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.nullDevice
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            throw ToolingError.executableNotFound("stateui was not built from \(package.path)")
        }
        for configuration in ["debug", "release"] {
            let candidate = package.appendingPathComponent(".build/\(configuration)/stateui")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw ToolingError.executableNotFound("stateui was not built from \(package.path)")
    }
}
#endif
