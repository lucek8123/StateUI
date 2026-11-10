// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Plans and executes an application's build for one host.
public struct BuildService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func plan(_ request: BuildRequest, project: URL? = nil) async throws -> (ResolvedWorkspace, BuildPlan) {
        let workspace = try tooling.resolve(
            project: project, application: request.application, host: request.host,
            configuration: request.configuration
        )
        let host = try workspace.context.requiringHost()
        let driver = try tooling.driver(for: host)
        let plan = try await driver.buildPlan(request, context: workspace.context)
        return (workspace, plan)
    }

    public func run(_ request: BuildRequest, project: URL? = nil) async throws -> ExecutionOutcome {
        let (_, plan) = try await plan(request, project: project)
        if request.dryRun {
            return try await tooling.execute(plan, dryRun: true)
        }
        return try await tooling.execute(plan)
    }
}

/// Plans and executes an application's test suites for one host.
public struct TestService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func plan(_ request: TestRequest, project: URL? = nil) async throws -> (ResolvedWorkspace, TestPlan) {
        let workspace = try tooling.resolve(
            project: project, application: request.application, host: request.host,
            configuration: request.configuration
        )
        let host = try workspace.context.requiringHost()
        // `native` and `foundation` stand on the machine, not on a host, so no
        // driver is asked for them.
        if request.suite == "native" {
            let builder = SwiftBuilder(
                runner: CommandRunner(executor: tooling.executor, environment: tooling.environment),
                environment: tooling.environment, platform: tooling.platform
            )
            let suites = try NativeTestSuites.suites(
                builder: builder, checkout: try HostSupport.checkout(workspace.context),
                platform: tooling.platform, filter: request.filter,
                environment: request.conformanceEnvironment
            )
            return (workspace, TestPlan(application: request.application, host: host, suites: suites))
        }
        if request.suite == "foundation" {
            let builder = SwiftBuilder(
                runner: CommandRunner(executor: tooling.executor, environment: tooling.environment),
                environment: tooling.environment, platform: tooling.platform
            )
            let suite = try NativeTestSuites.foundation(
                builder: builder, checkout: try HostSupport.checkout(workspace.context),
                platform: tooling.platform, environment: request.conformanceEnvironment
            )
            return (workspace, TestPlan(application: request.application, host: host, suites: [suite]))
        }
        let driver = try tooling.driver(for: host)
        let plan = try await driver.testPlan(request, context: workspace.context)
        return (workspace, plan)
    }

    public func run(
        _ request: TestRequest, project: URL? = nil,
        onOutput: (@Sendable (ProcessOutput) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
        let (workspace, plan) = try await plan(request, project: project)
        guard !plan.suites.isEmpty else {
            if request.staleOnly {
                return ExecutionOutcome(
                    status: .succeeded,
                    notes: ["Every conformance family's verdicts stand at its revision: nothing to run."]
                )
            }
            throw ToolingError.unsupportedHost(
                "\(workspace.host?.label ?? "This host") has no test suite this tool can run.",
                suggestion: "Run `stateui doctor --host \(workspace.host?.rawValue ?? "")`, or `stateui test --suite native`."
            )
        }
        if !request.buildOnly && plan.suites.contains(where: \.requiresDevice), let host = workspace.host {
            let driver = try tooling.driver(for: host)
            if try await driver.devices(workspace.context).isEmpty {
                throw ToolingError.deviceNotFound(
                    "The \(host.label) suite needs a device, and none is available.",
                    suggestion: "Start an emulator or attach a device."
                )
            }
        }

        var results: [ExecutionOutcome] = []
        for suite in plan.suites {
            var failure: Error?
            var outcome: ExecutionOutcome?
            do {
                let executed = try await tooling.execute(
                    steps: suite.steps, actions: suite.actions, postSteps: suite.postSteps,
                    dryRun: request.dryRun, onOutput: onOutput
                )
                let checks = await TestCheckRunner(
                    tooling: tooling, request: request, workspace: workspace
                ).run(suite.checks)
                let status: ExecutionOutcome.Status = checks.contains { $0.status == .failed }
                    ? .failed : executed.status
                outcome = ExecutionOutcome(
                    status: status, duration: executed.duration,
                    outputs: executed.outputs + suite.outputs, factsFile: executed.factsFile,
                    url: executed.url, notes: executed.notes, checks: checks
                )
            } catch {
                failure = error
                _ = try? await tooling.execute(
                    steps: suite.onFailure, dryRun: request.dryRun, onOutput: onOutput
                )
            }
            _ = try? await tooling.execute(steps: suite.cleanup, dryRun: request.dryRun, onOutput: onOutput)
            if let failure { throw failure }
            if let outcome { results.append(outcome) }
        }
        return Self.combine(results, notes: plan.suites.map(\.detail))
    }

    static func combine(_ outcomes: [ExecutionOutcome], notes: [String] = []) -> ExecutionOutcome {
        let status: ExecutionOutcome.Status
        if outcomes.contains(where: { $0.status == .failed }) {
            status = .failed
        } else if outcomes.allSatisfy({ $0.status == .planned }) {
            status = .planned
        } else {
            status = .succeeded
        }
        return ExecutionOutcome(
            status: status,
            duration: outcomes.reduce(0) { $0 + $1.duration },
            outputs: outcomes.flatMap(\.outputs),
            notes: outcomes.flatMap(\.notes) + notes,
            checks: outcomes.flatMap(\.checks)
        )
    }
}

