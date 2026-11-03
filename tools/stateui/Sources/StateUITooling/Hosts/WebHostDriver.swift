// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Web host: a WebAssembly module in a page, served natively and opened in
/// a browser.
public struct WebHostDriver: HostDriver {
    public let id = HostID.web
    public let capabilities = HostCapabilities(devices: false, browsers: true)

    let runner: CommandRunner
    let environment: Environment
    let platform: Platform

    public init(runner: CommandRunner, environment: Environment = .current, platform: Platform = .current) {
        self.runner = runner
        self.environment = environment
        self.platform = platform
    }

    private var swiftBuilder: SwiftBuilder {
        SwiftBuilder(runner: runner, environment: environment, platform: platform)
    }

    public func availability(_ context: ProjectContext) async -> HostAvailability {
        guard platform.operatingSystem == .macOS || platform.operatingSystem == .linux else {
            return HostSupport.availability(id, platform: platform, toolchainReady: false)
        }
        guard await swiftBuilder.swiftSDKID(family: "wasm") != nil else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "No Swift SDK for WebAssembly of the toolchain's release is installed. Run `swift sdk install`."
            )
        }
        return HostSupport.availability(id, platform: platform, toolchainReady: true)
    }

    public func browsers(_ context: ProjectContext) async throws -> [Browser] {
        await BrowserDiscovery(runner: runner, environment: environment, platform: platform).browsers()
    }

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let application = try HostSupport.application(context)
        let checkout = try HostSupport.checkout(context)
        guard let sdk = await swiftBuilder.swiftSDKID(family: "wasm") else {
            throw ToolingError.toolchainMissing(
                "No Swift SDK for WebAssembly of the toolchain's release is installed.",
                suggestion: "Install it with `swift sdk install`, then run `stateui doctor --host web`."
            )
        }
        let step = try swiftBuilder.buildInvocation(
            application: application, host: id, configuration: request.configuration,
            swiftSDK: sdk, triple: HostCompilation.webTriple, extra: request.extraArguments
        )
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: request.configuration,
            swiftSDK: sdk, triple: HostCompilation.webTriple
        )
        let site = siteURL(application, configuration: request.configuration)
        let actions = try WebPageLayout.actions(
            application: application, checkout: checkout, products: bin, site: site
        )
        return BuildPlan(
            application: application.name, host: id, configuration: request.configuration,
            steps: [step], actions: actions, outputs: [site],
            notes: [
                "STATEUI_HOST=web compiles the application and the host into one module.",
                "The page is laid out at \(site.path): index.html, the relay, the module and the pictures.",
            ]
        )
    }

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let site = siteURL(application, configuration: request.configuration)
        let port = request.port ?? 8460
        let facts = application.buildDirectory(for: id).appendingPathComponent("server.json")
        let log = application.buildDirectory(for: id).appendingPathComponent("run.log")
        let browser = request.browser ?? "default"
        let query = WebPageLayout.query(context.environment)
        var arguments = [
            "__serve-web", site.path, "\(port)", facts.path, browser,
        ]
        if !query.isEmpty { arguments.append(query) }
        let step = HostSupport.run(
            HostSupport.currentExecutable(environment: environment), arguments,
            cwd: application.directory, label: "Serve \(application.name)'s page on port \(port)",
            environment: context.environment.stateuiVariables, mode: .background
        )
        return RunPlan(
            application: application.name, host: id, configuration: request.configuration,
            build: request.noBuild ? nil : build, steps: [step], detached: request.detach,
            factsFile: facts, url: "http://localhost:\(port)/", logFile: log,
            notes: [
                "The page is served on every interface; server.json says where.",
                "STATEUI_ variables reach the application as query parameters.",
            ]
        )
    }

    public func deployPlan(
        _ request: DeployRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DeployPlan {
        let application = try HostSupport.application(context)
        guard let destination = request.destination else {
            throw ToolingError.deploymentFailed("No destination was resolved for \(application.name).")
        }
        let release = try await buildPlan(
            BuildRequest(application: application.name, host: id, configuration: .release), context: context
        )
        let site = siteURL(application, configuration: .release)
        return DeployPlan(
            application: application.name, host: id, configuration: .release,
            build: build ?? release,
            actions: [
                .remove(destination),
                .createDirectory(destination),
                .copyTree(site, to: destination),
            ],
            destination: destination,
            notes: ["The destination is a folder any web server serves as it is."]
        )
    }

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let site = siteURL(application, configuration: request.configuration)
        let port = 8460
        var browser: Browser?
        if let id = request.browser {
            browser = await BrowserDiscovery(runner: runner, environment: environment, platform: platform).browser(id: id)
        }
        let chromium = browser.map { $0.isChromium } ?? true
        let facts = application.buildDirectory(for: id).appendingPathComponent("server.json")
        let serve = HostSupport.run(
            HostSupport.currentExecutable(environment: environment),
            ["__serve-web", site.path, "\(port)", facts.path, "none"],
            cwd: application.directory, label: "Serve \(application.name)'s page",
            environment: context.environment.stateuiVariables, mode: .background
        )
        return DebugPlan(
            adapter: .chrome, request: .launch, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (Web)",
            environment: ["STATEUI_HOST": id.rawValue],
            url: "http://localhost:\(port)/",
            runtimeExecutable: chromium ? browser?.executable : nil,
            webRoot: site.path,
            build: build, preLaunch: [serve], factsFile: facts,
            notes: [
                chromium
                    ? "The page is followed by a Chromium DevTools debugger."
                    : "\(browser?.name ?? "This browser") has no DevTools protocol the debugger can follow; the page opens without a session.",
                "server.json says where the page is served.",
            ]
        )
    }

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        guard let sdk = await swiftBuilder.swiftSDKID(family: "wasm") else {
            throw ToolingError.toolchainMissing("No Swift SDK for WebAssembly of the toolchain's release is installed.")
        }
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.Web/Testing", isDirectory: true)
        guard FileSystem.isDirectory(package) else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        let scratch = package.appendingPathComponent(".build/web", isDirectory: true)
        var arguments = [
            "build", "--package-path", package.path, "--scratch-path", scratch.path,
            "--swift-sdk", sdk, "--build-tests",
        ]
        let build = ProcessInvocation(
            executable: try swiftBuilder.swift(), arguments: arguments,
            environment: ["STATEUI_HOST": id.rawValue],
            workingDirectory: package, label: "Build the Web host's tests for WebAssembly"
        )
        arguments.append("--show-bin-path")
        let bin: URL
        if let output = await runner.output(
            build.executable, arguments, workingDirectory: package,
            environment: ["STATEUI_HOST": id.rawValue], label: "Web tests --show-bin-path"
        ), let line = output.split(whereSeparator: \.isNewline).map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            bin = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
        } else {
            bin = scratch.appendingPathComponent("debug", isDirectory: true)
        }
        let program = bin.appendingPathComponent("StateUIWebTests-test-runner.wasm")
        let relay = checkout.appendingPathComponent("lib/StateUI/StateUI.Web/JavaScript/stateui-web.js")
        guard runner.which("node") != nil else {
            throw ToolingError.toolchainMissing(
                "Node.js was not found; the Web host's tests run in it.",
                suggestion: "Install Node.js 20 or newer."
            )
        }
        var runArguments: [String]
        let detail: String
        if request.browser {
            // The tests a browser's own page needs: the conformance families and the
            // host's tests that run a host, each in a program of its own, the page loaded anew.
            runArguments = ["__web-browser-test", relay.path, program.path]
            if request.suite == "host" {
                runArguments.append("--host")
            } else if let families = request.filter {
                runArguments.append(families)
            }
            detail = request.suite == "host"
                ? "the host's own tests that run a host, in a headless browser, with no conformance family"
                : "every conformance family and the tests that need a browser's own page, each in a program of its own"
        } else {
            runArguments = ["__web-test", relay.path, program.path]
            if let filter = request.filter { runArguments.append(filter) }
            detail = "the Web host's package, compiled for WebAssembly and run in Node over its page"
        }
        let run = ProcessInvocation(
            executable: HostSupport.currentExecutable(environment: environment), arguments: runArguments,
            environment: request.conformanceEnvironment,
            workingDirectory: package, label: "Run the Web host's tests"
        )
        var steps: [ProcessInvocation] = [build]
        if !request.buildOnly { steps.append(run) }
        return TestPlan(
            application: context.application?.name, host: id,
            suites: [TestSuitePlan(
                name: "lib/StateUI/StateUI.Web/Testing",
                detail: request.buildOnly
                    ? "the suite is built for WebAssembly and not run, so another machine runs it"
                    : detail,
                steps: steps, host: id,
                outputs: request.buildOnly ? [program] : []
            )]
        )
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        let sdk = await swiftBuilder.swiftSDKID(family: "wasm")
        return LSPEnvironment(
            host: id, environment: ["STATEUI_HOST": id.rawValue],
            scratchPath: id.indexDirectory, swiftSDK: sdk, triple: HostCompilation.webTriple,
            notes: sdk == nil
                ? ["No Swift SDK for WebAssembly is installed; the editor compiles for this machine."]
                : []
        )
    }

    private func siteURL(_ application: Application, configuration: BuildConfiguration) -> URL {
        application.buildDirectory(for: id)
            .appendingPathComponent("site", isDirectory: true)
            .appendingPathComponent(configuration.rawValue, isDirectory: true)
    }
}
