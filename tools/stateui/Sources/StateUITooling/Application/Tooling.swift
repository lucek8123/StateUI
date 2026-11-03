// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where a running request's progress goes. The RPC server binds this for the
/// duration of a task, so a plan's streamed output becomes `task.progress`
/// notifications instead of interleaving with stdout.
public enum ToolingProgress {
    @TaskLocal public static var handler: (@Sendable (String) -> Void)?
}

/// A project resolved against the configuration and a request: the one place
/// the CLI and the protocol share.
public struct ResolvedWorkspace: Sendable {
    public let project: ProjectInfo
    public let config: StateUIConfiguration
    public let application: Application?
    public let host: HostID?
    public let configuration: BuildConfiguration
    public let context: ProjectContext

    public init(
        project: ProjectInfo, config: StateUIConfiguration, application: Application?,
        host: HostID?, configuration: BuildConfiguration, context: ProjectContext
    ) {
        self.project = project
        self.config = config
        self.application = application
        self.host = host
        self.configuration = configuration
        self.context = context
    }
}

/// The tool's services, wired once and shared by the command line and the
/// JSON-RPC server.
public struct Tooling: Sendable {
    public let executor: any ProcessExecuting
    public let environment: Environment
    public let platform: Platform
    public let logger: Logger
    public let registry: HostRegistry
    public let discovery: ProjectDiscovery
    public let configurationService: ConfigurationService
    public let toolchainService: ToolchainService
    public let planExecutor: PlanExecutor
    public let cwd: URL

    public init(
        executor: any ProcessExecuting = RealProcessExecutor(),
        environment: Environment = .current,
        platform: Platform = .current,
        logger: Logger = Logger(),
        cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.executor = executor
        self.environment = environment
        self.platform = platform
        self.logger = logger
        self.discovery = ProjectDiscovery()
        self.configurationService = ConfigurationService()
        self.toolchainService = ToolchainService(
            executor: executor, environment: environment, platform: platform
        )
        self.registry = HostRegistry.standard(
            executor: executor, environment: environment, platform: platform
        )
        self.planExecutor = PlanExecutor(executor: executor, logger: logger)
        self.cwd = cwd
    }

    public func project(explicit: URL? = nil) throws -> ProjectInfo {
        try discovery.discover(explicit: explicit, cwd: cwd)
    }

    public func loadConfiguration(_ project: ProjectInfo) throws -> StateUIConfiguration {
        try configurationService.load(root: project.root)
    }

    /// Resolves an application, host and configuration from the request and the
    /// project's stored selections.
    public func resolve(
        project explicitProject: URL? = nil,
        application requestedApplication: String? = nil,
        host requestedHost: HostID? = nil,
        configuration requestedConfiguration: BuildConfiguration? = nil
    ) throws -> ResolvedWorkspace {
        let project = try project(explicit: explicitProject)
        let config = try loadConfiguration(project)

        let applicationName = requestedApplication
            ?? config.defaultApplication
            ?? (project.applications.count == 1 ? project.applications[0].name : nil)
        let application: Application?
        if let applicationName {
            guard let found = project.application(named: applicationName) else {
                throw ToolingError.applicationNotFound(
                    "\(project.root.path) has no application named \(applicationName).",
                    context: ["applications": project.applications.map(\.name).joined(separator: ", ")],
                    suggestion: "Run `stateui apps` to list them."
                )
            }
            application = found
        } else {
            application = nil
        }

        let host = requestedHost
            ?? config.defaultHost
            ?? application.flatMap { $0.availableHosts.count == 1 ? $0.availableHosts[0] : nil }
        let configuration = requestedConfiguration ?? config.configuration ?? .debug

        let context = ProjectContext(
            project: project, application: application, host: host,
            configuration: configuration, config: config,
            environment: environment, platform: platform
        )
        return ResolvedWorkspace(
            project: project, config: config, application: application,
            host: host, configuration: configuration, context: context
        )
    }

    public func driver(for host: HostID) throws -> any HostDriver {
        try registry.driver(for: host)
    }

    /// Streams a build's output to stderr while the result stays on stdout. A
    /// request that bound a progress handler sends it there instead: stdout is
    /// reserved for protocol frames.
    public func outputHandler() -> @Sendable (ProcessOutput) -> Void {
        if let handler = ToolingProgress.handler {
            return { output in handler(output.text) }
        }
        return { output in
            FileHandle.standardError.write(Data(output.text.utf8))
        }
    }

    public func execute(
        steps: [ProcessInvocation], actions: [FileAction] = [], postSteps: [ProcessInvocation] = [],
        dryRun: Bool = false, detached: Bool = false, logFile: URL? = nil,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        try await planExecutor.execute(
            steps: steps, actions: actions, postSteps: postSteps,
            dryRun: dryRun, detached: detached, logFile: logFile,
            onOutput: onOutput ?? outputHandler()
        )
    }

    public func execute(
        _ plan: BuildPlan, dryRun: Bool = false,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        var outcome = try await planExecutor.execute(plan, dryRun: dryRun, onOutput: onOutput ?? outputHandler())
        if outcome.status == .succeeded || outcome.status == .planned {
            outcome = ExecutionOutcome(
                status: outcome.status, duration: outcome.duration, outputs: plan.outputs,
                factsFile: outcome.factsFile, url: outcome.url, notes: outcome.notes + plan.notes
            )
        }
        return outcome
    }

    /// The default deployment folder: `artifacts/<application>/<host>`, with an
    /// architecture below a WinUI head.
    public func defaultDeploymentDestination(
        project: ProjectInfo, application: Application, host: HostID, architecture: String? = nil
    ) -> URL {
        var destination = project.root
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(application.name, isDirectory: true)
            .appendingPathComponent(host.productSuffix, isDirectory: true)
        if host == .winUI {
            destination.appendPathComponent(architecture ?? (platform.architecture == .arm64 ? "arm64" : "x64"))
        }
        return destination
    }
}