/// Plans and executes an application, or starts it in the background.
public struct RunService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func plan(
        _ request: RunRequest, project: URL? = nil
    ) async throws -> (ResolvedWorkspace, BuildPlan?, RunPlan) {
        let workspace = try tooling.resolve(
            project: project, application: request.application, host: request.host,
            configuration: request.configuration
        )
        let host = try workspace.context.requiringHost()
        let driver = try tooling.driver(for: host)
        var build: BuildPlan?
        if !request.noBuild {
            build = try await driver.buildPlan(
                BuildRequest(
                    application: request.application, host: host, configuration: request.configuration,
                    device: request.device, browser: request.browser, dryRun: request.dryRun
                ),
                context: workspace.context
            )
        }
        let plan = try await driver.runPlan(request, context: workspace.context, build: build)
        return (workspace, build, plan)
    }

    public func run(_ request: RunRequest, project: URL? = nil) async throws -> ExecutionOutcome {
        let (_, build, plan) = try await plan(request, project: project)
        if request.dryRun {
            if let build {
                _ = try await tooling.execute(build, dryRun: true)
            }
            let outcome = try await tooling.execute(
                steps: plan.steps, actions: plan.actions, dryRun: true,
                detached: plan.detached, logFile: plan.logFile
            )
            return ExecutionOutcome(
                status: .planned, outputs: build?.outputs ?? [], factsFile: plan.factsFile,
                url: plan.url, notes: outcome.notes + plan.notes
            )
        }
        if let build {
            _ = try await tooling.execute(build)
        }
        let outcome = try await tooling.execute(
            steps: plan.steps, actions: plan.actions, dryRun: false,
            detached: plan.detached, logFile: plan.logFile
        )
        return ExecutionOutcome(
            status: plan.detached ? .started : outcome.status,
            duration: outcome.duration, outputs: build?.outputs ?? [],
            factsFile: plan.factsFile, url: plan.url, notes: outcome.notes + plan.notes
        )
    }
}

/// Plans and executes a release build into its deployment destination.
public struct DeployService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func plan(
        _ request: DeployRequest, project: URL? = nil
    ) async throws -> (ResolvedWorkspace, DeployPlan) {
        let workspace = try tooling.resolve(
            project: project, application: request.application, host: request.host,
            configuration: request.configuration
        )
        let host = try workspace.context.requiringHost()
        let application = try workspace.context.requiringApplication()
        let driver = try tooling.driver(for: host)
        let destination = request.destination
            ?? tooling.defaultDeploymentDestination(
                project: workspace.project, application: application, host: host,
                architecture: request.architecture
            )
        var resolved = request
        resolved.destination = destination
        let plan = try await driver.deployPlan(resolved, context: workspace.context, build: nil)
        return (workspace, plan)
    }

    public func run(_ request: DeployRequest, project: URL? = nil) async throws -> ExecutionOutcome {
        let (_, plan) = try await plan(request, project: project)
        if request.dryRun {
            _ = try await tooling.execute(
                steps: plan.steps, actions: plan.actions, postSteps: plan.postSteps, dryRun: true
            )
            return ExecutionOutcome(status: .planned, outputs: [plan.destination], notes: plan.notes)
        }
        if let build = plan.build {
            _ = try await tooling.execute(build)
        }
        let outcome = try await tooling.execute(
            steps: plan.steps, actions: plan.actions, postSteps: plan.postSteps
        )
        return ExecutionOutcome(
            status: outcome.status, duration: outcome.duration, outputs: [plan.destination],
            notes: outcome.notes + plan.notes
        )
    }
}

