// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

final class ProcessTests: XCTestCase {
    private var shell: URL { URL(fileURLWithPath: TestFixture.shell) }

    private static func invocation(
        command: String, capture: Bool = true, label: String = "test"
    ) -> ProcessInvocation {
        #if os(Windows)
        let arguments = ["/c", command]
        #else
        let arguments = ["-c", command]
        #endif
        return ProcessInvocation(
            executable: URL(fileURLWithPath: TestFixture.shell), arguments: arguments,
            workingDirectory: FileManager.default.temporaryDirectory,
            label: label, captureOutput: capture
        )
    }

    private func invocation(
        command: String, capture: Bool = true, label: String = "test"
    ) -> ProcessInvocation {
        Self.invocation(command: command, capture: capture, label: label)
    }

    func testCapturesStandardOutputAndStatus() async throws {
        #if os(Windows)
        let command = "<nul set /p=hello& <nul set /p=oops>&2& exit /b 0"
        #else
        let command = "printf 'hello'; printf 'oops' >&2; exit 0"
        #endif
        let result = try await RealProcessExecutor().execute(
            invocation(command: command)
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "hello")
        XCTAssertEqual(result.standardError, "oops")
    }

    func testReportsANonZeroExitWithoutThrowing() async throws {
        #if os(Windows)
        let command = "<nul set /p=no>&2& exit /b 7"
        #else
        let command = "printf 'no' >&2; exit 7"
        #endif
        let result = try await RealProcessExecutor().execute(
            invocation(command: command)
        )
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.standardError, "no")
    }

    func testStreamsOutputWhileCapturingIt() async throws {
        let box = OutputBox()
        #if os(Windows)
        let command = "<nul set /p=one& <nul set /p=two>&2& exit /b 0"
        #else
        let command = "printf 'one'; printf 'two' >&2"
        #endif
        let result = try await RealProcessExecutor().execute(
            invocation(command: command)
        ) { output in
            box.append(output)
        }
        XCTAssertEqual(result.exitCode, 0)
        // Each stream is streamed as it is captured, so a caller sees the same text
        // the result holds, and never the two pipes' bytes tangled together.
        XCTAssertEqual(box.text(for: .stdout), result.standardOutput)
        XCTAssertEqual(box.text(for: .stderr), result.standardError)
        XCTAssertTrue(box.text(for: .stdout).contains("one"))
        XCTAssertTrue(box.text(for: .stderr).contains("two"))
    }

    func testMissingExecutableIsAStructuredError() async {
        let invocation = ProcessInvocation(
            executable: FileManager.default.temporaryDirectory.appendingPathComponent("definitely-not-here"),
            arguments: [], workingDirectory: FileManager.default.temporaryDirectory, label: "missing"
        )
        do {
            _ = try await RealProcessExecutor().execute(invocation)
            XCTFail("Expected the executor to throw.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "executableNotFound")
        }
    }

    func testCancellationTerminatesTheProcess() async throws {
        #if os(Windows)
        let command = "ping -n 30 127.0.0.1 >nul"
        #else
        let command = "sleep 30"
        #endif
        let task = Task {
            try await RealProcessExecutor().execute(
                Self.invocation(command: command, label: "sleep")
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "operationCancelled")
        }
    }

    func testScriptedExecutorRecordsInvocations() async throws {
        let executor = ScriptedProcessExecutor(
            answers: ["echo": .init(result: ProcessResult(exitCode: 0, standardOutput: "ok"))]
        )
        let result = try await executor.execute(invocation(command: "echo ok", label: "echo"))
        XCTAssertEqual(result.standardOutput, "ok")
        let recorded = await executor.recorded()
        XCTAssertEqual(recorded.map(\.label), ["echo"])
    }

    func testCommandRunnerTreatsNonZeroAsMissingOutput() async {
        let executor = ScriptedProcessExecutor(
            fallback: .init(result: ProcessResult(exitCode: 1, standardError: "no"))
        )
        let runner = CommandRunner(executor: executor)
        #if os(Windows)
        let output = await runner.output(shell, ["/c", "exit /b 1"], label: "probe")
        #else
        let output = await runner.output(shell, ["-c", "false"], label: "probe")
        #endif
        XCTAssertNil(output)
    }

    func testADecoderHoldsACharacterUntilItsBytesAreWhole() throws {
        let accent = try XCTUnwrap("café!".data(using: .utf8))
        var decoder = UTF8ChunkDecoder()
        // "é" is two bytes; its first alone stands in no character, so nothing is read yet.
        XCTAssertEqual(decoder.decode(Data([accent[3]])), "")
        XCTAssertEqual(decoder.decode(Data([accent[4], UInt8(ascii: "!")])), "é!")
        XCTAssertEqual(decoder.decode(Data()), "")
    }

    func testADecoderWeighsBytesThatStandInNoCharacter() {
        var decoder = UTF8ChunkDecoder()
        // Bytes no character can hold are read as the machine's own would read them,
        // and let go, so a stream never stalls on them.
        let text = decoder.decode(Data([0xC3, 0x28, 0x61]))
        XCTAssertTrue(text.contains("(a"))
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(decoder.decode(Data([UInt8(ascii: "b")])), "b")
    }

    /// A carried tail is kept as the decoder's own bytes, not as a slice of the chunk
    /// it was cut from: a slice keeps the indices of the buffer behind it, and counting
    /// into it as a length falls outside what it holds and traps.
    func testADecoderCarriesItsTailWithoutCountingIntoASlice() throws {
        let text = String(repeating: "naïve — 🌍 ☕ ", count: 200)
        let bytes = try XCTUnwrap(text.data(using: .utf8))
        var decoder = UTF8ChunkDecoder()
        var read = ""
        var position = 0
        // Chunks of seven bytes cut characters in half over and over, so a tail is
        // carried after nearly every one of them.
        while position < bytes.count {
            let length = min(7, bytes.count - position)
            read += decoder.decode(bytes[position..<(position + length)])
            position += length
        }
        XCTAssertEqual(read, text)
    }

    /// A process whose output crosses a pipe's chunk mid-character reads back whole:
    /// this is the path a long test run takes, where the split lands in its last lines.
    func testAProcessWhoseOutputSplitsCharactersReadsBackWhole() async throws {
        let text = String(repeating: "naïve — 🌍 ☕ café ✓ ", count: 400)
        #if os(Windows)
        let file = try TestFixture.write(
            text, to: FileManager.default.temporaryDirectory.appendingPathComponent("wide-\(UUID().uuidString).txt"))
        let result = try await RealProcessExecutor().execute(
            ProcessInvocation(
                executable: URL(fileURLWithPath: TestFixture.shell),
                arguments: ["/c", "type", file.lastPathComponent],
                workingDirectory: file.deletingLastPathComponent(), label: "wide output",
                captureOutput: true
            )
        )
        #else
        let result = try await RealProcessExecutor().execute(
            invocation(command: "printf '%s' '\(text)'", label: "wide output")
        )
        #endif
        XCTAssertEqual(result.standardOutput, text)
        XCTAssertTrue(result.succeeded)
    }
}

/// Collects streamed output from a process's pipes, one text per stream.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func append(_ output: ProcessOutput) {
        lock.lock()
        if output.stream == .stdout { out += output.text } else { err += output.text }
        lock.unlock()
    }

    func text(for stream: ProcessOutput.Stream) -> String {
        lock.lock(); defer { lock.unlock() }
        return stream == .stdout ? out : err
    }
}
