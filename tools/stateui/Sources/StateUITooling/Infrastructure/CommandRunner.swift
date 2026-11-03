// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Captures a native tool's output for discovery. Never used for a build that
/// a user watches; that goes through the process executor's streaming path.
public struct CommandRunner: Sendable {
    public let executor: any ProcessExecuting
    public let environment: Environment

    public init(executor: any ProcessExecuting, environment: Environment = .current) {
        self.executor = executor
        self.environment = environment
    }

    public func output(
        _ executable: URL, _ arguments: [String], workingDirectory: URL = FileManager.default.currentDirectoryPath.url,
        environment overrides: [String: String] = [:], label: String = "probe"
    ) async -> String? {
        let invocation = ProcessInvocation(
            executable: executable,
            arguments: arguments,
            environment: overrides,
            workingDirectory: workingDirectory,
            label: label,
            captureOutput: true
        )
        guard let result = try? await executor.execute(invocation), result.exitCode == 0 else { return nil }
        return result.standardOutput + result.standardError
    }

    public func result(
        _ executable: URL, _ arguments: [String], workingDirectory: URL = FileManager.default.currentDirectoryPath.url,
        environment overrides: [String: String] = [:], label: String = "probe"
    ) async -> ProcessResult? {
        let invocation = ProcessInvocation(
            executable: executable,
            arguments: arguments,
            environment: overrides,
            workingDirectory: workingDirectory,
            label: label,
            captureOutput: true
        )
        return try? await executor.execute(invocation)
    }

    public func which(_ name: String) -> URL? {
        FileSystem.findExecutable(name, environment: environment)
    }
}

extension String {
    public var url: URL { URL(fileURLWithPath: self) }
}

public struct ProcessFailure: Error, Sendable, CustomStringConvertible {
    public let label: String
    public let exitCode: Int32
    public let output: String

    public init(label: String, exitCode: Int32, output: String) {
        self.label = label
        self.exitCode = exitCode
        self.output = output
    }

    public var description: String { "\(label) exited \(exitCode): \(output.suffix(2000))" }
}