/// Prepares a debugger launch or attach configuration for one host.
public struct DebugService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func plan(
        _ request: DebugRequest, project: URL? = nil
    ) async throws -> (ResolvedWorkspace, DebugPlan) {
        let workspace = try tooling.resolve(
            project: project, application: request.application, host: request.host,
            configuration: request.configuration
        )
        let host = try workspace.context.requiringHost()
        let driver = try tooling.driver(for: host)
        let build = try await driver.buildPlan(
            BuildRequest(
                application: request.application, host: host, configuration: request.configuration,
                device: request.device, browser: request.browser
            ),
            context: workspace.context
        )
        let plan = try await driver.debugPlan(request, context: workspace.context, build: build)
        return (workspace, plan)
    }

    /// Runs the plan's preparation in full: the build, including the file
    /// actions and post-steps that assemble and sign an artifact, then whatever
    /// starts the application held for the debugger.
    public func prepare(_ request: DebugRequest, project: URL? = nil) async throws -> ExecutionOutcome {
        let (_, plan) = try await plan(request, project: project)
        return try await prepare(plan, dryRun: request.dryRun)
    }

    public func prepare(_ plan: DebugPlan, dryRun: Bool = false) async throws -> ExecutionOutcome {
        var outcomes: [ExecutionOutcome] = []
        if let build = plan.build {
            outcomes.append(try await tooling.execute(build, dryRun: dryRun))
        }
        outcomes.append(try await tooling.execute(steps: plan.preLaunch, dryRun: dryRun))

        let status: ExecutionOutcome.Status
        if dryRun {
            status = .planned
        } else if outcomes.contains(where: { $0.status == .failed }) {
            status = .failed
        } else {
            status = .succeeded
        }
        return ExecutionOutcome(
            status: status,
            duration: outcomes.reduce(0) { $0 + $1.duration },
            outputs: plan.build?.outputs ?? [],
            factsFile: plan.factsFile, url: plan.url,
            notes: outcomes.flatMap(\.notes) + plan.notes
        )
    }
}

