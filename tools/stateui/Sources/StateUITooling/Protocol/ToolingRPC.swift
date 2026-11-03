// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The methods the CLI and the editor both speak, over JSON-RPC 2.0.
public struct ToolingRPC: RPCHandling {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    /// The operations an editor starts and then follows: a plan alone is
    /// immediate, but running one can take minutes and must be cancellable.
    public func isLongRunning(method: String, params: JSONValue?) -> Bool {
        guard params?["dryRun"]?.boolValue != true else { return false }
        switch method {
        case "build", "test", "run", "deploy", "debug/prepare", "size/budgets",
             "lsp/configure", "group/create":
            return true
        default:
            return false
        }
    }

    public func handle(
        method: String, params: JSONValue?, context: RPCContext
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        if context.isCancelled { throw ToolingError.operationCancelled() }
        switch method {
        case "initialize": return try initialize(params)
        case "shutdown": return .null
        case "version": return .object([
            "name": .string("stateui"), "version": .string(ToolingVersion.version),
            "protocolVersion": .int(ToolingVersion.protocolVersion),
        ])
        case "doctor": return try await doctor(params)
        case "project": return try JSONValue(tooling.project(explicit: projectURL(params)))
        case "apps": return try JSONValue(tooling.project(explicit: projectURL(params)).applications)
        case "hosts": return try await hosts(params)
        case "devices": return try await devices(params)
        case "browsers": return try await browsers(params)
        case "config/get": return try configGet(params)
        case "config/set": return try configSet(params)
        case "build": return try await build(params)
        case "test": return try await test(params)
        case "run": return try await run(params)
        case "deploy": return try await deploy(params)
        case "size/budgets": return try await sizeBudgets(params)
        case "debug/plan": return try await debugPlan(params)
        case "debug/prepare": return try await debugPrepare(params)
        case "web/stop": return try webStop(params)
        case "lsp/environment": return try await lspEnvironment(params)
        case "lsp/configure": return try await lspConfigure(params)
        case "lsp/clean": return try await lspClean(params)
        case "new": return try newApplication(params)
        case "group/releases": return try await groupReleases(params)
        case "group/create": return try await groupCreate(params)
        default:
            throw ToolingError.protocolError("Method \(method) is not supported.", context: ["method": method])
        }
    }

    // MARK: - Discovery

    private func initialize(_ params: JSONValue?) throws -> JSONValue {
        if let requested = params?["protocolVersion"]?.intValue,
           requested != ToolingVersion.protocolVersion {
            throw ToolingError(
                code: "protocolVersionMismatch",
                message: "The client speaks protocol \(requested); this server speaks \(ToolingVersion.protocolVersion).",
                context: ["client": "\(requested)", "server": "\(ToolingVersion.protocolVersion)"],
                suggestion: "Update stateui or the editor extension."
            )
        }
        let project = try? tooling.project()
        let hosts: [JSONValue] = HostID.allCases.map { host in
            .object([
                "id": .string(host.rawValue),
                "label": .string(host.label),
                "platforms": .array(host.developmentPlatforms.map(\.rawValue).sorted().map(JSONValue.string)),
            ])
        }
        return .object([
            "serverInfo": .object([
                "name": .string("stateui"),
                "version": .string(ToolingVersion.version),
                "protocolVersion": .int(ToolingVersion.protocolVersion),
            ]),
            "capabilities": .object([
                "build": .bool(true), "test": .bool(true), "run": .bool(true),
                "deploy": .bool(true), "debug": .bool(true), "devices": .bool(true),
                "browsers": .bool(true), "lsp": .bool(true), "cancellation": .bool(true),
                "size": .bool(true), "scaffold": .bool(true), "groups": .bool(true),
                "stopServed": .bool(true),
            ]),
            "hosts": .array(hosts),
            "applications": .array((project?.applications.map(\.name) ?? []).map(JSONValue.string)),
        ])
    }

    private func doctor(_ params: JSONValue?) async throws -> JSONValue {
        let hosts = hostList(params)
        return try JSONValue(await tooling.toolchainService.report(hosts: hosts))
    }

