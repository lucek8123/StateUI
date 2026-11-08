// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import StateUITooling

@main
struct StateUICommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            print(help)
            exit(0)
        }
        if command == "--version" || command == "-version" {
            print(ToolingVersion.summary)
            exit(0)
        }

        do {
            let parsed = try CommandLineParser.parse(Array(arguments.dropFirst()))
            // `--help` beside a command says what that command takes, rather than
            // being accepted by the parser and ignored by the command.
            if parsed.flag("help") { print(help); exit(0) }
            let logger = Logger(level: logLevel(parsed))
            let projectURL = parsed.value("project").map { FileSystem.expand($0) }
            let tooling = Tooling(
                logger: logger,
                cwd: projectURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )

            switch command {
            case "version":
                emit(versionResult(), json: parsed.flag("json"), human: ToolingVersion.summary)
            case "help", "--help", "-h":
                print(help)
            case "doctor":
                try await doctor(tooling, parsed)
            case "project", "info":
                try project(tooling, parsed)
            case "apps":
                try apps(tooling, parsed)
            case "hosts":
                try await hosts(tooling, parsed)
            case "host":
                try host(tooling, parsed)
            case "config":
                try config(tooling, parsed)
            case "devices":
                try await devices(tooling, parsed)
            case "browsers":
                try await browsers(tooling, parsed)
            case "build":
                try await build(tooling, parsed)
            case "test":
                try await test(tooling, parsed)
            case "run":
                try await run(tooling, parsed)
            case "deploy":
                try await deploy(tooling, parsed)
            case "stop":
                try stopServed(tooling, parsed)
            case "size":
                try await size(tooling, parsed)
            case "new":
                try newApplication(tooling, parsed)
            case "lsp":
                try await lsp(tooling, parsed)
            case "debug":
                try await debug(tooling, parsed)
            case "group":
                try await group(tooling, parsed)
            case "rpc":
                try await rpc(tooling, parsed)
            case "__serve-web":
                try serveWeb(parsed)
            case "__web-test":
                try webTest(parsed)
            case "__web-browser-test":
                try webBrowserTest(parsed, environment: tooling.environment)
            case "__android-logcat":
                try androidLogcat(parsed)
            case "__android-debug":
                try androidDebug(parsed)
            case "__uikit-debug":
                try uikitDebug(parsed)
            default:
                throw ToolingError.invalidArguments(
                    "Unknown command \(command).",
                    suggestion: "Run `stateui help`."
                )
            }
        } catch {
            let structured = error.toolingError
            FileHandle.standardError.write(Data(("stateui: \(structured)\n").utf8))
            exit(exitCode(for: structured))
        }
    }

    // MARK: - Commands

    static func doctor(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let hosts = try hostOption(parsed).map { [$0] }
        let report = await tooling.toolchainService.report(hosts: hosts)
        if parsed.flag("json") {
            emit(report, json: true)
        } else {
            print("platform: \(report.platform.description)")
            for finding in report.findings {
                let status = finding.status.rawValue
                let version = finding.version.map { " (\($0))" } ?? ""
                print("\(finding.isSatisfied ? "ok" : "!!") \(finding.component)\(version) [\(status)]")
                if !finding.isSatisfied, !finding.advice.isEmpty {
                    print("   \(finding.advice)")
                }
            }
            if !report.ready {
                print("\nBlocking components are missing. Fix them and run doctor again.")
            }
        }
        if !report.ready { exit(1) }
    }

    static func project(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        if parsed.flag("json") {
            emit(project, json: true)
        } else {
            print("root: \(project.root.path)")
            print("kind: \(project.kind.rawValue)")
            print("checkout: \(project.checkout?.path ?? "none")")
            print("applications: \(project.applications.map(\.name).joined(separator: ", "))")
        }
    }

    static func apps(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        // `apps info Gallery` names one application; `apps` and `apps list` list them all.
        let (named, _) = parsed.application(besides: ["list", "info"])
        if let named {
            guard let application = project.applications.first(where: { $0.name == named }) else {
                throw ToolingError.applicationNotFound(
                    "No application named \(named) stands in this checkout.",
                    context: ["application": named],
                    suggestion: "Run `stateui apps` to list what the repository holds."
                )
            }
            if parsed.flag("json") {
                emit(application, json: true)
            } else {
                print(application.name)
                print("  directory: \(application.directory.path)")
                print("  manifest:  \(application.manifest.path)")
                for head in application.heads {
                    print("  head:      \(head.host.label)")
                }
            }
            return
        }
        if parsed.flag("json") {
            emit(project.applications, json: true)
        } else if project.applications.isEmpty {
            print("No StateUI applications were found.")
        } else {
            for application in project.applications {
                let heads = application.availableHosts.map(\.label).joined(separator: ", ")
                print("\(application.name)\t\(heads)\t\(application.directory.path)")
            }
        }
    }

    static func hosts(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let service = ProjectService(tooling: tooling)
        let availability = try await service.hosts(project: parsed.value("project").map { FileSystem.expand($0) })
        // `hosts info gtk` answers one host; `hosts` and `hosts list` answer every one.
        let (named, _) = parsed.application(besides: ["list", "info"])
        if let raw = named {
            guard let host = HostID(parsing: raw) else {
                throw ToolingError.unsupportedHost(
                    "\(raw) is not a StateUI host.",
                    context: ["host": raw],
                    suggestion: "Run `stateui hosts` to list the hosts StateUI knows."
                )
            }
            let descriptor = HostDescriptor(id: host)
            let item = availability.first(where: { $0.host == host })
            if parsed.flag("json") {
                emit(
                    ["host": try JSONValue(descriptor), "availability": try JSONValue(item)],
                    json: true
                )
            } else {
                print(descriptor.label)
                print("  \(descriptor.detail)")
                print("  platforms: \(descriptor.platforms.map(\.rawValue).joined(separator: ", "))")
                print("  index:     \(descriptor.indexDirectory)")
                print("  status:    \(item?.status.rawValue ?? "unknown")")
                if let reason = item?.reason {
                    print("  reason:    \(reason)")
                }
            }
            return
        }
        if parsed.flag("json") {
            emit(availability, json: true)
        } else {
            for item in availability {
                let descriptor = HostDescriptor(id: item.host)
                print("\(descriptor.id.rawValue)\t\(item.status.rawValue)\t\(item.reason ?? "")")
            }
        }
    }

    static func host(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        let action = parsed.positionals.first ?? "list"
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        switch action {
        case "list", "get":
            let config = try tooling.loadConfiguration(project)
            if parsed.flag("json") {
                emit(config, json: true)
            } else {
                print("host: \(config.defaultHost?.rawValue ?? "none")")
                print("application: \(config.defaultApplication ?? "none")")
                print("configuration: \(config.configuration?.rawValue ?? "none")")
            }
        case "set":
            guard parsed.positionals.count >= 2, let host = HostID(parsing: parsed.positionals[1]) else {
                throw ToolingError.invalidArguments(
                    "host set needs a host: appkit, uikit, android, winui, gtk or web."
                )
            }
            try ProjectService(tooling: tooling).select(
                host: host, project: parsed.value("project").map { FileSystem.expand($0) }
            )
            print("Selected \(host.label).")
        default:
            throw ToolingError.invalidArguments("host takes list, get or set.")
        }
    }

    static func config(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        let action = parsed.positionals.first ?? "get"
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        switch action {
        case "get", "list":
            let config = try tooling.loadConfiguration(project)
            if parsed.flag("json") {
                emit(config, json: true)
            } else {
                print("host: \(config.defaultHost?.rawValue ?? "none")")
                print("application: \(config.defaultApplication ?? "none")")
                print("configuration: \(config.configuration?.rawValue ?? "none")")
            }
        case "set":
            let service = ProjectService(tooling: tooling)
            let selectedHost = try hostOption(parsed)
            // A device belongs to a host; `--host` names it when `--device-host` does not.
            let deviceHost = try deviceHostOption(parsed) ?? selectedHost
            try service.select(
                host: selectedHost,
                application: parsed.value("application"),
                configuration: try configurationOption(parsed),
                device: parsed.value("device"),
                deviceHost: deviceHost,
                browser: parsed.value("browser"),
                project: parsed.value("project").map { FileSystem.expand($0) }
            )
            let config = try tooling.loadConfiguration(project)
            if parsed.flag("json") {
                emit(config, json: true)
            } else {
                print("Updated configuration.")
            }
        default:
            throw ToolingError.invalidArguments("config takes get or set.")
        }
    }
    static func devices(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        guard let raw = parsed.value("host") else {
            throw ToolingError.invalidArguments("devices needs --host.", suggestion: "Try --host android or --host uikit.")
        }
        guard let host = HostID(parsing: raw) else {
            throw ToolingError.invalidArguments(
                "'\(raw)' is not a StateUI host.",
                context: ["host": raw],
                suggestion: "Use one of: \(HostID.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        let devices = try await ProjectService(tooling: tooling).devices(
            host: host, project: parsed.value("project").map { FileSystem.expand($0) }
        )
        if parsed.flag("json") {
            emit(devices, json: true)
        } else if devices.isEmpty {
            print("No \(host.label) devices are available.")
        } else {
            for device in devices {
                print("\(device.id)\t\(device.name)\t\(device.kind.rawValue)\t\(device.state ?? "")")
            }
        }
    }

    static func browsers(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let browsers = try await ProjectService(tooling: tooling).browsers(
            project: parsed.value("project").map { FileSystem.expand($0) }
        )
        if parsed.flag("json") {
            emit(browsers, json: true)
        } else if browsers.isEmpty {
            print("No browsers were found.")
        } else {
            for browser in browsers {
                print("\(browser.id)\t\(browser.name)\t\(browser.isDefault ? "default" : "")")
            }
        }
    }

    static func build(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let (named, extras) = parsed.application()
        let request = BuildRequest(
            application: named,
            host: try hostOption(parsed),
            configuration: try configuration(tooling, parsed),
            device: parsed.value("device"), browser: parsed.value("browser"),
            architecture: parsed.value("architecture"),
            dryRun: parsed.flag("dry-run"),
            extraArguments: extras
        )
        let service = BuildService(tooling: tooling)
        if request.dryRun {
            let (_, plan) = try await service.plan(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emit(plan, json: parsed.flag("json"), human: describe(plan))
        } else {
            let outcome = try await service.run(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emitOutcome(outcome, json: parsed.flag("json"))
        }
    }

    static func test(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let (named, extras) = parsed.application()
        guard extras.isEmpty else {
            throw ToolingError.invalidArguments(
                "test takes one application and no other positional argument.",
                suggestion: "Name a suite with --suite and a filter with --filter."
            )
        }
        let request = TestRequest(
            application: named,
            host: try hostOption(parsed),
            configuration: try configuration(tooling, parsed),
            device: parsed.value("device"),
            filter: parsed.value("filter"), suite: parsed.value("suite"),
            browser: parsed.flag("in-browser"),
            buildOnly: parsed.flag("build-only"),
            architecture: parsed.value("architecture"),
            updateExports: parsed.flag("update-exports"),
            staleOnly: parsed.flag("stale"),
            dryRun: parsed.flag("dry-run")
        )
        let service = TestService(tooling: tooling)
        if request.dryRun {
            let (_, plan) = try await service.plan(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emit(plan, json: parsed.flag("json"), human: describe(plan))
        } else {
            let outcome = try await service.run(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emitOutcome(outcome, json: parsed.flag("json"))
        }
    }

    static func run(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let (named, extras) = parsed.application()
        guard extras.isEmpty else {
            throw ToolingError.invalidArguments(
                "run takes one application and no other positional argument.",
                suggestion: "Run `stateui run \(named ?? "") --host <host>`."
            )
        }
        let request = RunRequest(
            application: named,
            host: try hostOption(parsed),
            configuration: try configuration(tooling, parsed),
            device: parsed.value("device"), browser: parsed.value("browser"),
            port: parsed.value("port").flatMap(Int.init),
            dryRun: parsed.flag("dry-run"), detach: parsed.flag("detach"),
            prepareDebugger: parsed.flag("prepare"), noBuild: parsed.flag("no-build")
        )
        let service = RunService(tooling: tooling)
        if request.dryRun {
            let (_, buildPlan, runPlan) = try await service.plan(
                request, project: parsed.value("project").map { FileSystem.expand($0) }
            )
            if parsed.flag("json") {
                let result: [String: JSONValue] = [
                    "build": try buildPlan.map { try JSONValue($0) } ?? .null,
                    "run": try JSONValue(runPlan),
                ]
                emit(result, json: true)
            } else {
                if let buildPlan { print(describe(buildPlan)) }
                print(describe(runPlan))
            }
        } else {
            let outcome = try await service.run(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emitOutcome(outcome, json: parsed.flag("json"))
        }
    }

    static func deploy(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let (named, extras) = parsed.application()
        guard extras.isEmpty else {
            throw ToolingError.invalidArguments(
                "deploy takes one application and no other positional argument.",
                suggestion: "Name where to lay it out with --destination."
            )
        }
        let request = DeployRequest(
            application: named,
            host: try hostOption(parsed),
            configuration: try configuration(tooling, parsed),
            device: parsed.value("device"), browser: parsed.value("browser"),
            architecture: parsed.value("architecture"),
            destination: parsed.value("destination").map { FileSystem.expand($0) },
            dryRun: parsed.flag("dry-run")
        )
        let service = DeployService(tooling: tooling)
        if request.dryRun {
            let (_, plan) = try await service.plan(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emit(plan, json: parsed.flag("json"), human: describe(plan))
        } else {
            let outcome = try await service.run(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emitOutcome(outcome, json: parsed.flag("json"))
        }
    }

    /// Gives up the page a Web run left serving. Only a Web page is served, so naming
    /// another host is answered plainly rather than silently doing nothing.
    static func stopServed(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        let (named, extras) = parsed.application()
        guard extras.isEmpty else {
            throw ToolingError.invalidArguments(
                "stop takes one application and no other positional argument.",
                suggestion: "stateui stop [NAME] --host web"
            )
        }
        let host = try hostOption(parsed, default: .web)!
        guard host == .web else {
            throw ToolingError.unsupportedHost(
                "Nothing serves a page for \(host.rawValue); only the Web host serves one.",
                suggestion: "Drop --host, or give up a Web page: stateui stop --host web."
            )
        }
        let page = try WebServerService(tooling: tooling).stop(
            project: parsed.value("project").map { FileSystem.expand($0) },
            application: named ?? parsed.value("application")
        )
        if parsed.flag("json") {
            emit(page, json: true)
        } else {
            print("Gave up \(page.url), served as process \(page.pid).")
        }
    }

    /// Each application's Web module, built for release, gzipped the way a page
    /// fetches it, and held to the budget the repository records beside its exports.
    static func size(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let action = parsed.positionals.first ?? "budgets"
        guard action == "budgets" else {
            throw ToolingError.invalidArguments(
                "The size command measures budgets.",
                suggestion: "stateui size budgets --host web"
            )
        }
        let host = try hostOption(parsed, default: .web)!
        let configuration = try configurationOption(parsed) ?? .release
        let project = parsed.value("project").map { FileSystem.expand($0) }
        if parsed.flag("dry-run") {
            let plan = try await SizeService(tooling: tooling).plan(
                host: host, configuration: configuration, project: project
            )
            emit(plan, json: parsed.flag("json"), human: describe(plan))
            return
        }
        let report = try await SizeService(tooling: tooling).budgets(
            host: host, configuration: configuration, project: project
        )
        if parsed.flag("json") {
            emit(report, json: true)
        } else {
            for budget in report.budgets { print(budget.sentence) }
        }
        if report.failed {
            throw ToolingError.buildFailed(
                "A module stands over its budget.",
                context: report.budgets.filter { $0.verdict == .over }
                    .map { [$0.application: String($0.bytes)] }
                    .reduce([:]) { $0.merging($1) { $1 } },
                suggestion: "Lower the module, or raise its budget in the change that grows it."
            )
        }
    }

    static func newApplication(_ tooling: Tooling, _ parsed: ParsedCommand) throws {
        guard let name = parsed.positionals.first else {
            throw ToolingError.invalidArguments("new needs a name.", suggestion: "stateui new Gallery2")
        }
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        let directory = try ScaffoldService().create(
            name: name,
            appsDirectory: parsed.value("apps-dir").map { FileSystem.expand($0) },
            project: project
        )
        if parsed.flag("json") {
            emit(["application": name, "directory": directory.path], json: true)
        } else {
            print("Created \(directory.path)")
        }
    }

    static func lsp(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let action = parsed.positionals.first ?? "environment"
        guard ["environment", "configure", "clean"].contains(action) else {
            throw ToolingError.invalidArguments("lsp takes environment, configure or clean.")
        }
        let service = LSPService(tooling: tooling)
        let host = try hostOption(parsed)
        let project = parsed.value("project").map { FileSystem.expand($0) }
        switch action {
        case "environment":
            let environment = try await service.environment(host: host, project: project)
            if parsed.flag("json") {
                emit(environment, json: true)
            } else {
                print(try JSON.encode(environment, pretty: true))
            }
        case "configure":
            // A dry run says what indexing would be run; only a real run builds the index.
            let outcome = try await service.configure(
                host: host, project: project, dryRun: parsed.flag("dry-run")
            )
            emitOutcome(outcome, json: parsed.flag("json"))
        case "clean":
            let result = try await service.clean(host: host, all: parsed.flag("all"), project: project, dryRun: parsed.flag("dry-run"))
            if parsed.flag("json") {
                emit(result, json: true)
            } else {
                let verb = parsed.flag("dry-run") ? "would remove" : "removed"
                for path in result.removed { print("\(verb) \(path)") }
                for note in result.notes { print(note) }
            }
        default:
            break
        }
    }

    /// A project group: a folder holding one application per StateUI release, and the workspace
    /// that opens all of them at once.
    static func group(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let service = GroupService(tooling: tooling)
        let project = parsed.value("project").map { FileSystem.expand($0) }
        let checkout = parsed.value("checkout").map { FileSystem.expand($0) }
        let floor = parsed.value("minimum")
        let action = parsed.positionals.first ?? "create"
        switch action {
        case "releases", "list":
            let releases = try await service.releases(checkout: checkout, project: project, floor: floor)
            if parsed.flag("json") {
                emit(releases, json: true)
            } else {
                for release in releases { print(release) }
            }
        case "create":
            let name = parsed.positionals.dropFirst().first ?? parsed.value("name")
            guard let name else {
                throw ToolingError.invalidArguments(
                    "group create needs a name.",
                    suggestion: "stateui group create MyApp [release...]"
                )
            }
            let releases = Array(parsed.positionals.dropFirst(2))
            let outcome = try await service.run(
                name: name,
                releases: releases.isEmpty ? nil : releases,
                at: parsed.value("destination").map { FileSystem.expand($0) },
                checkout: checkout, project: project, floor: floor,
                dryRun: parsed.flag("dry-run")
            )
            emitOutcome(outcome, json: parsed.flag("json"))
        default:
            throw ToolingError.invalidArguments("group takes releases or create.")
        }
    }

    static func debug(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        let action = parsed.positionals.first ?? "plan"
        let (named, extras) = parsed.application(besides: ["plan", "prepare"])
        guard extras.isEmpty else {
            throw ToolingError.invalidArguments(
                "debug takes one application and no other positional argument.",
                suggestion: "stateui debug plan <application> --host <host>."
            )
        }
        let request = DebugRequest(
            application: named,
            host: try hostOption(parsed),
            configuration: try configuration(tooling, parsed),
            device: parsed.value("device"), browser: parsed.value("browser"),
            prepare: action == "prepare" || parsed.flag("prepare"),
            dryRun: parsed.flag("dry-run")
        )
        let service = DebugService(tooling: tooling)
        if action == "prepare" {
            let outcome = try await service.prepare(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emitOutcome(outcome, json: parsed.flag("json"))
        } else if action == "plan" {
            let (_, plan) = try await service.plan(request, project: parsed.value("project").map { FileSystem.expand($0) })
            emit(plan, json: parsed.flag("json"), human: describe(plan))
        } else {
            throw ToolingError.invalidArguments("debug takes plan or prepare.")
        }
    }

    static func rpc(_ tooling: Tooling, _ parsed: ParsedCommand) async throws {
        guard parsed.flag("stdio") || parsed.value("transport") == "stdio" else {
            throw ToolingError.invalidArguments(
                "rpc needs --stdio.", suggestion: "The editor starts `stateui rpc --stdio`."
            )
        }
        let server = RPCServer(
            handler: ToolingRPC(tooling: tooling), logger: tooling.logger
        )
        try await server.run()
    }

    // MARK: - Hidden plan helpers

    static func serveWeb(_ parsed: ParsedCommand) throws {
        guard parsed.positionals.count >= 4 else {
            throw ToolingError.invalidArguments("__serve-web needs a site, port, facts file and browser.")
        }
        let site = FileSystem.expand(parsed.positionals[0])
        guard let port = Int(parsed.positionals[1]) else {
            throw ToolingError.invalidArguments("__serve-web's port is not a number.")
        }
        let facts = FileSystem.expand(parsed.positionals[2])
        let browserID = parsed.positionals[3]
        let query = parsed.positionals.count > 4 ? parsed.positionals[4] : ""
        let executor = RealProcessExecutor()
        let runner = CommandRunner(executor: executor)
        let browser: Browser?
        if browserID == "none" {
            browser = Browser(id: "none", name: "none", executable: "", isDefault: false, isChromium: false)
        } else if browserID == "default" || browserID.isEmpty {
            browser = Browser(id: "default", name: "default", executable: "", isDefault: true, isChromium: false)
        } else {
            browser = try awaitBlocking {
                await BrowserDiscovery(runner: runner).browser(id: browserID)
            }
        }
        let server = StaticWebServer(
            root: site, port: port, factsFile: facts, browser: browser, query: query
        )
        try server.run()
    }

    /// The Web suite's class holding the conformance families, and the classes whose tests
    /// need a browser's own page - layout, focus, dialogs, input - so run in one.
    private static let webConformanceClass = "StateUIWebTests.WebConformanceTests"
    /// The host's own tests that need a browser's page. Kept equal to
    /// `hosts_in_browser` in `.scripts/Web/test-web.sh`: a class missing here runs
    /// in Node, where it fails, and never runs in the browser either.
    private static let webInBrowserClasses = [
        "StateUIWebTests.WebDrawnChildrenTests", "StateUIWebTests.WebGesturePaceTests",
        "StateUIWebTests.WebRequestTests", "StateUIWebTests.WebShapeRoomTests",
        "StateUIWebTests.WebKeyboardTests", "StateUIWebTests.WebFrameReportTests",
        "StateUIWebTests.WebWindowClosingTests", "StateUIWebTests.WebHistoryTests",
        "StateUIWebTests.WebLinksTests", "StateUIWebTests.WebTabTitleTests",
        "StateUIWebTests.WebLeaveTests", "StateUIWebTests.WebLookTests",
        "StateUIWebTests.WebScrollOffsetTests", "StateUIWebTests.WebHandTests",
        "StateUIWebTests.WebPointerTests", "StateUIWebTests.WebTabStripTests",
        "StateUIWebTests.WebPageElementTests", "StateUIWebTests.WebCanvasViewTests",
        "StateUIWebTests.WebEnvironmentTests", "StateUIWebTests.WebToggleTests",
        "StateUIWebTests.WebChoiceTests", "StateUIWebTests.WebEditMenuTests",
        "StateUIWebTests.WebTestWindowTests", "StateUIWebTests.WebHeldMenuTests",
        "StateUIWebTests.WebWordsOnTheWayTests",
    ]

    /// Every test the suite's program lists, one per line, as `run.mjs --list-tests` answers.
    private static func listWebTests(
        node: URL, runScript: URL, relay: URL, program: URL
    ) throws -> [String] {
        let (code, output) = try runCapturing(
            node, [runScript.path, relay.path, program.path, "--list-tests"]
        )
        guard code == 0 else {
            throw ToolingError.testFailed(
                "The Web suite's program could not list its tests.",
                context: ["program": program.path, "exit": String(code)],
                suggestion: "Build the suite first: `stateui test --host web --build-only`."
            )
        }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("StateUIWebTests.") }
    }

    static func webTest(_ parsed: ParsedCommand) throws {
        guard parsed.positionals.count >= 2 else {
            throw ToolingError.invalidArguments("__web-test needs a relay and a program.")
        }
        let relay = FileSystem.expand(parsed.positionals[0])
        let program = FileSystem.expand(parsed.positionals[1])
        let package = relay.deletingLastPathComponent().deletingLastPathComponent()
        let runScript = package.appendingPathComponent("Testing/JavaScript/run.mjs")
        guard let node = FileSystem.findExecutable("node") else {
            throw ToolingError.toolchainMissing("Node.js was not found.", suggestion: "Install Node.js 20 or newer.")
        }
        guard FileSystem.exists(runScript) else {
            throw ToolingError.toolchainMissing("The Web test runner is missing: \(runScript.path).")
        }

        // A class named alone runs that alone; nothing named runs every class the browser
        // does not, since those need a page a browser draws.
        var selected = parsed.positionals.count > 2 ? parsed.positionals[2] : ""
        if !selected.isEmpty && !selected.hasPrefix("StateUIWebTests.") {
            selected = "StateUIWebTests.\(selected)"
        }
        if selected.isEmpty {
            let held = Set([webConformanceClass] + webInBrowserClasses)
            selected = try listWebTests(node: node, runScript: runScript, relay: relay, program: program)
                .filter { test in
                    guard let slash = test.firstIndex(of: "/") else { return false }
                    return !held.contains(String(test[..<slash]))
                }
                .joined(separator: ",")
        }

        var arguments = [runScript.path, relay.path, program.path]
        if !selected.isEmpty { arguments.append(selected) }
        exit(try runAndWait(node, arguments, cwd: package))
    }

    /// The tests a browser's own page needs, in one, headless: every conformance family and the
    /// host's tests that run a host, each in a program of its own, the page loaded anew.
    static func webBrowserTest(_ parsed: ParsedCommand, environment: Environment) throws {
        guard parsed.positionals.count >= 2 else {
            throw ToolingError.invalidArguments("__web-browser-test needs a relay and a program.")
        }
        let relay = FileSystem.expand(parsed.positionals[0])
        let program = FileSystem.expand(parsed.positionals[1])
        let package = relay.deletingLastPathComponent().deletingLastPathComponent()
        let runScript = package.appendingPathComponent("Testing/JavaScript/run.mjs")
        let browserScript = package.appendingPathComponent("Testing/JavaScript/run-in-browser.mjs")
        guard let node = FileSystem.findExecutable("node") else {
            throw ToolingError.toolchainMissing("Node.js was not found.", suggestion: "Install Node.js 20 or newer.")
        }
        guard FileSystem.exists(runScript), FileSystem.exists(browserScript) else {
            throw ToolingError.toolchainMissing(
                "The Web suite's browser runner is missing.",
                context: ["run.mjs": runScript.path, "run-in-browser.mjs": browserScript.path]
            )
        }

        let rest = Array(parsed.positionals.dropFirst(2))
        let selected: [String]
        if rest.first == "--host" {
            // The host's own tests that run a host, and no conformance family.
            selected = webInBrowserClasses
        } else if !rest.isEmpty {
            // A family named - Button, TextField - runs its conformance alone.
            selected = rest.flatMap { $0.split(separator: ",").map { "\(webConformanceClass)/test\($0)" } }
        } else {
            let families = try listWebTests(node: node, runScript: runScript, relay: relay, program: program)
                .filter { $0.hasPrefix("\(webConformanceClass)/") }
            selected = families + webInBrowserClasses
        }

        let browser = try webBrowser(environment)
        exit(try runAndWait(
            node, [browserScript.path, browser.path, program.path, selected.joined(separator: ",")],
            cwd: package
        ))
    }

    /// Google Chrome or Chromium, or the one `STATEUI_BROWSER` names.
    private static func webBrowser(_ environment: Environment) throws -> URL {
        if let named = environment["STATEUI_BROWSER"], !named.isEmpty {
            let url = FileSystem.expand(named)
            if FileSystem.isExecutable(url) { return url }
            throw ToolingError.browserNotFound(
                "STATEUI_BROWSER names no executable browser.",
                context: ["STATEUI_BROWSER": named],
                suggestion: "Point STATEUI_BROWSER at Google Chrome or Chromium."
            )
        }
        for candidate in [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ] {
            let url = URL(fileURLWithPath: candidate)
            if FileSystem.isExecutable(url) { return url }
        }
        for name in ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"] {
            if let found = FileSystem.findExecutable(name) { return found }
        }
        throw ToolingError.browserNotFound(
            "No Google Chrome or Chromium was found.",
            suggestion: "Install Chromium, or name a browser with STATEUI_BROWSER."
        )
    }

    static func androidLogcat(_ parsed: ParsedCommand) throws {
        guard parsed.positionals.count >= 3 else {
            throw ToolingError.invalidArguments("__android-logcat needs adb, a serial and a package.")
        }
        let adb = FileSystem.expand(parsed.positionals[0])
        let serial = parsed.positionals[1]
        let package = parsed.positionals[2]
        var pid = ""
        for _ in 0..<20 {
            let (code, output) = try runCapturing(adb, ["-s", serial, "shell", "pidof", package])
            if code == 0 {
                pid = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pid.isEmpty { break }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard !pid.isEmpty else {
            FileHandle.standardError.write(Data("stateui: \(package) did not start.\n".utf8))
            exit(1)
        }
        exit(try runAndWait(adb, ["-s", serial, "logcat", "-v", "color", "--pid=\(pid)"],
                            cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    }

    static func androidDebug(_ parsed: ParsedCommand) throws {
        guard parsed.positionals.count >= 6 else {
            throw ToolingError.invalidArguments("__android-debug needs adb, serial, package, ABI, NDK and facts.")
        }
        let adb = FileSystem.expand(parsed.positionals[0])
        let serial = parsed.positionals[1]
        let package = parsed.positionals[2]
        let abi = parsed.positionals[3]
        let ndk = FileSystem.expand(parsed.positionals[4])
        let facts = FileSystem.expand(parsed.positionals[5])
        let architecture: String
        switch abi {
        case "arm64-v8a": architecture = "aarch64"
        case "armeabi-v7a": architecture = "arm"
        case "x86": architecture = "i386"
        default: architecture = abi
        }
        guard let server = findLLDBServer(ndk: ndk, architecture: architecture) else {
            throw ToolingError.debuggerUnavailable("The NDK at \(ndk.path) has no lldb-server for \(abi).")
        }
        _ = try runAndWait(adb, ["-s", serial, "push", server.path, "/data/local/tmp/stateui-lldb-server"],
                           cwd: ndk)
        _ = try runAndWait(adb, ["-s", serial, "shell", "run-as", package, "pkill", "-x", "lldb-server"], cwd: ndk)
        _ = try runAndWait(adb, ["-s", serial, "shell", "run-as", package, "cp",
                                 "/data/local/tmp/stateui-lldb-server", "lldb-server.new"], cwd: ndk)
        _ = try runAndWait(adb, ["-s", serial, "shell", "run-as", package, "chmod", "700", "lldb-server.new"], cwd: ndk)
        _ = try runAndWait(adb, ["-s", serial, "shell", "run-as", package, "mv", "lldb-server.new", "lldb-server"], cwd: ndk)
        let socket = "\(package)/stateui-debugger.sock"
        try startDetached(adb, ["-s", serial, "shell", "run-as", package, "./lldb-server",
                                "platform", "--server", "--listen", "unix-abstract:///\(socket)"], cwd: ndk)
        var pid = ""
        for _ in 0..<20 {
            let (code, output) = try runCapturing(adb, ["-s", serial, "shell", "pidof", package])
            if code == 0 {
                pid = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pid.isEmpty { break }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let symbols = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/android/symbols/\(abi)")
        let payload: [String: Any] = [
            "serial": serial, "package": package, "process": Int(pid) ?? 0,
            "socket": socket, "symbols": symbols.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileSystem.write(data, to: facts)
        print("debugger: ready to attach - \(facts.path)")
    }

    /// Starts a UIKit bundle held for the debugger, reads the process the
    /// simulator or device reports, and writes where the debugger attaches.
    static func uikitDebug(_ parsed: ParsedCommand) throws {
        guard parsed.positionals.count >= 6 else {
            throw ToolingError.invalidArguments(
                "__uikit-debug needs xcrun, a destination kind, its id, the bundle identifier, the bundle and facts."
            )
        }
        let xcrun = FileSystem.expand(parsed.positionals[0])
        let kind = parsed.positionals[1]
        let destination = parsed.positionals[2]
        let identifier = parsed.positionals[3]
        let bundle = FileSystem.expand(parsed.positionals[4])
        let facts = FileSystem.expand(parsed.positionals[5])
        var payload: [String: Any]
        switch kind {
        case "device":
            let answer = FileManager.default.temporaryDirectory
                .appendingPathComponent("stateui-uikit-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: answer) }
            let (code, output) = try runCapturing(xcrun, [
                "devicectl", "device", "process", "launch", "--device", destination,
                "--terminate-existing", "--start-stopped", "--json-output", answer.path, identifier,
            ])
            guard code == 0 else {
                throw ToolingError.debuggerUnavailable(
                    "\(identifier) did not start on \(destination).",
                    context: ["output": output],
                    suggestion: "Check that the device is connected and the bundle is signed for it."
                )
            }
            guard let data = try? Data(contentsOf: answer),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = object["result"] as? [String: Any],
                  let process = result["process"] as? [String: Any],
                  let pid = process["processIdentifier"] as? Int else {
                throw ToolingError.debuggerUnavailable(
                    "devicectl did not report \(identifier)'s process.",
                    context: ["device": destination]
                )
            }
            payload = ["process": pid, "device": destination, "symbols": bundle.path]
        default:
            let (code, output) = try runCapturing(
                xcrun, ["simctl", "launch", "--wait-for-debugger", destination, identifier]
            )
            guard code == 0 else {
                throw ToolingError.debuggerUnavailable(
                    "\(identifier) did not start on \(destination).",
                    context: ["output": output]
                )
            }
            let reported = output.split(separator: ":").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let pid = Int(reported) else {
                throw ToolingError.debuggerUnavailable(
                    "simctl did not report \(identifier)'s process.",
                    context: ["output": output]
                )
            }
            payload = ["process": pid, "simulator": destination, "symbols": bundle.path]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileSystem.write(data, to: facts)
        print("debugger: ready to attach - \(facts.path)")
    }

    // MARK: - Helpers

    /// The host `--host` names, refused when it names none of StateUI's hosts.
    /// An option given explicitly is never dropped: a mistyped host is a mistake,
    /// not a request for the checkout's default.
    static func hostOption(_ parsed: ParsedCommand, default fallback: HostID? = nil) throws -> HostID? {
        guard let raw = parsed.value("host") else { return fallback }
        guard let host = HostID(parsing: raw) else {
            throw ToolingError.invalidArguments(
                "'\(raw)' is not a StateUI host.",
                context: ["host": raw],
                suggestion: "Use one of: \(HostID.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return host
    }

    /// The configuration `--configuration` names, refused when it names neither.
    static func configurationOption(_ parsed: ParsedCommand) throws -> BuildConfiguration? {
        guard let raw = parsed.value("configuration") else { return nil }
        guard let configuration = BuildConfiguration(parsing: raw) else {
            throw ToolingError.invalidArguments(
                "'\(raw)' is not a configuration.",
                context: ["configuration": raw],
                suggestion: "Use debug or release."
            )
        }
        return configuration
    }

    /// The host `--device-host` names, refused when it names none.
    static func deviceHostOption(_ parsed: ParsedCommand) throws -> HostID? {
        guard let raw = parsed.value("device-host") else { return nil }
        guard let host = HostID(parsing: raw) else {
            throw ToolingError.invalidArguments(
                "'\(raw)' is not a StateUI host.",
                context: ["device-host": raw],
                suggestion: "Use one of: \(HostID.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return host
    }

    static func configuration(_ tooling: Tooling, _ parsed: ParsedCommand) throws -> BuildConfiguration {
        if let configuration = try configurationOption(parsed) {
            return configuration
        }
        let project = try tooling.project(explicit: parsed.value("project").map { FileSystem.expand($0) })
        return try tooling.loadConfiguration(project).configuration ?? .debug
    }

    static func logLevel(_ parsed: ParsedCommand) -> LogLevel {
        if parsed.flag("quiet") { return .quiet }
        if parsed.flag("verbose") { return .debug }
        return .info
    }

    static func emit<T: Encodable>(_ value: T, json: Bool, human: String? = nil) {
        if json {
            if let text = try? JSON.encode(value, pretty: true) { print(text) }
        } else if let human {
            print(human)
        } else if let text = try? JSON.encode(value, pretty: true) {
            print(text)
        }
    }

    static func emitOutcome(_ outcome: ExecutionOutcome, json: Bool) {
        if json {
            emit(outcome, json: true)
        } else {
            print("status: \(outcome.status.rawValue)")
            if outcome.duration > 0 { print(String(format: "duration: %.2fs", outcome.duration)) }
            for output in outcome.outputs { print("output: \(output.path)") }
            if let facts = outcome.factsFile { print("facts: \(facts.path)") }
            if let url = outcome.url { print("url: \(url)") }
            for note in outcome.notes { print("note: \(note)") }
        }
    }

    static func describe(_ plan: BuildPlan) -> String {
        var lines = ["build \(plan.application) for \(plan.host.label) (\(plan.configuration.rawValue))"]
        for step in plan.steps { lines.append("  step: \(step.label): \(step.displayCommand)") }
        for action in plan.actions { lines.append("  file: \(action.summary)") }
        for step in plan.postSteps { lines.append("  after: \(step.label): \(step.displayCommand)") }
        for output in plan.outputs { lines.append("  output: \(output.path)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: TestPlan) -> String {
        var lines = ["test \(plan.application ?? "the host") for \(plan.host.label)"]
        for suite in plan.suites {
            lines.append("  suite: \(suite.name) - \(suite.detail)")
            for step in suite.steps { lines.append("    step: \(step.displayCommand)") }
            for action in suite.actions { lines.append("    file: \(action.summary)") }
            for step in suite.postSteps { lines.append("    after: \(step.displayCommand)") }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: RunPlan) -> String {
        var lines = ["run \(plan.application) for \(plan.host.label) (\(plan.configuration.rawValue))"]
        for step in plan.steps { lines.append("  step: \(step.label): \(step.displayCommand)") }
        if let url = plan.url { lines.append("  url: \(url)") }
        for note in plan.notes { lines.append("  note: \(note)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: SizePlan) -> String {
        var lines = ["weigh \(plan.host.label) modules (\(plan.configuration.rawValue))"]
        for entry in plan.budgets {
            lines.append("  app: \(entry.application), budget \(entry.budget) bytes gzipped")
            lines.append("  module: \(entry.module.path)")
            for step in entry.build.steps { lines.append("    step: \(step.label): \(step.displayCommand)") }
            for action in entry.build.actions { lines.append("    file: \(action.summary)") }
            for step in entry.build.postSteps { lines.append("    after: \(step.label): \(step.displayCommand)") }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: DeployPlan) -> String {
        var lines = ["deploy \(plan.application) for \(plan.host.label) to \(plan.destination.path)"]
        for action in plan.actions { lines.append("  file: \(action.summary)") }
        for step in plan.postSteps { lines.append("  after: \(step.displayCommand)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ plan: DebugPlan) -> String {
        var lines = ["debug \(plan.application) for \(plan.host.label) (\(plan.request.rawValue), \(plan.adapter.rawValue))"]
        if let program = plan.program { lines.append("  program: \(program)") }
        if let url = plan.url { lines.append("  url: \(url)") }
        for command in plan.initCommands { lines.append("  init: \(command)") }
        for command in plan.attachCommands { lines.append("  attach: \(command)") }
        if let build = plan.build {
            for step in build.steps { lines.append("  build: \(step.label): \(step.displayCommand)") }
            for action in build.actions { lines.append("  build file: \(action.summary)") }
            for step in build.postSteps { lines.append("  build after: \(step.label): \(step.displayCommand)") }
        }
        for step in plan.preLaunch { lines.append("  before: \(step.displayCommand)") }
        if let facts = plan.factsFile { lines.append("  facts: \(facts.path)") }
        for note in plan.notes { lines.append("  note: \(note)") }
        return lines.joined(separator: "\n")
    }

    static func versionResult() -> [String: JSONValue] {
        [
            "name": .string("stateui"),
            "version": .string(ToolingVersion.version),
            "protocolVersion": .int(ToolingVersion.protocolVersion),
        ]
    }

    static func exitCode(for error: ToolingError) -> Int32 {
        switch error.code {
        case "invalidArguments", "invalidConfiguration": return 2
        default: return 1
        }
    }

    static func runAndWait(_ executable: URL, _ arguments: [String], cwd: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func runCapturing(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func startDetached(_ executable: URL, _ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func findLLDBServer(ndk: URL, architecture: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: ndk, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == "lldb-server" && url.path.contains("/lib/linux/\(architecture)/") {
            return url
        }
        return nil
    }

    /// Bridges a blocking hidden command to the async discovery it needs.
    static func awaitBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    static let help = """
    stateui \(ToolingVersion.version) - StateUI's developer tool

    USAGE:
      stateui <command> [options]

    COMMANDS:
      version                    Print the tool and protocol versions.
      doctor [--host H]          Check the toolchain.
      project|info               Describe the current project.
      apps [list|info NAME]      List applications, or describe one.
      config [get|list|set]      Show or change the checkout's host, application and configuration.
      hosts [list|info H]        List hosts and their availability, or describe one.
      host [list|get|set H]      Show or select the default host.
      devices --host H           List a host's devices.
      browsers                   List the Web host's browsers.
      build [options]            Build an application.
      test [options]             Run a host's tests.
      run [options]              Build and run an application.
      deploy [options]           Build and lay an application out.
      stop [--host web]          Give up the page a Web run left serving.
      size budgets --host web    Weigh each Web module against its budget.
      new NAME                   Create an application from HelloWorld.
      group releases [--minimum V]  List the releases a checkout's remote offers.
      group create NAME [release...]  Lay out a folder holding one application per release.
      lsp environment|configure  Report or build the host-scoped SourceKit index.
      lsp clean [--host H|--all] Remove an index, so the host indexes again.
      debug plan|prepare         Print or prepare a debug plan.
      rpc --stdio                Speak JSON-RPC 2.0 over stdio.

    OPTIONS:
      --application NAME  --host H  --configuration debug|release
      --device ID         --device-host H  --browser ID  --port N
      --project PATH      --destination PATH  --architecture ARCH  --apps-dir PATH
      --checkout PATH     --minimum V  --suite native|foundation|host  --filter NAMES
      --in-browser  --build-only  --update-exports  --stale
      --dry-run  --detach  --prepare  --no-build  --json  --quiet  --verbose
    """
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
