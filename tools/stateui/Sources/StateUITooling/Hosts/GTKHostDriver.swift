// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// GTK 4 with libadwaita on Linux: a Swift executable run in its own process.
public struct GTKHostDriver: HostDriver {
    public let id = HostID.gtk
    public let capabilities = HostCapabilities()

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
        guard platform.operatingSystem == .linux else {
            return HostSupport.availability(id, platform: platform, toolchainReady: false)
        }
        guard let pkgConfig = runner.which("pkg-config") else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "pkg-config was not found. Install pkg-config, GTK 4 and libadwaita."
            )
        }
        guard await runner.output(pkgConfig, ["--exists", "gtk4"], label: "pkg-config gtk4") != nil else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "GTK 4's development files were not found. Install libgtk-4-dev or gtk4."
            )
        }
        return HostSupport.availability(id, platform: platform, toolchainReady: true)
    }

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let application = try HostSupport.application(context)
        let configuration = request.configuration
        let builder = swiftBuilder
        let step = try builder.buildInvocation(
            application: application, host: id, configuration: configuration,
            extra: request.extraArguments
        )
        let bin = await builder.binPath(application: application, host: id, configuration: configuration)
        let executable = bin.appendingPathComponent(application.product(for: id))
        var steps: [ProcessInvocation] = []
        // The executable is written again; a running copy goes first, found by its path.
        if let pkill = FileSystem.findExecutable("pkill", environment: environment) {
            steps.append(HostSupport.run(
                pkill, ["-f", "^\(executable.path)( |$)"], cwd: application.directory,
                label: "Stop a running \(application.product(for: id))", allowFailure: true
            ))
        }
        steps.append(step)
        var actions: [FileAction] = []
        let images = HostSupport.images(application)
        if FileSystem.isDirectory(images) {
            actions.append(.createDirectory(bin.appendingPathComponent("Images", isDirectory: true)))
            actions.append(.copyTree(images, to: bin.appendingPathComponent("Images", isDirectory: true)))
        }
        actions.append(
            contentsOf: GTKDesktop.install(application: application, executable: executable, environment: environment)
        )
        return BuildPlan(
            application: application.name,
            host: id,
            configuration: configuration,
            steps: steps,
            actions: actions,
            outputs: [executable],
            notes: [
                "STATEUI_HOST=gtk makes the manifest declare the GTK head.",
                "The executable reads Resources/Images beside it.",
                "A running copy is stopped first: the build writes its executable again.",
                "The icon and the desktop entry that starts this build are installed for the user.",
            ]
        )
    }

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        let builder = swiftBuilder
        let swift = try builder.swift()
        let marks = TestSession(request: request, context: context)
            .environment()
            .merging(["STATEUI_HOST": id.rawValue]) { _, new in new }
        let effectiveFilter = request.conformanceFilter(for: id) ?? request.filter

        var suites: [TestSuitePlan] = []
        // The foundation's own tests on Linux - its C library and its thread
        // numbers, the Glibc branches no other machine runs - before the host's.
        if effectiveFilter == nil {
            suites.append(try NativeTestSuites.foundation(builder: builder, checkout: checkout, platform: platform))
        }
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.GTK/Testing", isDirectory: true)
        if FileSystem.isDirectory(package) {
            var arguments = ["test", "--package-path", package.path]
            if let filter = effectiveFilter { arguments.append(contentsOf: ["--filter", filter]) }
            suites.append(TestSuitePlan(
                name: "lib/StateUI/StateUI.GTK/Testing",
                detail: request.conformance && !request.updateExports
                    ? "the GTK host's conformance families, each verdict held to its marks"
                    : "the GTK host's own tests and every conformance family, each verdict held to its marks",
                steps: [HostSupport.run(
                    swift, arguments, cwd: package, label: "Test the GTK host",
                    environment: marks
                )],
                checks: await apiRecordCheck(checkout: checkout, package: package).map { [$0] } ?? []
            ))
        }
        return TestPlan(application: context.application?.name, host: id, suites: suites)
    }

    /// The facade and the web view's backend, as the test build made them, held to their API records - with the
    /// maps and pkg-config flags that find their C modules.
    private func apiRecordCheck(checkout: URL, package: URL) async -> TestCheck? {
        let application = Application(
            name: "StateUIGTK", directory: package, manifest: package.appendingPathComponent("Package.swift"),
            heads: [], checkout: checkout, bundleScript: nil
        )
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: .debug,
            scratch: package.appendingPathComponent(".build", isDirectory: true)
        )
        var arguments: [String] = []
        for map in [
            "StateUI/StateUI.GTK/Sources/CStateUIGTK",
            "StateUI/StateUI.GTK/Sources/CStateUISoup",
            "StateUI/StateUI.Host/CStateUIHost",
            "Backends/WebView.GTK/Sources/CWebKitGTK",
        ] {
            arguments.append(contentsOf: [
                "-Xcc", "-fmodule-map-file=\(checkout.path)/lib/\(map)/module.modulemap",
            ])
        }
        if let pkgConfig = runner.which("pkg-config"),
           let flags = await runner.output(
               pkgConfig, ["--cflags", "libadwaita-1", "libsoup-3.0", "webkitgtk-6.0"],
               label: "pkg-config --cflags"
           ) {
            for flag in flags.split(whereSeparator: \.isWhitespace).map(String.init) where !flag.isEmpty {
                arguments.append(contentsOf: ["-Xcc", flag])
            }
        }
        return .apiRecord([
            APIModule(name: "StateUIGTK", modules: bin, arguments: arguments),
            APIModule(name: "StateUIWebViewGTK", modules: bin, arguments: arguments),
        ])
    }

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let configuration = request.configuration
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: configuration)
        let executable = bin.appendingPathComponent(application.product(for: id))
        let log = application.buildDirectory(for: id).appendingPathComponent("run.log")
        let step = HostSupport.run(
            executable, [], cwd: application.directory, label: "Run \(application.product(for: id))",
            environment: context.environment.stateuiVariables, mode: .observe
        )
        return RunPlan(
            application: application.name, host: id, configuration: configuration,
            build: request.noBuild ? nil : build, steps: [step],
            detached: request.detach, logFile: log,
            notes: ["A GTK application is one instance; a second launch brings the first forward."]
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
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: .release)
        let executable = bin.appendingPathComponent(application.product(for: id))
        var actions: [FileAction] = [
            .remove(destination),
            .createDirectory(destination),
            .copy(executable, to: destination.appendingPathComponent(executable.lastPathComponent)),
            .copyMatching(bin, matching: ".so", to: destination),
        ]
        let images = bin.appendingPathComponent("Images", isDirectory: true)
        if FileSystem.isDirectory(images) {
            actions.append(.copyTree(images, to: destination.appendingPathComponent("Images", isDirectory: true)))
        }
        return DeployPlan(
            application: application.name, host: id, configuration: .release,
            build: build ?? release, actions: actions, destination: destination,
            notes: ["The folder holds the head, the StateUI libraries it links, and its pictures."]
        )
    }

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: request.configuration)
        let executable = bin.appendingPathComponent(application.product(for: id))
        return DebugPlan(
            adapter: .lldbDAP, request: .launch, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (GTK)",
            program: executable.path, workingDirectory: application.directory,
            environment: ["STATEUI_HOST": id.rawValue],
            build: build,
            notes: ["The debugger is the application's parent, which Ubuntu's ptrace scope permits."]
        )
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        LSPEnvironment(host: id, environment: ["STATEUI_HOST": id.rawValue], scratchPath: id.indexDirectory)
    }
}