    private func hosts(_ params: JSONValue?) async throws -> JSONValue {
        let project = try tooling.project(explicit: projectURL(params))
        let config = try tooling.loadConfiguration(project)
        let context = ProjectContext(
            project: project, application: nil, host: nil, configuration: .debug,
            config: config, environment: tooling.environment, platform: tooling.platform
        )
        let availability = await tooling.registry.availability(context)
        return .array(availability.map { item in
            let descriptor = HostDescriptor(id: item.host)
            return .object([
                "id": .string(descriptor.id.rawValue),
                "label": .string(descriptor.label),
                "detail": .string(descriptor.detail),
                "platforms": .array(descriptor.platforms.map(\.rawValue).map(JSONValue.string)),
                "capabilities": .object([
                    "build": .bool(descriptor.capabilities.build),
                    "run": .bool(descriptor.capabilities.run),
                    "test": .bool(descriptor.capabilities.test),
                    "deploy": .bool(descriptor.capabilities.deploy),
                    "debug": .bool(descriptor.capabilities.debug),
                    "devices": .bool(descriptor.capabilities.devices),
                    "browsers": .bool(descriptor.capabilities.browsers),
                    "lsp": .bool(descriptor.capabilities.lsp),
                ]),
                "indexDirectory": .string(descriptor.indexDirectory),
                "status": .string(item.status.rawValue),
                "reason": .string(item.reason ?? ""),
                "toolchainReady": .bool(item.toolchainReady),
                "deviceAvailable": .bool(item.deviceAvailable),
            ])
        })
    }

    private func devices(_ params: JSONValue?) async throws -> JSONValue {
        guard let raw = params?["host"]?.stringValue ?? params?["hostId"]?.stringValue,
              let host = HostID(parsing: raw) else {
            throw ToolingError.invalidArguments("devices needs a host.", suggestion: "Pass host: \"android\" or \"uikit\".")
        }
        let workspace = try tooling.resolve(project: projectURL(params), host: host)
        return try JSONValue(try await tooling.driver(for: host).devices(workspace.context))
    }

    private func browsers(_ params: JSONValue?) async throws -> JSONValue {
        let workspace = try tooling.resolve(project: projectURL(params), host: .web)
        return try JSONValue(try await tooling.driver(for: .web).browsers(workspace.context))
    }

    // MARK: - Configuration

    private func configGet(_ params: JSONValue?) throws -> JSONValue {
        let project = try tooling.project(explicit: projectURL(params))
        return try JSONValue(try tooling.loadConfiguration(project))
    }