/// Prepares and cleans the language server's per-host build index.
public struct LSPService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func environment(host: HostID?, project: URL? = nil) async throws -> LSPEnvironment {
        let workspace = try tooling.resolve(project: project, host: host)
        let resolvedHost = try workspace.context.requiringHost()
        return try await tooling.driver(for: resolvedHost).lspEnvironment(workspace.context)
    }

    /// The index build that fills a host's index directory: SwiftPM asked to build this host's
    /// head into `.build/<host>/index-build`, recording an index SourceKit reads while the editor
    /// works. The command is the plan; running it is `configure`.
    public func indexPlan(host: HostID?, project: URL? = nil) async throws -> (ResolvedWorkspace, LSPIndexPlan) {
        let workspace = try tooling.resolve(project: project, host: host)
        let resolvedHost = try workspace.context.requiringHost()
        let application = workspace.context.application ?? workspace.project.applications.first
        guard let application else {
            throw ToolingError.projectNotFound(
                "\(workspace.project.root.path) has no application to index.",
                suggestion: "Add one, or name it: `stateui lsp configure --application <name> --host \(resolvedHost.rawValue)`."
            )
        }
        let env = try await tooling.driver(for: resolvedHost).lspEnvironment(workspace.context)
        let checkout = try HostSupport.checkout(workspace.context)
        let index = checkout.appendingPathComponent(env.scratchPath)
        let builder = SwiftBuilder(
            runner: CommandRunner(executor: tooling.executor, environment: tooling.environment),
            environment: tooling.environment, platform: tooling.platform
        )
        let bin = await builder.binPath(
            application: application, host: resolvedHost, configuration: workspace.configuration,
            scratch: index, swiftSDK: env.swiftSDK, triple: env.triple, sdk: env.sdk.map { URL(fileURLWithPath: $0) }
        )
        let store = bin.appendingPathComponent("index-store", isDirectory: true)
        let arguments = builder.buildArguments(
            application: application, host: resolvedHost, configuration: workspace.configuration,
            scratch: index, product: application.product(for: resolvedHost),
            swiftSDK: env.swiftSDK, triple: env.triple, sdk: env.sdk.map { URL(fileURLWithPath: $0) },
            extra: ["-Xswiftc", "-index-store-path", "-Xswiftc", store.path]
        )
        let swift = try builder.swift()
        let plan = LSPIndexPlan(
            host: resolvedHost, packagePath: application.directory.path, indexDirectory: index.path,
            binPath: bin.path, command: [swift.path] + arguments,
            environment: env.environment,
            notes: env.notes + ["The index lives at \(index.path); removing it is `stateui lsp clean --host \(resolvedHost.rawValue)`."]
        )
        return (workspace, plan)
    }

    /// Write the folder's editor settings, and fill the host's index unless the plan is only
    /// asked for. The settings sit beside the checkout, where an editor's search reads them.
    public func configure(host: HostID?, project: URL? = nil, dryRun: Bool = false) async throws -> ExecutionOutcome {
        let (workspace, plan) = try await indexPlan(host: host, project: project)
        let settings = URL(fileURLWithPath: workspace.project.root.path).appendingPathComponent(".vscode/settings.json")
        let existing = FileSystem.exists(settings) ? try FileSystem.read(settings) : nil
        let contents = Self.settings(existing: existing)
        let step = ProcessInvocation(
            executable: URL(fileURLWithPath: plan.command[0]), arguments: Array(plan.command.dropFirst()),
            environment: plan.environment, workingDirectory: URL(fileURLWithPath: plan.packagePath),
            label: "indexing \(plan.indexDirectory) for \(workspace.host?.label ?? "the host")"
        )
        let outcome = try await tooling.execute(steps: dryRun ? [] : [step], actions: [FileAction(kind: .write, destination: settings, contents: contents)], dryRun: dryRun)
        var outputs: [URL] = [settings, URL(fileURLWithPath: plan.indexDirectory)]
        if let bin = plan.binPath { outputs.append(URL(fileURLWithPath: bin)) }
        return ExecutionOutcome(
            status: outcome.status, duration: outcome.duration,
            outputs: outputs, notes: plan.notes + outcome.notes
        )
    }

    /// Remove an index: one host's, or every host's, including the single index directory the
    /// editor used before one directory per host. The host indexes again on its own afterwards.
    public func clean(host: HostID?, all: Bool, project: URL? = nil, dryRun: Bool = false) async throws -> LSPCleanResult {
        let project = try tooling.project(explicit: project)
        let hosts: [HostID]
        if all {
            hosts = HostID.allCases
        } else {
            let stored = try tooling.loadConfiguration(project)
            let resolved = host ?? stored.defaultHost
            guard let resolved else {
                throw ToolingError.invalidArguments(
                    "No host to clean the index of.",
                    suggestion: "Name one: `stateui lsp clean --host gtk`, or every one: `stateui lsp clean --all`."
                )
            }
            hosts = [resolved]
        }

        var directories: [URL] = hosts.map { project.root.appendingPathComponent($0.indexDirectory, isDirectory: true) }
        let legacy = project.root.appendingPathComponent(".build/index-build", isDirectory: true)
        if FileSystem.isDirectory(legacy) { directories.append(legacy) }

        let existing = directories.filter { FileSystem.isDirectory($0) }
        let missing = directories.filter { !FileSystem.isDirectory($0) }
        let actions = existing.map { FileAction(kind: .remove, destination: $0) }
        _ = try await tooling.execute(steps: [], actions: actions, dryRun: dryRun)

        var notes: [String] = []
        if existing.isEmpty {
            notes.append("There was no index to remove.")
        } else {
            notes.append(dryRun
                ? "These indexes would be removed; the host indexes again when the editor asks."
                : "Removed \(existing.count) index \(existing.count == 1 ? "directory" : "directories"); the host indexes again when the editor asks.")
        }
        return LSPCleanResult(
            removed: existing.map { $0.path }, absent: missing.map { $0.path },
            notes: notes + (all ? ["Every host's index was cleaned."] : [])
        )
    }

    /// The settings an editor reads to work in this folder: the build folders a search should
    /// skip. Existing keys are kept - a repository's own settings survive being written into.
    /// Which host and application are being indexed is the checkout's own selection, in
    /// `.stateui/config.json`; the editors read that from the tool, not from a settings file
    /// the tool writes, so nothing naming a host or an application goes in here.
    static func settings(existing: String?) -> String {
        let exclude: [String: Any] = [
            "**/.build": true, "**/.swiftpm": true, "**/artifacts": true,
            "**/node_modules": true, "**/dist": true, "**/out": true,
        ]
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.prettyJSON(["search.exclude": exclude])
        }
        // A plain JSON file is merged and written back as it was. An editor's
        // settings file usually carries comments - VS Code reads JSONC - and
        // re-serializing it would delete every one of them, so such a file is
        // edited in place instead.
        if let data = existing.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var document = object
            document["search.exclude"] = exclude
            return Self.prettyJSON(document)
        }
        return merging(exclude, into: existing)
    }

    /// Puts `search.exclude` into a JSONC document without rewriting what stands
    /// around it: the member is replaced where it already exists, else inserted
    /// before the document's closing brace.
    private static func merging(_ exclude: [String: Any], into text: String) -> String {
        let value = Self.prettyJSON(exclude)
        if let range = JSONCScanner.valueRange(of: "search.exclude", in: text) {
            return text.replacingCharacters(in: range, with: value)
        }
        guard let close = text.lastIndex(where: { !$0.isWhitespace }), text[close] == "}" else {
            return Self.prettyJSON(["search.exclude": exclude])
        }
        let member = "  \"search.exclude\" : " + value.replacingOccurrences(of: "\n", with: "\n  ")
        let prefix = String(text[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        let comma = prefix.hasSuffix("{") || prefix.hasSuffix(",") ? "" : ","
        return prefix + comma + "\n" + member + "\n" + String(text[close...])
    }

    private static func prettyJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
            ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Finds a member's value in a JSON-with-comments document, without decoding or
/// rewriting the document, so comments and formatting survive a settings write.
private enum JSONCScanner {
    static func valueRange(of key: String, in text: String) -> Range<String.Index>? {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            skipTrivia(characters, &index)
            guard index < characters.count else { return nil }
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            guard let name = readString(characters, &index) else { return nil }
            guard name == key else { continue }
            skipTrivia(characters, &index)
            guard index < characters.count, characters[index] == ":" else { continue }
            index += 1
            skipTrivia(characters, &index)
            guard index < characters.count else { return nil }
            let valueStart = index
            guard let end = endOfValue(characters, &index) else { return nil }
            return text.index(text.startIndex, offsetBy: valueStart)..<text.index(text.startIndex, offsetBy: end)
        }
        return nil
    }

    private static func skipTrivia(_ characters: [Character], _ index: inout Int) {
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                index += 2
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, characters.count)
                continue
            }
            break
        }
    }

    private static func readString(_ characters: [Character], _ index: inout Int) -> String? {
        guard index < characters.count, characters[index] == "\"" else { return nil }
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 1
                if index < characters.count {
                    value.append(characters[index])
                    index += 1
                }
                continue
            }
            if character == "\"" {
                index += 1
                return value
            }
            value.append(character)
            index += 1
        }
        return nil
    }

    /// Advances `index` past one JSON value and answers where it ended.
    private static func endOfValue(_ characters: [Character], _ index: inout Int) -> Int? {
        guard index < characters.count else { return nil }
        if characters[index] == "\"" {
            return readString(characters, &index) == nil ? nil : index
        }
        if characters[index] == "{" || characters[index] == "[" {
            let open = characters[index]
            let close: Character = open == "{" ? "}" : "]"
            var depth = 0
            while index < characters.count {
                skipTrivia(characters, &index)
                guard index < characters.count else { return nil }
                if characters[index] == "\"" {
                    guard readString(characters, &index) != nil else { return nil }
                    continue
                }
                if characters[index] == open {
                    depth += 1
                } else if characters[index] == close {
                    depth -= 1
                    index += 1
                    if depth == 0 { return index }
                    continue
                }
                index += 1
            }
            return nil
        }
        let start = index
        while index < characters.count,
              characters[index] != ",", characters[index] != "}", characters[index] != "]" {
            index += 1
        }
        return index > start ? index : nil
    }
}

