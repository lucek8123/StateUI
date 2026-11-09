// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// AppKit on macOS: the head is wrapped in an application bundle, as a macOS
/// application is, and run in its own process.
public struct AppKitHostDriver: HostDriver {
    public let id = HostID.appKit
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
        guard platform.operatingSystem == .macOS else {
            return HostSupport.availability(id, platform: platform, toolchainReady: false)
        }
        guard (try? swiftBuilder.swift()) != nil else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "Swift was not found. Install Swift 6.4 (Xcode 27 or swift.org), or set SWIFT_BIN."
            )
        }
        return HostSupport.availability(id, platform: platform, toolchainReady: true)
    }

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let application = try HostSupport.application(context)
        let configuration = request.configuration
        let builder = swiftBuilder
        let product = application.product(for: id)
        let step = try builder.buildInvocation(
            application: application, host: id, configuration: configuration,
            extra: request.extraArguments
        )
        let bin = await builder.binPath(application: application, host: id, configuration: configuration)
        let executable = bin.appendingPathComponent(product)
        let bundle = bin.appendingPathComponent("\(product).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let iconWork = application.buildDirectory(for: id).appendingPathComponent("icon", isDirectory: true)
        let iconset = iconWork.appendingPathComponent("StateUI.iconset", isDirectory: true)
        let icns = iconWork.appendingPathComponent("StateUI.icns")
        let artwork = HostSupport.appIcon(application).appendingPathComponent("appicon_macos.svg")
        let iconSteps = AppleIcon.steps(
            source: artwork, iconset: iconset, output: icns,
            workingDirectory: application.directory, environment: environment
        )

        var actions: [FileAction] = [
            .remove(bundle),
            .createDirectory(macos),
            .createDirectory(resources.appendingPathComponent("Images", isDirectory: true)),
            .copy(executable, to: macos.appendingPathComponent(product)),
            .copyMatching(bin, matching: ".dylib", to: macos),
            // The bundle names the icon only when one was drawn: a bundle with no
            // custom icon is not a failure, and naming a file that is not there is.
            .write(HostSupport.infoPlist(
                executable: product,
                identifier: HostSupport.lowercaseIdentifier(application.name),
                name: application.name,
                minimumSystemVersion: "26.0",
                extra: iconSteps.isEmpty ? [:] : ["CFBundleIconFile": "StateUI.icns"]
            ), to: contents.appendingPathComponent("Info.plist")),
        ]
        let images = HostSupport.images(application)
        if FileSystem.isDirectory(images) {
            actions.append(.copyTree(images, to: resources.appendingPathComponent("Images", isDirectory: true)))
        }
        if !iconSteps.isEmpty {
            actions.append(.copy(icns, to: resources.appendingPathComponent("StateUI.icns")))
        }

        var postSteps: [ProcessInvocation] = []
        if let codesign = FileSystem.findExecutable("codesign", environment: environment) {
            postSteps.append(HostSupport.run(
                codesign, ["--force", "--deep", "--sign", "-", bundle.path],
                cwd: application.directory, label: "Sign \(product).app ad hoc"
            ))
        }

        return BuildPlan(
            application: application.name,
            host: id,
            configuration: configuration,
            steps: [step] + iconSteps,
            actions: actions,
            postSteps: postSteps,
            outputs: [bundle],
            notes: [
                "The bundle is assembled natively: the executable, its StateUI libraries, Info.plist, images and icon.",
                "No .scripts/AppKit bundling script is invoked.",
            ]
        )
    }

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        let builder = swiftBuilder
        let swift = try builder.swift()
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.AppKit", isDirectory: true)
        guard FileSystem.isDirectory(package) else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        var arguments = ["test", "--package-path", package.path]
        if let filter = request.conformanceFilter(for: id) ?? request.filter {
            arguments.append(contentsOf: ["--filter", filter])
        }
        let marks = request.conformanceEnvironment.merging(["STATEUI_HOST": id.rawValue]) { _, new in new }
        return TestPlan(
            application: context.application?.name, host: id,
            suites: [TestSuitePlan(
                name: "lib/StateUI/StateUI.AppKit",
                detail: request.conformance
                    ? "the AppKit host's conformance families, each verdict held to its marks"
                    : "the AppKit host's own tests and every conformance family, each verdict held to its marks",
                steps: [HostSupport.run(
                    swift, arguments, cwd: package, label: "Test the AppKit host", environment: marks
                )]
            )]
        )
    }

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let configuration = request.configuration
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: configuration)
        let product = application.product(for: id)
        let executable = bin.appendingPathComponent("\(product).app/Contents/MacOS/\(product)")
        let log = application.buildDirectory(for: id).appendingPathComponent("run.log")
        var steps: [ProcessInvocation] = []
        if let pkill = FileSystem.findExecutable("pkill", environment: environment) {
            steps.append(HostSupport.run(
                pkill, ["-f", "^\(executable.path)( |$)"], cwd: application.directory,
                label: "Stop a running \(product)", allowFailure: true
            ))
        }
        steps.append(HostSupport.run(
            executable, [], cwd: application.directory, label: "Run \(product)",
            environment: context.environment.stateuiVariables, mode: .observe
        ))
        return RunPlan(
            application: application.name, host: id, configuration: configuration,
            build: request.noBuild ? nil : build, steps: steps, detached: request.detach,
            logFile: log,
            notes: ["A running copy is stopped first: the build writes its executable again."]
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
        let bundle = bin.appendingPathComponent("\(application.product(for: id)).app", isDirectory: true)
        return DeployPlan(
            application: application.name, host: id, configuration: .release,
            build: build ?? release,
            actions: [
                .remove(destination),
                .createDirectory(destination),
                .copyTree(bundle, to: destination.appendingPathComponent(bundle.lastPathComponent)),
            ],
            destination: destination,
            notes: ["The destination holds the signed application bundle."]
        )
    }

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let bin = await swiftBuilder.binPath(application: application, host: id, configuration: request.configuration)
        let product = application.product(for: id)
        let executable = bin.appendingPathComponent("\(product).app/Contents/MacOS/\(product)")
        return DebugPlan(
            adapter: .lldbDAP, request: .launch, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (AppKit)",
            program: executable.path, workingDirectory: application.directory,
            environment: ["STATEUI_HOST": id.rawValue],
            build: build,
            notes: ["The bundle is launched by lldb-dap after the build."]
        )
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        LSPEnvironment(host: id, environment: ["STATEUI_HOST": id.rawValue], scratchPath: id.indexDirectory)
    }
}