    private func configSet(_ params: JSONValue?) throws -> JSONValue {
        let project = try tooling.project(explicit: projectURL(params))
        // One owner decides what a selection means: the same service the CLI uses, so a
        // name that stands nowhere is refused in both directions.
        try ProjectService(tooling: tooling).select(
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            application: params?["application"]?.stringValue,
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)),
            device: params?["device"]?.stringValue,
            deviceHost: params?["deviceHost"]?.stringValue.flatMap(HostID.init(parsing:)),
            browser: params?["browser"]?.stringValue,
            project: projectURL(params)
        )
        return try JSONValue(try tooling.loadConfiguration(project))
    }

    // MARK: - The page a Web run left serving

    /// Stops the detached server a Web run started, reading the process from the page's
    /// own facts file. A task no longer holds it, so cancellation alone cannot free the port.
    private func webStop(_ params: JSONValue?) throws -> JSONValue {
        let page = try WebServerService(tooling: tooling).stop(
            project: projectURL(params), application: params?["application"]?.stringValue
        )
        return .object([
            "stopped": .bool(true),
            "url": .string(page.url),
            "port": .int(page.port),
            "pid": .int(Int(page.pid)),
        ])
    }

    // MARK: - Build, test, run, deploy, debug

    private func build(_ params: JSONValue?) async throws -> JSONValue {
        let request = BuildRequest(
            application: params?["application"]?.stringValue,
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)) ?? .debug,
            device: params?["device"]?.stringValue,
            browser: params?["browser"]?.stringValue,
            architecture: params?["architecture"]?.stringValue,
            dryRun: params?["dryRun"]?.boolValue ?? false,
            extraArguments: params?["extraArguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
        if request.dryRun {
            let (_, plan) = try await BuildService(tooling: tooling).plan(request, project: projectURL(params))
            return try JSONValue(plan)
        }
        return try JSONValue(try await BuildService(tooling: tooling).run(request, project: projectURL(params)))
    }

    private func test(_ params: JSONValue?) async throws -> JSONValue {
        let request = TestRequest(
            application: params?["application"]?.stringValue,
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)) ?? .debug,
            device: params?["device"]?.stringValue,
            filter: params?["filter"]?.stringValue,
            suite: params?["suite"]?.stringValue,
            browser: params?["inBrowser"]?.boolValue ?? false,
            buildOnly: params?["buildOnly"]?.boolValue ?? false,
            architecture: params?["architecture"]?.stringValue,
            updateExports: params?["updateExports"]?.boolValue ?? false,
            staleOnly: params?["staleOnly"]?.boolValue ?? false,
            dryRun: params?["dryRun"]?.boolValue ?? false
        )
        if request.dryRun {
            let (_, plan) = try await TestService(tooling: tooling).plan(request, project: projectURL(params))
            return try JSONValue(plan)
        }
        return try JSONValue(try await TestService(tooling: tooling).run(request, project: projectURL(params)))
    }

    private func run(_ params: JSONValue?) async throws -> JSONValue {
        let request = RunRequest(
            application: params?["application"]?.stringValue,
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)) ?? .debug,
            device: params?["device"]?.stringValue,
            browser: params?["browser"]?.stringValue,
            port: params?["port"]?.intValue,
            dryRun: params?["dryRun"]?.boolValue ?? false,
            detach: params?["detach"]?.boolValue ?? false,
            prepareDebugger: params?["prepare"]?.boolValue ?? false,
            noBuild: params?["noBuild"]?.boolValue ?? false
        )
        if request.dryRun {
            let (_, build, plan) = try await RunService(tooling: tooling).plan(request, project: projectURL(params))
            return try JSONValue([
                "build": try build.map { try JSONValue($0) } ?? .null,
                "run": try JSONValue(plan),
            ])
        }
        return try JSONValue(try await RunService(tooling: tooling).run(request, project: projectURL(params)))
    }

    private func deploy(_ params: JSONValue?) async throws -> JSONValue {
        let destination = params?["destination"]?.stringValue.map { FileSystem.expand($0) }
        let request = DeployRequest(
            application: params?["application"]?.stringValue,
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)) ?? .release,
            device: params?["device"]?.stringValue,
            browser: params?["browser"]?.stringValue,
            architecture: params?["architecture"]?.stringValue,
            destination: destination,
            dryRun: params?["dryRun"]?.boolValue ?? false
        )
        if request.dryRun {
            let (_, plan) = try await DeployService(tooling: tooling).plan(request, project: projectURL(params))
            return try JSONValue(plan)
        }
        return try JSONValue(try await DeployService(tooling: tooling).run(request, project: projectURL(params)))
    }

    /// Each application's Web module, built for release and gzipped, weighed against
    /// the budget the repository records. The report says whether any stands over.
    private func sizeBudgets(_ params: JSONValue?) async throws -> JSONValue {
        let host = params?["host"]?.stringValue.flatMap(HostID.init(parsing:)) ?? .web
        let configuration = params?["configuration"]?.stringValue
            .flatMap(BuildConfiguration.init(parsing:)) ?? .release
        let report = try await SizeService(tooling: tooling).budgets(
            host: host, configuration: configuration, project: projectURL(params)
        )
        return try JSONValue(report)
    }

    private func debugPlan(_ params: JSONValue?) async throws -> JSONValue {
        let request = debugRequest(params)
        let (_, plan) = try await DebugService(tooling: tooling).plan(request, project: projectURL(params))
        return try JSONValue(plan)
    }

    private func debugPrepare(_ params: JSONValue?) async throws -> JSONValue {
        let request = debugRequest(params)
        return try JSONValue(try await DebugService(tooling: tooling).prepare(request, project: projectURL(params)))
    }

    private func debugRequest(_ params: JSONValue?) -> DebugRequest {
        DebugRequest(
            application: params?["application"]?.stringValue,
            host: params?["host"]?.stringValue.flatMap(HostID.init(parsing:)),
            configuration: params?["configuration"]?.stringValue.flatMap(BuildConfiguration.init(parsing:)) ?? .debug,
            device: params?["device"]?.stringValue,
            browser: params?["browser"]?.stringValue,
            prepare: params?["prepare"]?.boolValue ?? false,
            dryRun: params?["dryRun"]?.boolValue ?? false
        )
    }

    private func lspEnvironment(_ params: JSONValue?) async throws -> JSONValue {
        let host = params?["host"]?.stringValue.flatMap(HostID.init(parsing:))
        let environment = try await LSPService(tooling: tooling).environment(
            host: host, project: projectURL(params)
        )
        return try JSONValue(environment)
    }

    /// The folder's editor settings, and the index build that fills the host's index
    /// directory. `dryRun` says what indexing would run without building it.
    private func lspConfigure(_ params: JSONValue?) async throws -> JSONValue {
        let host = params?["host"]?.stringValue.flatMap(HostID.init(parsing:))
        let outcome = try await LSPService(tooling: tooling).configure(
            host: host, project: projectURL(params), dryRun: params?["dryRun"]?.boolValue ?? false
        )
        return try JSONValue(outcome)
    }

    /// Remove an index - one host's, or every host's - so the host indexes again.
    private func lspClean(_ params: JSONValue?) async throws -> JSONValue {
        let host = params?["host"]?.stringValue.flatMap(HostID.init(parsing:))
        let result = try await LSPService(tooling: tooling).clean(
            host: host, all: params?["all"]?.boolValue ?? false,
            project: projectURL(params), dryRun: params?["dryRun"]?.boolValue ?? false
        )
        return try JSONValue(result)
    }

    private func groupReleases(_ params: JSONValue?) async throws -> JSONValue {
        let releases = try await GroupService(tooling: tooling).releases(
            checkout: params?["checkout"]?.stringValue.map { FileSystem.expand($0) },
            project: projectURL(params),
            floor: params?["minimum"]?.stringValue
        )
        return .array(releases.map(JSONValue.string))
    }

    private func groupCreate(_ params: JSONValue?) async throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw ToolingError.invalidArguments("group/create needs a name.", suggestion: "Pass name: \"MyProject\".")
        }
        let releases = params?["releases"]?.arrayValue?.compactMap(\.stringValue)
        let outcome = try await GroupService(tooling: tooling).run(
            name: name, releases: releases?.isEmpty == true ? nil : releases,
            at: params?["destination"]?.stringValue.map { FileSystem.expand($0) },
            checkout: params?["checkout"]?.stringValue.map { FileSystem.expand($0) },
            project: projectURL(params),
            floor: params?["minimum"]?.stringValue,
            dryRun: params?["dryRun"]?.boolValue ?? false
        )
        return try JSONValue(outcome)
    }

    private func newApplication(_ params: JSONValue?) throws -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            throw ToolingError.invalidArguments("new needs a name.")
        }
        let project = try tooling.project(explicit: projectURL(params))
        let appsDirectory = params?["appsDirectory"]?.stringValue.map { FileSystem.expand($0) }
        let directory = try ScaffoldService().create(
            name: name, appsDirectory: appsDirectory, project: project
        )
        return try JSONValue(["application": name, "directory": directory.path])
    }

    // MARK: - Params

    private func projectURL(_ params: JSONValue?) -> URL? {
        params?["project"]?.stringValue.map { FileSystem.expand($0) }
    }

    private func hostList(_ params: JSONValue?) -> [HostID]? {
        if let list = params?["hosts"]?.arrayValue {
            return list.compactMap { $0.stringValue.flatMap(HostID.init(parsing:)) }
        }
        if let host = params?["host"]?.stringValue.flatMap(HostID.init(parsing:)) {
            return [host]
        }
        return nil
    }
}