/// The budgets a host's shipped modules are held to. The Web host's module is what a
/// page downloads, so each application's release module is built, gzipped the way a
/// page fetches it, and weighed against the budget the repository records.
public struct SizeService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    /// Reads the Web size budgets from the repository's `.scripts/Web/size-budgets.sh`,
    /// whose `budgets=( ... )` array holds one `"Application bytes"` entry per
    /// application. Returns the application-to-byte mapping.
    static func parseSizeBudgets(_ text: String) throws -> [String: Int] {
        guard let start = text.range(of: "budgets=("),
              let end = text.range(of: ")", range: start.upperBound..<text.endIndex) else {
            throw ToolingError.projectNotFound("No budgets array was found in the size-budget script.")
        }
        let body = String(text[start.upperBound..<end.lowerBound])
        var result: [String: Int] = [:]
        let pattern = #""([^"\s]+)\s+(\d+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        for match in regex.matches(in: body, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: body),
                  let bytesRange = Range(match.range(at: 2), in: body) else { continue }
            guard let bytes = Int(body[bytesRange]) else { continue }
            result[String(body[nameRange])] = bytes
        }
        guard !result.isEmpty else {
            throw ToolingError.projectNotFound("No size budgets were recorded in the script.")
        }
        return result
    }

    public func budgets(
        host: HostID, configuration: BuildConfiguration = .release, project: URL? = nil
    ) async throws -> SizeReport {
        guard host == .web else {
            throw ToolingError.unsupportedHost(
                "\(host.label) ships nothing a page downloads, so it has no size to hold.",
                suggestion: "Measure the Web host: `stateui size budgets --host web`."
            )
        }
        let (project, recorded) = try recordedBudgets(project)
        guard let gzip = FileSystem.findExecutable("gzip", environment: tooling.environment) else {
            throw ToolingError.toolchainMissing(
                "gzip was not found, so a module could not be weighed the way a page fetches it.",
                suggestion: "Install gzip."
            )
        }

        var measured: [SizeBudget] = []
        for (application, budget) in recorded.sorted(by: { $0.key < $1.key }) {
            let workspace = try tooling.resolve(
                project: project.root, application: application, host: .web, configuration: configuration
            )
            guard let app = workspace.application else {
                throw ToolingError.applicationNotFound(
                    "\(application) is not an application of this repository.",
                    context: ["applications": project.applications.map(\.name).joined(separator: ", ")]
                )
            }
            _ = try await BuildService(tooling: tooling).run(
                BuildRequest(application: application, host: .web, configuration: configuration),
                project: project.root
            )
            let module = app.buildDirectory(for: .web)
                .appendingPathComponent("site", isDirectory: true)
                .appendingPathComponent(configuration.rawValue, isDirectory: true)
                .appendingPathComponent("\(app.product(for: .web)).wasm")
            guard FileSystem.exists(module) else {
                throw ToolingError.buildFailed(
                    "\(application)'s Web module was not built at \(module.path).",
                    context: ["configuration": configuration.rawValue],
                    suggestion: "Build it: `stateui build --application \(application) --host web --configuration \(configuration.rawValue)`."
                )
            }
            measured.append(
                SizeBudget(
                    application: application, module: module,
                    bytes: try await gzipped(module, with: gzip), budget: budget
                )
            )
        }
        return SizeReport(host: .web, configuration: configuration, budgets: measured)
    }

    /// What a measurement would build and weigh, for `--dry-run` and the RPC's
    /// `dryRun: true`: planning runs nothing.
    public func plan(
        host: HostID, configuration: BuildConfiguration = .release, project explicit: URL? = nil
    ) async throws -> SizePlan {
        guard host == .web else {
            throw ToolingError.unsupportedHost(
                "\(host.label) ships nothing a page downloads, so it has no size to hold.",
                suggestion: "Measure the Web host: `stateui size budgets --host web`."
            )
        }
        let (project, recorded) = try recordedBudgets(explicit)
        var entries: [SizePlan.Entry] = []
        for (application, budget) in recorded.sorted(by: { $0.key < $1.key }) {
            let (workspace, build) = try await BuildService(tooling: tooling).plan(
                BuildRequest(application: application, host: .web, configuration: configuration),
                project: project.root
            )
            guard let app = workspace.application else {
                throw ToolingError.applicationNotFound(
                    "\(application) is not an application of this repository.",
                    context: ["applications": project.applications.map(\.name).joined(separator: ", ")]
                )
            }
            let module = app.buildDirectory(for: .web)
                .appendingPathComponent("site", isDirectory: true)
                .appendingPathComponent(configuration.rawValue, isDirectory: true)
                .appendingPathComponent("\(app.product(for: .web)).wasm")
            entries.append(
                SizePlan.Entry(application: application, module: module, budget: budget, build: build)
            )
        }
        return SizePlan(host: .web, configuration: configuration, budgets: entries)
    }

    private func recordedBudgets(_ explicit: URL?) throws -> (ProjectInfo, [String: Int]) {
        let project = try tooling.project(explicit: explicit)
        let file = project.root.appendingPathComponent(".scripts/Web/size-budgets.sh")
        guard FileSystem.exists(file) else {
            throw ToolingError.projectNotFound(
                "The repository records no Web size budgets at \(file.path).",
                suggestion: "Add an entry to the budgets array there."
            )
        }
        return (project, try Self.parseSizeBudgets(try FileSystem.read(file)))
    }

    /// The module gzipped at level nine with no name or timestamp in the stream. The
    /// copy beside it is weighed and removed, so the site holds only the module.
    private func gzipped(_ module: URL, with gzip: URL) async throws -> Int {
        let compressed = URL(fileURLWithPath: module.path + ".gz")
        defer { try? FileSystem.remove(compressed) }
        let runner = CommandRunner(executor: tooling.executor, environment: tooling.environment)
        guard let result = await runner.result(gzip, ["-9", "-n", "-k", "-f", module.path], label: "gzip"),
              result.exitCode == 0 else {
            throw ToolingError.buildFailed(
                "gzip could not compress \(module.path).",
                suggestion: "Check the module is readable, and gzip is installed."
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: compressed.path)
        return (attributes[.size] as? Int) ?? 0
    }
}

