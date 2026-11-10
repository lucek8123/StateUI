// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Starts a process that outlives the command, writing its output to a log.
public struct DetachedLauncher: Sendable {
    public init() {}

    @discardableResult
    public func launch(_ invocation: ProcessInvocation, logFile: URL? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = Environment.current.merging(
            invocation.environment, unsetting: invocation.unsetEnvironment
        )
        process.standardInput = FileHandle.nullDevice

        if let logFile {
            try FileSystem.makeDirectory(logFile.deletingLastPathComponent())
            if !FileSystem.exists(logFile) {
                _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                _ = try? handle.seekToEnd()
                process.standardOutput = handle
                process.standardError = handle
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw ToolingError.executableNotFound(invocation.executable.path)
        }
        return process.processIdentifier
    }
}

/// Applies a plan: processes in order, then the file actions that lay their
/// output out. A dry run prints the plan and changes nothing.
public struct PlanExecutor: Sendable {
    public let executor: any ProcessExecuting
    public let logger: Logger
    public let launcher: DetachedLauncher

    public init(
        executor: any ProcessExecuting, logger: Logger = Logger(), launcher: DetachedLauncher = DetachedLauncher()
    ) {
        self.executor = executor
        self.logger = logger
        self.launcher = launcher
    }

    public func execute(
        steps: [ProcessInvocation], actions: [FileAction] = [], postSteps: [ProcessInvocation] = [],
        dryRun: Bool = false, detached: Bool = false, logFile: URL? = nil,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        let started = Date()

        if dryRun {
            for step in steps {
                logger.info("plan: \(step.label): \(step.displayCommand)")
                if !step.environment.isEmpty {
                    logger.info("      \(step.displayEnvironment)")
                }
            }
            for action in actions {
                logger.info("plan: \(action.summary)")
            }
            for step in postSteps {
                logger.info("plan: \(step.label): \(step.displayCommand)")
            }
            return ExecutionOutcome(status: .planned)
        }

        try await run(steps, detached: detached, logFile: logFile, onOutput: onOutput)

        for action in actions {
            try apply(action)
        }

        try await run(postSteps, detached: false, logFile: logFile, onOutput: onOutput)

        return ExecutionOutcome(
            status: detached ? .started : .succeeded,
            duration: Date().timeIntervalSince(started)
        )
    }

    public func execute(
        _ plan: BuildPlan, dryRun: Bool = false,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        try await execute(
            steps: plan.steps, actions: plan.actions, postSteps: plan.postSteps,
            dryRun: dryRun, onOutput: onOutput
        )
    }

    public func execute(
        _ plan: DeployPlan, dryRun: Bool = false,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        if let build = plan.build {
            _ = try await execute(build, dryRun: dryRun, onOutput: onOutput)
        }
        return try await execute(
            steps: plan.steps, actions: plan.actions, postSteps: plan.postSteps,
            dryRun: dryRun, onOutput: onOutput
        )
    }

    private func run(
        _ steps: [ProcessInvocation], detached: Bool, logFile: URL?,
        onOutput: (@Sendable (ProcessOutput) -> Void)?
    ) async throws {
        for step in steps {
            if detached && step.mode == .observe {
                logger.debug("skipping \(step.label): detached")
                continue
            }
            if detached && step.mode == .background {
                let pid = try launcher.launch(step, logFile: logFile)
                logger.info("started: \(step.label), process \(pid)\(logFile.map { ", log \($0.path)" } ?? "")")
                continue
            }
            if step.mode == .background {
                let pid = try launcher.launch(step, logFile: logFile)
                logger.info("started: \(step.label), process \(pid)\(logFile.map { ", log \($0.path)" } ?? "")")
                continue
            }

            logger.debug("running \(step.label): \(step.displayCommand)")
            let result: ProcessResult
            do {
                result = try await executor.execute(step, onOutput: onOutput)
            } catch let error as ToolingError {
                throw error
            } catch {
                throw error.toolingError
            }

            if !result.succeeded && !step.allowFailure {
                let output = result.standardOutput + result.standardError
                throw ToolingError(
                    code: "processFailed",
                    message: "\(step.label) exited \(result.exitCode).",
                    context: [
                        "executable": step.executable.path,
                        "arguments": step.arguments.joined(separator: " "),
                        "exitCode": "\(result.exitCode)",
                        "output": String(output.suffix(4000)),
                    ],
                    suggestion: "Read the output above, or run the printed command yourself."
                )
            }
            if !result.succeeded {
                logger.debug("\(step.label) exited \(result.exitCode), which the plan allows")
            }
        }
    }

    private func apply(_ action: FileAction) throws {
        logger.debug("applying \(action.summary)")
        switch action.kind {
        case .createDirectory:
            guard let destination = action.destination else { return }
            try FileSystem.makeDirectory(destination)
        case .remove:
            guard let destination = action.destination else { return }
            try FileSystem.remove(destination)
        case .copy:
            guard let source = action.source, let destination = action.destination else { return }
            try FileSystem.copy(source, to: destination)
        case .copyTree:
            guard let source = action.source, let destination = action.destination else { return }
            try FileSystem.copyTree(source, to: destination, excluding: Set(action.excluding))
        case .copyMatching:
            guard let source = action.source, let destination = action.destination,
                  let matching = action.matching else { return }
            try FileSystem.makeDirectory(destination)
            for child in FileSystem.children(source) where child.lastPathComponent.hasSuffix(matching) {
                try FileSystem.copy(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        case .move:
            guard let source = action.source, let destination = action.destination else { return }
            try FileSystem.makeDirectory(destination.deletingLastPathComponent())
            try FileSystem.remove(destination)
            try FileManager.default.moveItem(at: source, to: destination)
        case .write:
            guard let destination = action.destination, let contents = action.contents else { return }
            try FileSystem.write(contents, to: destination)
        case .makeExecutable:
            guard let destination = action.destination else { return }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        case .symlink:
            guard let source = action.source, let destination = action.destination else { return }
            try FileSystem.remove(destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }
}
