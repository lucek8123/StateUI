// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// WinUI 3 on Windows: a Swift executable, the Windows App SDK laid beside it.
///
/// Every step of the layout belongs to the repository's own WinUI tool, run as a
/// Swift script (`tools/stateui/Support/winui-tools.swift`): the packages fetched
/// where the cache holds none, the C++/WinRT projection the relay includes, the
/// directory made self-contained, the C++ runtime Visual Studio's redistributable
/// holds. The pins travel to it as arguments, so no version stands twice.
///
/// The Swift runtime is laid by nothing here: Windows keeps it in the installer's
/// merge modules, which only `msi.dll` reads. A head runs with the runtime of the
/// toolchain that built it - docs/design/platforms/winui/runtime.md#another-architecture.
public struct WinUIHostDriver: HostDriver {
    public let id = HostID.winUI
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
        guard platform.operatingSystem == .windows else {
            return HostSupport.availability(id, platform: platform, toolchainReady: false)
        }
        guard (try? swiftBuilder.swift()) != nil else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "Swift was not found. Install Swift 6.4 for Windows."
            )
        }
        // The projection, the packages and the runtime are laid by the build itself.
        return HostSupport.availability(id, platform: platform, toolchainReady: true)
    }

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let checkout = try HostSupport.checkout(context)
        let application = try HostSupport.application(context)
        let configuration = request.configuration
        let architecture = Self.architecture(request.architecture, platform: platform)
        let product = application.product(for: id)
        let swift = try swiftBuilder.swift()

        var extra = request.extraArguments
        if let architecture = request.architecture, let mapped = Self.swiftArchitecture(architecture) {
            extra.append(contentsOf: ["--arch", mapped])
        }
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: configuration)
        let executable = bin.appendingPathComponent("\(product).exe")

        var steps: [ProcessInvocation] = []
        // A running head holds its executable, which the build writes again: it stops first.
        if let taskkill = FileSystem.findExecutable("taskkill", environment: environment) {
            steps.append(HostSupport.run(
                taskkill, ["/IM", "\(product).exe", "/F"], cwd: application.directory,
                label: "Stop a running \(product)", allowFailure: true
            ))
        }
        if let script = tools(in: checkout) {
            steps.append(contentsOf: toolSteps(
                swift: swift, script: script, "projection",
                ["--projection", projection(of: checkout).path],
                packages: WinUIPackages.projection, cwd: checkout,
                label: "Generate the C++/WinRT projection"
            ))
        }
        steps.append(try swiftBuilder.buildInvocation(
            application: application, host: id, configuration: configuration, extra: extra
        ))

        var actions: [FileAction] = []
        let images = HostSupport.images(application)
        if FileSystem.isDirectory(images) {
            actions.append(.createDirectory(bin.appendingPathComponent("Images", isDirectory: true)))
            actions.append(.copyTree(images, to: bin.appendingPathComponent("Images", isDirectory: true)))
        }

        var postSteps: [ProcessInvocation] = []
        if let script = tools(in: checkout) {
            postSteps.append(contentsOf: toolSteps(
                swift: swift, script: script, "self-contained",
                ["--directory", bin.path, "--executable", executable.path,
                 "--architecture", architecture, "--repository", checkout.path],
                packages: WinUIPackages.laying, cwd: checkout,
                label: "Lay the Windows App SDK beside \(product)"
            ))
        }

        return BuildPlan(
            application: application.name,
            host: id,
            configuration: configuration,
            steps: steps,
            actions: actions,
            postSteps: postSteps,
            outputs: [executable],
            notes: [
                "STATEUI_HOST=winui makes the manifest declare the WinUI head.",
                "The Windows App SDK's runtime, the manifest registering the WinRT classes it declares, and resources.pri are laid beside the head; a package the cache holds nowhere is fetched from nuget.org.",
                "A running head is stopped first: the build writes its executable again.",
                "The Swift runtime is the toolchain's own, found on the search path; stateui lays no runtime of another architecture - see docs/design/platforms/winui/runtime.md#another-architecture.",
            ]
        )
    }

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: request.configuration)
        let executable = bin.appendingPathComponent("\(application.product(for: id)).exe")
        let log = application.buildDirectory(for: id).appendingPathComponent("run.log")
        let step = HostSupport.run(
            executable, [], cwd: bin, label: "Run \(application.product(for: id))",
            environment: context.environment.stateuiVariables,
            mode: request.detach ? .background : .observe
        )
        return RunPlan(
            application: application.name, host: id, configuration: request.configuration,
            build: request.noBuild ? nil : build, steps: [step], detached: request.detach,
            logFile: log,
            notes: ["The Windows App SDK stands beside the head, where Windows finds it next to the executable."]
        )
    }

    public func deployPlan(
        _ request: DeployRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DeployPlan {
        let checkout = try HostSupport.checkout(context)
        let application = try HostSupport.application(context)
        guard let destination = request.destination else {
            throw ToolingError.deploymentFailed("No destination was resolved for \(application.name).")
        }
        let architecture = Self.architecture(request.architecture, platform: platform)
        let release = try await buildPlan(
            BuildRequest(
                application: application.name, host: id, configuration: .release,
                architecture: request.architecture
            ), context: context
        )
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: .release)

        var postSteps: [ProcessInvocation] = []
        // The destination runs on a machine with nothing installed: the C++ runtime
        // comes from Visual Studio's redistributable and is laid there explicitly.
        if let script = tools(in: checkout) {
            postSteps.append(contentsOf: toolSteps(
                swift: try swiftBuilder.swift(), script: script, "cpp-runtime",
                ["--directory", destination.path, "--architecture", architecture],
                packages: [], cwd: checkout, label: "Lay the C++ runtime for \(architecture)"
            ))
        }

        return DeployPlan(
            application: application.name, host: id, configuration: .release,
            build: build ?? release,
            actions: [
                .remove(destination),
                .createDirectory(destination),
                .copyTree(
                    bin, to: destination,
                    excluding: [".objlib", ".swiftmodule", ".lib", ".exp", ".ilk", ".pdb", "plutil.exe"]
                ),
            ],
            postSteps: postSteps,
            destination: destination,
            notes: [
                "The destination holds the head and the Windows App SDK runtime it runs with.",
                "What only a build reads - modules, import libraries, object libraries - stays behind.",
                "The Swift runtime is not laid: the deployed folder needs the toolchain that built the head on its search path - see docs/design/platforms/winui/runtime.md#another-architecture.",
            ]
        )
    }

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: request.configuration)
        let executable = bin.appendingPathComponent("\(application.product(for: id)).exe")
        return DebugPlan(
            adapter: .lldbDAP, request: .launch, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (WinUI)",
            program: executable.path, workingDirectory: bin,
            environment: ["STATEUI_HOST": id.rawValue],
            build: build,
            notes: ["lldb-dap reads the DWARF the head carries."]
        )
    }

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        let builder = swiftBuilder
        let swift = try builder.swift()
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.WinUI/Testing", isDirectory: true)
        guard FileSystem.isDirectory(package) else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        let architecture = Self.architecture(nil, platform: platform)
        let marks = TestSession(request: request, context: context)
            .environment()
            .merging(["STATEUI_HOST": id.rawValue]) { _, new in new }

        var suites: [TestSuitePlan] = []
        // The foundation's own tests on Windows - its C library and its thread
        // numbers, the branches no other machine runs - before the host's.
        if request.filter == nil && !request.staleOnly && !request.conformance {
            suites.append(try NativeTestSuites.foundation(builder: builder, checkout: checkout, platform: platform))
        }

        var steps: [ProcessInvocation] = []
        if let script = tools(in: checkout) {
            steps.append(contentsOf: toolSteps(
                swift: swift, script: script, "projection",
                ["--projection", projection(of: checkout).path],
                packages: WinUIPackages.projection, cwd: checkout,
                label: "Generate the C++/WinRT projection"
            ))
        }
        let scratch = package.appendingPathComponent(".build/winui", isDirectory: true)
        var buildArguments = ["build", "--package-path", package.path, "--build-tests"]
        buildArguments.append(contentsOf: ["--scratch-path", scratch.path])
        let build = ProcessInvocation(
            executable: swift, arguments: buildArguments, environment: marks,
            workingDirectory: package, label: "Build the WinUI host's tests"
        )
        steps.append(build)
        let bin = await builder.binPath(
            application: Application(
                name: "StateUIWinUITests", directory: package,
                manifest: package.appendingPathComponent("Package.swift"),
                heads: [], checkout: checkout, bundleScript: nil
            ),
            host: id, configuration: .debug, scratch: scratch
        )

        // Each test runs in a process of its own, as WinUI keeps GDI objects of
        // every window; the conformance families are WinUI's column of the
        // dictionary: some fifteen minutes, so they run only on request.
        var postSteps: [ProcessInvocation] = []
        if let script = tools(in: checkout) {
            postSteps.append(contentsOf: toolSteps(
                swift: swift, script: script, "self-contained",
                ["--directory", bin.path,
                 "--executable", bin.appendingPathComponent("StateUIWinUITests-test-runner.exe").path,
                 "--architecture", architecture, "--repository", checkout.path],
                packages: WinUIPackages.laying, cwd: checkout,
                label: "Lay the Windows App SDK beside the test runner"
            ))
        }
        let narrowing: [String]
        if let filter = request.conformanceFilter(for: id) ?? request.filter {
            narrowing = ["--filter", filter, "--parallel", "--num-workers", "1"]
        } else if request.staleOnly || request.updateExports {
            narrowing = ["--filter", id.conformanceClass, "--parallel", "--num-workers", "1"]
        } else {
            narrowing = ["--skip", id.conformanceClass, "--parallel", "--num-workers", "1"]
        }
        postSteps.append(ProcessInvocation(
            executable: swift,
            arguments: [
                "test", "--package-path", package.path, "--skip-build",
                "--scratch-path", scratch.path,
            ] + narrowing,
            environment: marks, workingDirectory: package,
            label: "Test the WinUI host", captureOutput: false
        ))

        let maps = [
            "-Xcc", "-fmodule-map-file=\(checkout.path)/lib/StateUI/StateUI.WinUI/Sources/CStateUIWinUI/include/module.modulemap",
            "-Xcc", "-fmodule-map-file=\(checkout.path)/lib/Backends/WebView.WinUI/Relay/include/module.modulemap",
            "-Xcc", "-fmodule-map-file=\(checkout.path)/lib/StateUI/StateUI.Host/CStateUIHost/module.modulemap",
        ]
        suites.append(TestSuitePlan(
            name: "lib/StateUI/StateUI.WinUI/Testing",
            detail: request.conformance
                ? "the WinUI host's conformance families, each verdict held to its marks"
                : request.staleOnly
                    ? "only the conformance families whose verdicts stand at another revision"
                    : "the host's own tests; add --conformance, --stale or a filter to reach the conformance families",
            steps: steps, postSteps: postSteps, host: id,
            checks: [.apiRecord([
                APIModule(name: "StateUIWinUI", modules: bin, arguments: maps),
                APIModule(name: "StateUIWebViewWinUI", modules: bin, arguments: maps),
            ])]
        ))
        return TestPlan(application: context.application?.name, host: id, suites: suites)
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        LSPEnvironment(host: id, environment: ["STATEUI_HOST": id.rawValue], scratchPath: id.indexDirectory)
    }

    /// The repository's WinUI tool, as a Swift script: nil where the checkout
    /// holds none, in which case nothing lays the SDK and only the build runs.
    private func tools(in checkout: URL) -> URL? {
        let script = checkout.appendingPathComponent("tools/stateui/Support/winui-tools.swift")
        return FileSystem.exists(script) ? script : nil
    }

    /// The host's C++/WinRT projection, which the relay includes.
    private func projection(of checkout: URL) -> URL {
        checkout.appendingPathComponent("lib/StateUI/StateUI.WinUI/.projection", isDirectory: true)
    }

    /// The steps that run one subcommand of the WinUI tool. Swift runs the
    /// script where its interpreter mode works; on Windows, where it does not,
    /// the script is compiled once and the executable runs instead. The pins,
    /// and the package cache the tool reads, travel to it as arguments.
    private func toolSteps(
        swift: URL, script: URL, _ subcommand: String, _ arguments: [String],
        packages: [(id: String, version: String)], cwd: URL, label: String
    ) -> [ProcessInvocation] {
        var toolArguments = [subcommand] + arguments
        if !packages.isEmpty {
            toolArguments += ["--nuget", WinUIPackages.root(environment: environment).path]
        }
        toolArguments += WinUIPackages.arguments(packages)

        #if os(Windows)
        // Swift's interpreter mode is not supported on Windows; compile the
        // tool and run the executable it makes. The tool needs the Swift
        // runtime of the toolchain that compiled it on its search path.
        let swiftc = swift.deletingLastPathComponent().appendingPathComponent("swiftc.exe")
        let tool = FileManager.default.temporaryDirectory
            .appendingPathComponent("stateui-winui-tools.exe")
        let compile = HostSupport.run(
            swiftc, ["-O", "-static", "-o", tool.path, script.path],
            cwd: cwd, label: "Build the WinUI tool"
        )
        let toolchain = swift.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let version = toolchain.lastPathComponent
            .split(separator: "+").first.map(String.init) ?? toolchain.lastPathComponent
        let runtime = toolchain.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Runtimes/\(version)/usr/bin", isDirectory: true)
        var runEnvironment: [String: String] = [:]
        if FileSystem.isDirectory(runtime) {
            let path = environment["PATH"] ?? ""
            runEnvironment["PATH"] = path.isEmpty ? runtime.path : "\(runtime.path);\(path)"
        }
        return [
            compile,
            HostSupport.run(
                tool, toolArguments, cwd: cwd, label: label, environment: runEnvironment
            ),
        ]
        #else
        return [HostSupport.run(
            swift, [script.path] + toolArguments, cwd: cwd, label: label
        )]
        #endif
    }

    static func architecture(_ requested: String?, platform: Platform) -> String {
        if let requested, ["arm64", "x64"].contains(requested) { return requested }
        return platform.architecture == .arm64 ? "arm64" : "x64"
    }

    static func swiftArchitecture(_ requested: String) -> String? {
        switch requested {
        case "x64": return "x86_64"
        case "arm64": return "aarch64"
        default: return nil
        }
    }
}