/// The budgets as the repository writes them: one entry per application, the module's
/// size gzipped, in bytes.
private struct SizeBudgetFile: Codable {
    let budgets: [String: Int]
}

/// Where a Web run's page is served, and by which process.
public struct ServedPage: Sendable, Codable, Equatable {
    public let url: String
    public let port: Int
    public let pid: Int32

    public init(url: String, port: Int, pid: Int32) {
        self.url = url
        self.port = port
        self.pid = pid
    }
}

/// Gives up the page a Web run left serving. A run answers `started` and then serves
/// through a detached process, so the task the editor cancelled is long gone while the
/// port still listens; the facts file names the process, and this stops it.
public struct WebServerService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func stop(project explicit: URL? = nil, application requested: String? = nil) throws -> ServedPage {
        #if os(Windows)
        throw ToolingError.unsupportedHost("The Web host's server runs on macOS and Linux.")
        #else
        let workspace = try tooling.resolve(
            project: explicit, application: requested, host: .web
        )
        guard let application = workspace.application else {
            throw ToolingError.applicationNotFound(
                "Nothing names an application to serve in \(workspace.project.root.path).",
                context: ["applications": workspace.project.applications.map(\.name).joined(separator: ", ")],
                suggestion: "Run `stateui apps`, or name one with --application."
            )
        }

