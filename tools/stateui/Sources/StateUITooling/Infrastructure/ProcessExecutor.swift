// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One chunk of a running process's output.
public struct ProcessOutput: Sendable {
    public enum Stream: String, Sendable {
        case stdout
        case stderr
    }

    public let stream: Stream
    public let text: String

    public init(stream: Stream, text: String) {
        self.stream = stream
        self.text = text
    }
}

/// What a finished process exited with, printed and how long it took.
public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let duration: TimeInterval

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "", duration: TimeInterval = 0) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.duration = duration
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// Runs a planned process and reports its output as it arrives.
public protocol ProcessExecuting: Sendable {
    func execute(
        _ invocation: ProcessInvocation,
        onOutput: (@Sendable (ProcessOutput) -> Void)?
    ) async throws -> ProcessResult
}

public extension ProcessExecuting {
    func execute(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        try await execute(invocation, onOutput: nil)
    }
}

/// Bytes read from a pipe, decoded only as far as a character is complete: the bytes
/// that begin a character whose rest has not arrived are carried to the chunk that completes it.
struct UTF8ChunkDecoder: Sendable {
    private var carried = Data()

    /// The text the chunk completes, holding back whatever stands mid-character.
    /// What is decoded and what is carried are taken as prefixes and suffixes, never by
    /// counting into a slice: a slice carries its own indices, and a count is not one.
    mutating func decode(_ data: Data) -> String {
        carried.append(data)
        let held = Self.partialTail(in: carried)
        let whole = carried.count - held
        let bytes = Data(carried.prefix(whole))
        let text = bytes.isEmpty
            ? ""
            : String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        // A fresh Data holds the waiting bytes, so its indices begin again at zero.
        carried = held == 0 ? Data() : Data(carried.suffix(held))
        return text
    }

    /// How many trailing bytes begin a character whose continuation has not arrived.
    /// A UTF-8 character is at most four bytes, so only the last three can be split.
    static func partialTail(in data: Data) -> Int {
        var offset = 0
        for byte in data.suffix(3).reversed() {
            offset += 1
            if byte < 0x80 { return 0 }            // ASCII: the stream is whole at this byte
            if byte >= 0xC2 {                      // A lead byte, whose character may be unfinished
                let whole = byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                return offset < whole ? offset : 0
            }
            // A continuation byte: look back for the lead that began it.
        }
        return 0                                   // No lead stands here: no character waits for more
    }
}

/// Output captured while a process runs, readable from any of its pipes' threads.
private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var out = ""
    private var err = ""

    func append(_ text: String, stream: ProcessOutput.Stream) {
        lock.lock()
        if stream == .stdout { out += text } else { err += text }
        lock.unlock()
    }

    func texts() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (out, err)
    }
}

/// A process that can be terminated from another thread when its task is cancelled.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func adopt(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        #if !os(Windows)
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
        #endif
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Runs processes on this machine.
public struct RealProcessExecutor: ProcessExecuting {
    public init() {}

    public func execute(
        _ invocation: ProcessInvocation,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ProcessResult {
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = invocation.executable
                process.arguments = invocation.arguments
                process.currentDirectoryURL = invocation.workingDirectory
                process.environment = Environment.current.merging(
                    invocation.environment, unsetting: invocation.unsetEnvironment
                )

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                let captured = CapturedOutput()

                @Sendable func read(_ handle: FileHandle, stream: ProcessOutput.Stream) {
                    var decoder = UTF8ChunkDecoder()
                    while true {
                        let data: Data
                        do {
                            data = try handle.read(upToCount: 4096) ?? Data()
                        } catch {
                            return
                        }
                        if data.isEmpty { return }
                        let text = decoder.decode(data)
                        if text.isEmpty { continue }
                        onOutput?(ProcessOutput(stream: stream, text: text))
                        if invocation.captureOutput {
                            captured.append(text, stream: stream)
                        }
                    }
                }

                // The pipes are read before the child runs, so the output it writes in
                // its first moments is not lost when it closes them as it exits.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    read(stdout.fileHandleForReading, stream: .stdout)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    read(stderr.fileHandleForReading, stream: .stderr)
                    group.leave()
                }

                // Nothing started, so closing the ends the process would have written
                // to leaves the readers to find their end of file.
                func closeWriteEnds() {
                    stdout.fileHandleForWriting.closeFile()
                    stderr.fileHandleForWriting.closeFile()
                }

                if !FileManager.default.fileExists(atPath: invocation.executable.path) {
                    closeWriteEnds()
                    continuation.resume(throwing: ToolingError.executableNotFound(invocation.executable.path))
                    return
                }
                do {
                    try process.run()
                } catch {
                    closeWriteEnds()
                    if (error as NSError).domain == NSCocoaErrorDomain,
                       (error as NSError).code == NSFileNoSuchFileError {
                        continuation.resume(throwing: ToolingError.executableNotFound(invocation.executable.path))
                    } else {
                        continuation.resume(throwing: ToolingError(
                            code: "processNotStarted",
                            message: "\(invocation.label) could not start: \(error.localizedDescription)",
                            context: ["executable": invocation.executable.path],
                            suggestion: "Check that the executable exists and can run on this machine."
                        ))
                    }
                    return
                }

                running.adopt(process)
                let started = Date()

                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.wait()
                    let (out, err) = captured.texts()

                    if running.isCancelled {
                        continuation.resume(throwing: ToolingError.operationCancelled(
                            "\(invocation.label) was cancelled."
                        ))
                    } else {
                        continuation.resume(returning: ProcessResult(
                            exitCode: process.terminationStatus,
                            standardOutput: out,
                            standardError: err,
                            duration: Date().timeIntervalSince(started)
                        ))
                    }
                }
            }
        } onCancel: {
            running.cancel()
        }
    }
}

/// A deterministic executor for tests: answers planned invocations with
/// recorded results and output.
public actor ScriptedProcessExecutor: ProcessExecuting {
    public struct Answer: Sendable {
        public let result: ProcessResult
        public let output: [ProcessOutput]

        public init(result: ProcessResult, output: [ProcessOutput] = []) {
            self.result = result
            self.output = output
        }
    }

    private var answers: [String: Answer]
    private var fallback: Answer
    public private(set) var invocations: [ProcessInvocation] = []

    public init(answers: [String: Answer] = [:], fallback: Answer = Answer(result: ProcessResult(exitCode: 0))) {
        self.answers = answers
        self.fallback = fallback
    }

    public func execute(
        _ invocation: ProcessInvocation,
        onOutput: (@Sendable (ProcessOutput) -> Void)?
    ) async throws -> ProcessResult {
        invocations.append(invocation)
        let answer = answers[invocation.label] ?? fallback
        for output in answer.output { onOutput?(output) }
        return answer.result
    }

    public func recorded() -> [ProcessInvocation] { invocations }
}
