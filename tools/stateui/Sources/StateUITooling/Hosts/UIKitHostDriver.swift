// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// UIKit on iOS and iPadOS: a head wrapped in an application bundle, run on a
/// simulator or a device in its own process.
public struct UIKitHostDriver: HostDriver {
    public let id = HostID.uiKit
    public let capabilities = HostCapabilities(devices: true)

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
        guard let xcrun = runner.which("xcrun") else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "xcrun was not found. Install Xcode 27 and select it with xcode-select."
            )
        }
        guard await runner.output(xcrun, ["--find", "swift"], label: "xcrun --find swift") != nil else {
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: "Xcode's Swift was not found. Install Xcode 27."
            )
        }
        let runtimes = await runner.output(
            xcrun, ["simctl", "list", "runtimes", "available", "-j"], label: "simctl runtimes"
        )
        let hasRuntime = runtimes.flatMap(ToolchainService.newestIOSRuntime).map { Version.atLeast($0, "26") } ?? false
        return HostSupport.availability(
            id, platform: platform, toolchainReady: hasRuntime,
            reason: hasRuntime ? nil : "No iOS 26 or newer simulator runtime is installed. Add one in Xcode's Settings, Components."
        )
    }

    public func devices(_ context: ProjectContext) async throws -> [Device] {
        guard platform.operatingSystem == .macOS, let xcrun = runner.which("xcrun") else { return [] }
        var found = await simulators(xcrun)
        found.append(contentsOf: await physicalDevices(xcrun))
        return found
    }

    // MARK: - Build

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let application = try HostSupport.application(context)
        let destination = try await resolveDestination(for: request.device)
        let sdkName = destination.isDevice ? "iphoneos" : "iphonesimulator"
        let triple = destination.isDevice ? HostCompilation.uikitDeviceTriple : HostCompilation.uikitSimulatorTriple
        guard let sdk = await swiftBuilder.xcodeSDKPath(sdkName) else {
            throw ToolingError.toolchainMissing(
                "The \(sdkName) SDK was not found.",
                suggestion: "Install the iOS platform in Xcode's Settings, Components."
            )
        }
        let swift = try await xcrunSwift()
        let step = try swiftBuilder.buildInvocation(
            application: application, host: id, configuration: request.configuration,
            triple: triple, sdk: sdk, extra: request.extraArguments, executable: swift
        )
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: request.configuration,
            triple: triple, sdk: sdk, executable: swift
        )
        let product = application.product(for: id)
        let bundle = bin.appendingPathComponent("\(product).app", isDirectory: true)
        let identifier = HostSupport.lowercaseIdentifier(application.name)
        let bundleSteps = try await bundlePlan(
            application: application, product: product, identifier: identifier,
            bin: bin, bundle: bundle, isDevice: destination.isDevice, sdkName: sdkName,
            configuration: request.configuration, context: context
        )
        return BuildPlan(
            application: application.name, host: id, configuration: request.configuration,
            steps: [step] + bundleSteps.steps, actions: bundleSteps.actions,
            postSteps: bundleSteps.postSteps, outputs: [bundle],
            notes: [
                "The bundle is assembled natively: the executable, its StateUI libraries in Frameworks/, Info.plist, pictures and icon.",
                "No .scripts/UIKit script is invoked.",
                destination.isDevice
                    ? "A device bundle is signed ad hoc; a development profile is not selected yet, so installation may refuse it."
                    : "The simulator bundle is signed ad hoc.",
            ]
        )
    }

    // MARK: - Test

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.UIKit/Tests", isDirectory: true)
        guard FileSystem.isDirectory(package) else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        guard platform.operatingSystem == .macOS else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        let destination = try await resolveDestination(for: request.device)
        guard !destination.isDevice else {
            throw ToolingError.deviceNotFound(
                "The UIKit host's suite runs on a simulator.",
                context: ["device": destination.name],
                suggestion: "Name a simulator, or omit --device."
            )
        }
        let sdkName = "iphonesimulator"
        guard let sdk = await swiftBuilder.xcodeSDKPath(sdkName),
              let platformPath = await xcrunPlatformPath(sdkName),
              let swift = try? await xcrunSwift() else {
            throw ToolingError.toolchainMissing("The iOS simulator SDK was not found.")
        }
        let frameworks = platformPath.appendingPathComponent("Developer/Library/Frameworks", isDirectory: true)
        let libraries = platformPath.appendingPathComponent("Developer/usr/lib", isDirectory: true)
        let extra = [
            "-Xswiftc", "-F", "-Xswiftc", frameworks.path,
            "-Xswiftc", "-I", "-Xswiftc", libraries.path,
            "-Xlinker", "-F", "-Xlinker", frameworks.path,
            "-Xlinker", "-L", "-Xlinker", libraries.path,
            "-Xlinker", "-rpath", "-Xlinker", frameworks.path,
            "-Xlinker", "-rpath", "-Xlinker", libraries.path,
        ]
        let product = "StateUIUIKitTests"
        let scratch = package.appendingPathComponent(".build", isDirectory: true)
        let build = try swiftBuilder.buildInvocation(
            application: Application(
                name: product, directory: package, manifest: package.appendingPathComponent("Package.swift"),
                heads: [], checkout: checkout, bundleScript: nil
            ),
            host: id, configuration: .debug, scratch: scratch, product: product,
            triple: HostCompilation.uikitSimulatorTriple, sdk: sdk, extra: extra, executable: swift,
            label: "Build the UIKit host's tests"
        )
        let bin = await swiftBuilder.binPath(
            application: Application(
                name: product, directory: package, manifest: package.appendingPathComponent("Package.swift"),
                heads: [], checkout: checkout, bundleScript: nil
            ),
            host: id, configuration: .debug, scratch: scratch,
            triple: HostCompilation.uikitSimulatorTriple, sdk: sdk, executable: swift
        )
        let bundle = scratch.appendingPathComponent("debug/\(product).app", isDirectory: true)
        let bundleSteps = try await bundlePlan(
            application: Application(
                name: product, directory: package, manifest: package.appendingPathComponent("Package.swift"),
                heads: [], checkout: checkout, bundleScript: nil
            ),
            product: product, identifier: "com.stateui.uikit.tests", bin: bin, bundle: bundle,
            isDevice: false, sdkName: sdkName, configuration: .debug, context: context,
            resources: package.appendingPathComponent("Resources", isDirectory: true)
        )
        var launchEnvironment = [
            "SIMCTL_CHILD_STATEUI_FILTER": request.filter ?? "",
            "SIMCTL_CHILD_STATEUI_UPDATE_EXPORTS": context.environment["STATEUI_UPDATE_EXPORTS"] ?? "",
            "SIMCTL_CHILD_STATEUI_STALE_ONLY": context.environment["STATEUI_STALE_ONLY"] ?? "",
        ]
        if let suite = request.suite { launchEnvironment["SIMCTL_CHILD_STATEUI_FILTER"] = suite }
        let steps = [build] + bundleSteps.steps
        var postSteps = bundleSteps.postSteps
        if let xcrun = runner.which("xcrun") {
            postSteps.append(HostSupport.run(
                xcrun, ["simctl", "install", destination.id, bundle.path],
                cwd: package, label: "Install the UIKit host's tests"
            ))
            postSteps.append(HostSupport.run(
                xcrun,
                ["simctl", "launch", "--console-pty", "--terminate-running-process", destination.id,
                 "com.stateui.uikit.tests"],
                cwd: package, label: "Run the UIKit host's tests",
                environment: launchEnvironment, mode: .observe
            ))
        }
        return TestPlan(
            application: context.application?.name, host: id,
            suites: [TestSuitePlan(
                name: "lib/StateUI/StateUI.UIKit/Tests",
                detail: "the UIKit host's package, run as an application on \(destination.name)",
                steps: steps, actions: bundleSteps.actions, postSteps: postSteps,
                requiresDevice: true, host: id
            )]
        )
    }

    // MARK: - Run

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let destination = try await resolveDestination(for: request.device)
        let sdkName = destination.isDevice ? "iphoneos" : "iphonesimulator"
        let triple = destination.isDevice ? HostCompilation.uikitDeviceTriple : HostCompilation.uikitSimulatorTriple
        let sdk = await swiftBuilder.xcodeSDKPath(sdkName)
        let swift = try? await xcrunSwift()
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: request.configuration,
            triple: triple, sdk: sdk, executable: swift
        )
        let product = application.product(for: id)
        let bundle = bin.appendingPathComponent("\(product).app", isDirectory: true)
        let identifier = HostSupport.lowercaseIdentifier(application.name)
        let log = application.buildDirectory(for: id).appendingPathComponent("run.log")
        let facts = application.buildDirectory(for: id).appendingPathComponent("debugger.json")
        var steps: [ProcessInvocation] = []
        guard let xcrun = runner.which("xcrun") else {
            throw ToolingError.toolchainMissing("xcrun was not found.")
        }
        if destination.isDevice {
            steps.append(HostSupport.run(
                xcrun, ["devicectl", "device", "install", "app", "--device", destination.id, bundle.path],
                cwd: application.directory, label: "Install \(product) on \(destination.name)"
            ))
            var launch = [
                "devicectl", "device", "process", "launch", "--device", destination.id,
                "--terminate-existing",
            ]
            if !request.detach { launch.append("--console") }
            launch.append(identifier)
            steps.append(HostSupport.run(
                xcrun, launch, cwd: application.directory, label: "Run \(product) on \(destination.name)",
                environment: context.environment.stateuiVariables,
                mode: request.detach ? .run : .observe
            ))
        } else {
            steps.append(HostSupport.run(
                xcrun, ["simctl", "boot", destination.id], cwd: application.directory,
                label: "Boot \(destination.name)", allowFailure: true
            ))
            if let open = FileSystem.findExecutable("open") {
                steps.append(HostSupport.run(
                    open, ["-a", "Simulator", "--args", "-CurrentDeviceUDID", destination.id],
                    cwd: application.directory, label: "Bring the Simulator forward", allowFailure: true
                ))
            }
            steps.append(HostSupport.run(
                xcrun, ["simctl", "install", destination.id, bundle.path],
                cwd: application.directory, label: "Install \(product) on \(destination.name)"
            ))
            steps.append(HostSupport.run(
                xcrun, ["simctl", "terminate", destination.id, identifier],
                cwd: application.directory, label: "Stop a running \(product)", allowFailure: true
            ))
            var launch = ["simctl", "launch", "--terminate-running-process"]
            if !request.detach { launch.append("--console-pty") }
            launch.append(contentsOf: [destination.id, identifier])
            steps.append(HostSupport.run(
                xcrun, launch, cwd: application.directory, label: "Run \(product) on \(destination.name)",
                environment: context.environment.stateuiVariables,
                mode: request.detach ? .run : .observe
            ))
        }
        return RunPlan(
            application: application.name, host: id, configuration: request.configuration,
            build: request.noBuild ? nil : build, steps: steps, detached: request.detach,
            factsFile: facts, logFile: log,
            notes: [
                "The destination is \(destination.name) (\(destination.isDevice ? "device" : "simulator")).",
                request.detach
                    ? "The application is started without following its output."
                    : "The application's output is followed until it exits.",
            ]
        )
    }

    // MARK: - Deploy

    public func deployPlan(
        _ request: DeployRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DeployPlan {
        let application = try HostSupport.application(context)
        guard let destination = request.destination else {
            throw ToolingError.deploymentFailed("No destination was resolved for \(application.name).")
        }
        let destinationDevice = try await resolveDestination(for: request.device)
        let release = try await buildPlan(
            BuildRequest(
                application: application.name, host: id, configuration: .release,
                device: request.device
            ), context: context
        )
        let sdkName = destinationDevice.isDevice ? "iphoneos" : "iphonesimulator"
        let triple = destinationDevice.isDevice ? HostCompilation.uikitDeviceTriple : HostCompilation.uikitSimulatorTriple
        let sdk = await swiftBuilder.xcodeSDKPath(sdkName)
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: .release,
            triple: triple, sdk: sdk, executable: try? await xcrunSwift()
        )
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
            notes: ["The destination holds the application bundle built for \(destinationDevice.name)."]
        )
    }

    // MARK: - Debug

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let destination = try await resolveDestination(for: request.device)
        let sdkName = destination.isDevice ? "iphoneos" : "iphonesimulator"
        let triple = destination.isDevice ? HostCompilation.uikitDeviceTriple : HostCompilation.uikitSimulatorTriple
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: request.configuration,
            triple: triple, sdk: await swiftBuilder.xcodeSDKPath(sdkName),
            executable: try? await xcrunSwift()
        )
        let product = application.product(for: id)
        let executable = bin.appendingPathComponent("\(product).app/Contents/MacOS/\(product)")
        let bundleExecutable = bin.appendingPathComponent("\(product).app/\(product)")
        let bundle = bin.appendingPathComponent("\(product).app", isDirectory: true)
        let identifier = HostSupport.lowercaseIdentifier(application.name)
        let facts = application.buildDirectory(for: id).appendingPathComponent("debugger.json")
        guard let xcrun = runner.which("xcrun") else {
            throw ToolingError.toolchainMissing("xcrun was not found.")
        }
        var preLaunch: [ProcessInvocation] = []
        if destination.isDevice {
            preLaunch.append(HostSupport.run(
                xcrun, ["devicectl", "device", "install", "app", "--device", destination.id, bundle.path],
                cwd: application.directory, label: "Install \(product) on \(destination.name)"
            ))
        } else {
            preLaunch.append(HostSupport.run(
                xcrun, ["simctl", "boot", destination.id], cwd: application.directory,
                label: "Boot \(destination.name)", allowFailure: true
            ))
            preLaunch.append(HostSupport.run(
                xcrun, ["simctl", "install", destination.id, bundle.path],
                cwd: application.directory, label: "Install \(product) on \(destination.name)"
            ))
            preLaunch.append(HostSupport.run(
                xcrun, ["simctl", "terminate", destination.id, identifier],
                cwd: application.directory, label: "Stop a running \(product)", allowFailure: true
            ))
        }
        preLaunch.append(HostSupport.run(
            HostSupport.currentExecutable(environment: environment),
            ["__uikit-debug", xcrun.path, destination.isDevice ? "device" : "simulator",
             destination.id, identifier, bundle.path, facts.path],
            cwd: application.directory, label: "Start \(product) held for the debugger"
        ))
        var initCommands: [String] = []
        if destination.isDevice {
            initCommands.append("platform select remote-ios")
        } else {
            initCommands.append("platform select ios-simulator")
        }
        initCommands.append("settings set target.source-map . \(application.directory.path)")
        return DebugPlan(
            adapter: .lldbDAP, request: .attach, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (UIKit)",
            program: FileSystem.exists(bundleExecutable) ? bundleExecutable.path : executable.path,
            workingDirectory: application.directory,
            environment: ["STATEUI_HOST": id.rawValue],
            initCommands: initCommands, attachCommands: [],
            build: build, preLaunch: preLaunch, factsFile: facts,
            notes: [
                "The bundle is installed on \(destination.name) and started held for the debugger.",
                "debugger.json names the process once the application has started.",
            ]
        )
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        let sdk = await swiftBuilder.xcodeSDKPath("iphonesimulator")
        return LSPEnvironment(
            host: id, environment: ["STATEUI_HOST": id.rawValue],
            scratchPath: id.indexDirectory, sdk: sdk?.path,
            triple: HostCompilation.uikitSimulatorTriple,
            notes: sdk == nil ? ["The iOS simulator SDK was not found; the editor compiles for this machine."] : []
        )
    }

    // MARK: - Bundle assembly

    private struct BundleSteps {
        let steps: [ProcessInvocation]
        let actions: [FileAction]
        let postSteps: [ProcessInvocation]
    }

    private func bundlePlan(
        application: Application, product: String, identifier: String,
        bin: URL, bundle: URL, isDevice: Bool, sdkName: String,
        configuration: BuildConfiguration, context: ProjectContext,
        resources: URL? = nil
    ) async throws -> BundleSteps {
        let executable = bin.appendingPathComponent(product)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        let images = bundle.appendingPathComponent("Images", isDirectory: true)
        let resourceRoot = resources ?? application.directory.appendingPathComponent("Resources", isDirectory: true)
        let tools = application.buildDirectory(for: id).appendingPathComponent("tools", isDirectory: true)
        let infoPlist = bundle.appendingPathComponent("Info.plist")

        let platformName = isDevice ? "iPhoneOS" : "iPhoneSimulator"
        let extra: [String: Any] = [
            "CFBundleSupportedPlatforms": [platformName],
            "MinimumOSVersion": "26.0",
            "LSRequiresIPhoneOS": true,
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": [String: Any](),
            "CADisableMinimumFrameDurationOnPhone": true,
            "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": true],
            "UISupportedInterfaceOrientations": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight",
                "UIInterfaceOrientationPortraitUpsideDown",
            ],
        ]

        var actions: [FileAction] = [
            .remove(bundle),
            .createDirectory(frameworks),
            .createDirectory(images),
            .copy(executable, to: bundle.appendingPathComponent(product)),
            .copyMatching(bin, matching: ".dylib", to: frameworks),
            .write(HostSupport.infoPlist(
                executable: product, identifier: identifier, name: application.name,
                minimumSystemVersion: "26.0", extra: extra
            ), to: infoPlist),
        ]
        if FileSystem.isDirectory(resourceRoot.appendingPathComponent("Images", isDirectory: true)) {
            actions.append(.copyTree(
                resourceRoot.appendingPathComponent("Images", isDirectory: true),
                to: images
            ))
        }

        var steps: [ProcessInvocation] = []
        var postSteps: [ProcessInvocation] = []
        let checkout = try? HostSupport.checkout(context)

        if let installNameTool = FileSystem.findExecutable("install_name_tool") {
            postSteps.append(HostSupport.run(
                installNameTool, ["-add_rpath", "@executable_path/Frameworks", bundle.appendingPathComponent(product).path],
                cwd: application.directory, label: "Add the Frameworks rpath", allowFailure: true
            ))
        }

        // Pictures: UIKit draws no SVG, so the application's artwork is rasterized
        // by the repository's own Swift tool, compiled and run as explicit steps.
        let sourceImages = resourceRoot.appendingPathComponent("Images", isDirectory: true)
        let rasterizerSourceURL = checkout?.appendingPathComponent("tools/stateui/Support/rasterize-images.swift")
        let rasterizerSource = (rasterizerSourceURL.map { FileSystem.exists($0) } == true) ? rasterizerSourceURL : nil
        if FileSystem.isDirectory(sourceImages), let rasterizerSource = rasterizerSource,
           let swiftc = try? await awaitCompiler("swiftc") {
            let rasterizer = tools.appendingPathComponent("rasterize-images")
            steps.append(HostSupport.run(
                swiftc, ["-O", rasterizerSource.path,
                         "-o", rasterizer.path],
                cwd: application.directory, label: "Compile the picture rasterizer"
            ))
            postSteps.append(HostSupport.run(
                rasterizer, [sourceImages.path, images.path],
                cwd: application.directory, label: "Draw the application's pictures for UIKit"
            ))
        }

        // Icon: drawn into an asset catalog, compiled by actool, its keys merged
        // into Info.plist.
        let artwork = resourceRoot.appendingPathComponent("AppIcon", isDirectory: true)
        let drawerSourceURL = checkout?.appendingPathComponent("tools/stateui/Support/draw-app-icon-uikit.swift")
        let drawerSource = (drawerSourceURL.map { FileSystem.exists($0) } == true) ? drawerSourceURL : nil
        if FileSystem.isDirectory(artwork), let drawerSource = drawerSource,
           let swiftc = try? await awaitCompiler("swiftc") {
            let drawer = tools.appendingPathComponent("draw-app-icon")
            let catalog = tools.appendingPathComponent("Assets.xcassets", isDirectory: true)
            let iconPlist = tools.appendingPathComponent("icon.plist")
            steps.append(HostSupport.run(
                swiftc, ["-O", drawerSource.path,
                         "-o", drawer.path],
                cwd: application.directory, label: "Compile the icon drawer"
            ))
            postSteps.append(HostSupport.run(
                drawer, [artwork.path, catalog.path], cwd: application.directory,
                label: "Draw the application's icon"
            ))
            if let xcrun = runner.which("xcrun") {
                postSteps.append(HostSupport.run(
                    xcrun, ["actool", catalog.path, "--compile", bundle.path, "--platform", sdkName,
                            "--minimum-deployment-target", "26.0", "--target-device", "iphone",
                            "--target-device", "ipad", "--app-icon", "AppIcon",
                            "--output-partial-info-plist", iconPlist.path,
                            "--output-format", "human-readable-text"],
                    cwd: application.directory, label: "Compile the icon with actool"
                ))
                if FileSystem.isExecutable(URL(fileURLWithPath: "/usr/libexec/PlistBuddy")) {
                    postSteps.append(HostSupport.run(
                        URL(fileURLWithPath: "/usr/libexec/PlistBuddy"),
                        ["-c", "Merge \(iconPlist.path)", infoPlist.path],
                        cwd: application.directory, label: "Merge the icon keys into Info.plist"
                    ))
                }
            }
        }

        // An application's own Info.plist, where it has one, wins key by key.
        let ownPlist = application.directory.appendingPathComponent("Platforms/UIKit/Info.plist")
        if FileSystem.exists(ownPlist),
           FileSystem.isExecutable(URL(fileURLWithPath: "/usr/libexec/PlistBuddy")) {
            postSteps.append(HostSupport.run(
                URL(fileURLWithPath: "/usr/libexec/PlistBuddy"),
                ["-c", "Merge \(ownPlist.path)", infoPlist.path],
                cwd: application.directory, label: "Merge the application's Info.plist"
            ))
        }

        if let codesign = FileSystem.findExecutable("codesign") {
            postSteps.append(HostSupport.run(
                codesign, ["--force", "--deep", "--sign", "-", bundle.path],
                cwd: application.directory, label: "Sign \(product).app ad hoc", allowFailure: isDevice
            ))
        }

        return BundleSteps(steps: steps, actions: actions, postSteps: postSteps)
    }

    // MARK: - Discovery

    struct Destination: Sendable {
        let isDevice: Bool
        let id: String
        let name: String
        let udid: String
    }

    private func xcrunSwift() async throws -> URL {
        let xcrun = try swiftBuilder.xcrun()
        guard let output = await runner.output(xcrun, ["--find", "swift"], label: "xcrun --find swift") else {
            throw ToolingError.toolchainMissing("Xcode's Swift was not found.")
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileSystem.isExecutable(URL(fileURLWithPath: path)) else {
            throw ToolingError.toolchainMissing("Xcode's Swift was not found at \(path).")
        }
        return URL(fileURLWithPath: path)
    }

    private func xcrunPlatformPath(_ sdk: String) async -> URL? {
        guard let xcrun = runner.which("xcrun"),
              let output = await runner.output(xcrun, ["--sdk", sdk, "--show-sdk-platform-path"],
                                               label: "xcrun --show-sdk-platform-path") else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private func awaitCompiler(_ name: String) async throws -> URL {
        guard let xcrun = runner.which("xcrun"),
              let output = await runner.output(xcrun, ["--find", name], label: "xcrun --find \(name)") else {
            throw ToolingError.toolchainMissing("\(name) was not found in Xcode.")
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileSystem.isExecutable(URL(fileURLWithPath: path)) else {
            throw ToolingError.toolchainMissing("\(name) was not found in Xcode.")
        }
        return URL(fileURLWithPath: path)
    }

    func resolveDestination(for wanted: String?) async throws -> Destination {
        guard platform.operatingSystem == .macOS, let xcrun = runner.which("xcrun") else {
            throw ToolingError.hostUnavailable(
                "UIKit heads are built on macOS.",
                suggestion: "Run stateui on a Mac with Xcode 27."
            )
        }
        if let wanted {
            for device in await physicalDevices(xcrun)
            where device.name == wanted || device.id == wanted {
                return Destination(isDevice: true, id: device.id, name: device.name, udid: device.id)
            }
        }
        let simulators = await simulatorRecords(xcrun)
        guard !simulators.isEmpty else {
            throw ToolingError.deviceNotFound(
                "No iOS simulator is available.",
                suggestion: "Install an iOS runtime and a simulator in Xcode's Settings, Components."
            )
        }
        let chosen: SimulatorRecord?
        if let wanted {
            chosen = simulators.first { $0.name == wanted || $0.udid == wanted }
        } else {
            chosen = simulators.last(where: { $0.state == "Booted" })
                ?? simulators.last(where: { $0.name.hasPrefix("iPhone") })
                ?? simulators.last
        }
        guard let chosen else {
            throw ToolingError.deviceNotFound(
                "No simulator or device is named \(wanted ?? "").",
                suggestion: "Run `stateui devices --host uikit` to list them."
            )
        }
        return Destination(isDevice: false, id: chosen.udid, name: chosen.name, udid: chosen.udid)
    }

    struct SimulatorRecord: Sendable {
        let name: String
        let udid: String
        let state: String
        let runtime: String
    }

    private func simulatorRecords(_ xcrun: URL) async -> [SimulatorRecord] {
        guard let output = await runner.output(
            xcrun, ["simctl", "list", "devices", "available", "-j"], label: "simctl devices"
        ), let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [[String: Any]]] else { return [] }
        var records: [SimulatorRecord] = []
        for (runtime, listed) in devices where runtime.contains("iOS") {
            let version = runtime.split(separator: ".").last.map(String.init)?
                .replacingOccurrences(of: "iOS-", with: "")
                .replacingOccurrences(of: "-", with: ".") ?? runtime
            for device in listed {
                guard let name = device["name"] as? String,
                      let udid = device["udid"] as? String else { continue }
                if device["isAvailable"] as? Bool == false { continue }
                records.append(SimulatorRecord(
                    name: name, udid: udid, state: device["state"] as? String ?? "", runtime: version
                ))
            }
        }
        return records.sorted {
            let order = Version.compare($0.runtime, $1.runtime)
            return order == 0 ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : order < 0
        }
    }

    private func simulators(_ xcrun: URL) async -> [Device] {
        await simulatorRecords(xcrun).map { record in
            Device(
                id: record.udid, name: record.name, host: id, kind: .simulator,
                platform: "iOS", osVersion: record.runtime, state: record.state,
                architecture: platform.architecture.rawValue,
                isAvailable: record.state != "Unavailable"
            )
        }
    }

    private func physicalDevices(_ xcrun: URL) async -> [Device] {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("stateui-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard await runner.result(
            xcrun, ["devicectl", "list", "devices", "--json-output", temporary.path],
            label: "devicectl list devices"
        )?.succeeded == true,
              let data = try? Data(contentsOf: temporary),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device -> Device? in
            let hardware = device["hardwareProperties"] as? [String: Any] ?? [:]
            let properties = device["deviceProperties"] as? [String: Any] ?? [:]
            guard hardware["platform"] as? String == "iOS",
                  hardware["reality"] as? String == "physical" else { return nil }
            guard let identifier = device["identifier"] as? String else { return nil }
            let name = properties["name"] as? String ?? identifier
            return Device(
                id: identifier, name: name, host: id, kind: .physical, platform: "iOS",
                osVersion: properties["osVersionNumber"] as? String,
                state: "connected", architecture: hardware["deviceType"] as? String,
                isAvailable: true
            )
        }
    }
}