        let facts = application.buildDirectory(for: .web).appendingPathComponent("server.json")
        guard FileSystem.exists(facts) else {
            throw ToolingError(
                code: "notServing",
                message: "Nothing serves \(application.name)'s page.",
                suggestion: "Serve one with `stateui run --host web`; `stop` only gives up a page already served."
            )
        }

        let page = try readFacts(facts)
        guard kill(page.pid, 0) == 0 else {
            // The facts outlive the process they named when a run dies by other means:
            // the file goes, and the port is already free.
            try? FileSystem.remove(facts)
            throw ToolingError(
                code: "notServing",
                message: "Nothing serves \(application.name)'s page any more; \(page.url) is not listening.",
                suggestion: "Serve one with `stateui run --host web`."
            )
        }

        kill(page.pid, SIGTERM)
        var waited = 0
        while waited < 40 && kill(page.pid, 0) == 0 {
            usleep(50_000)
            waited += 1
        }
        if kill(page.pid, 0) == 0 { kill(page.pid, SIGKILL) }
        try? FileSystem.remove(facts)
        return page
        #endif
    }

    /// The page `server.json` names. A file that names no process is treated as no page
    /// at all, so a run made by an older binary is not reported as something stoppable.
    private func readFacts(_ factsFile: URL) throws -> ServedPage {
        let data = try Data(contentsOf: factsFile)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? Int).map(Int32.init),
              let port = (object["port"] as? Int),
              let servedURL = object["url"] as? String else {
            throw ToolingError(
                code: "notServing",
                message: "\(factsFile.path) names no served page.",
                suggestion: "Run `stateui run --host web` again, so the facts carry a port and a process."
            )
        }
        return ServedPage(url: servedURL, port: port, pid: pid)
    }
}
