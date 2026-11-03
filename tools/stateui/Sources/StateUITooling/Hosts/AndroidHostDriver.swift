// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Android Views: Swift compiled into a dynamic library, packaged by Gradle
/// around the host's Java layer, installed on a device or emulator.
public struct AndroidHostDriver: HostDriver {
    public let id = HostID.android
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
        guard id.developmentPlatforms.contains(platform.projectPlatform) else {
            return HostSupport.availability(id, platform: platform, toolchainReady: false)
        }
        do {
            let toolchain = try await AndroidToolchain.discover(
                environment: environment, platform: platform, runner: runner
            )
            let devices = await deviceList(toolchain)
            return HostSupport.availability(
                id, platform: platform, toolchainReady: toolchain.gradle != nil,
                deviceAvailable: !devices.isEmpty,
                reason: toolchain.gradle == nil
                    ? "Gradle \(AndroidToolchain.gradleVersion) was not found; install it or let the wrapper cache it."
                    : nil
            )
        } catch {
            let structured = error.toolingError
            return HostSupport.availability(
                id, platform: platform, toolchainReady: false,
                reason: structured.suggestion ?? structured.message
            )
        }
    }

    public func devices(_ context: ProjectContext) async throws -> [Device] {
        guard let toolchain = try? await AndroidToolchain.discover(
            environment: environment, platform: platform, runner: runner
        ) else { return [] }
        return await deviceList(toolchain)
    }

    // MARK: - Build

    public func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan {
        let application = try HostSupport.application(context)
        let toolchain = try await discover()
        let abi = try await abi(request.architecture ?? request.device, toolchain: toolchain)
        return try await headPlan(
            name: application.name, package: application.directory, product: application.product(for: id),
            configuration: request.configuration, abi: abi, toolchain: toolchain,
            resources: application.directory.appendingPathComponent("Resources", isDirectory: true),
            context: context, extra: request.extraArguments
        )
    }

    // MARK: - Test

    public func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        let checkout = try HostSupport.checkout(context)
        let package = checkout.appendingPathComponent("lib/StateUI/StateUI.Android/Tests", isDirectory: true)
        guard FileSystem.isDirectory(package) else {
            return TestPlan(application: context.application?.name, host: id, suites: [])
        }
        let toolchain = try await discover()
        let product = "StateUIAndroidTests"
        if request.buildOnly {
            // A machine that builds where another runs: the test APK is packaged for an
            // ABI no device is asked for, and nothing is installed or instrumented.
            let abi = request.architecture ?? "x86_64"
            let build = try await headPlan(
                name: product, package: package, product: product,
                configuration: .debug, abi: abi, toolchain: toolchain,
                resources: package.appendingPathComponent("Resources", isDirectory: true),
                context: context, extra: []
            )
            let apk = apkURL(build.outputs.first, package: package, product: product, configuration: .debug)
            return TestPlan(
                application: context.application?.name, host: id,
                suites: [TestSuitePlan(
                    name: "lib/StateUI/StateUI.Android/Tests",
                    detail: "the Android host's package, packaged for \(abi); it runs on a device elsewhere",
                    steps: build.steps, actions: build.actions, postSteps: build.postSteps,
                    host: id, outputs: [apk]
                )]
            )
        }
        let serial = try await serial(request.device, toolchain: toolchain)
        let abi = try await deviceABI(serial: serial, toolchain: toolchain)
        let build = try await headPlan(
            name: product, package: package, product: product,
            configuration: .debug, abi: abi, toolchain: toolchain,
            resources: package.appendingPathComponent("Resources", isDirectory: true),
            context: context, extra: []
        )
        let apk = apkURL(build.outputs.first, package: package, product: product, configuration: .debug)
        let namespace = packageName(package: package) ?? "com.stateui.android.tests"
        var instrument = [
            "shell", "am", "instrument", "-w",
        ]
        if let filter = request.filter ?? request.suite {
            instrument.append(contentsOf: ["-e", "filter", filter])
        }
        instrument.append("\(namespace)/stateui.android.test.StateUITestRunner")
        var postSteps = build.postSteps
        postSteps.append(HostSupport.run(
            toolchain.adb, ["-s", serial, "install", "-r", apk.path],
            cwd: package, label: "Install the Android host's tests"
        ))
        postSteps.append(HostSupport.run(
            toolchain.adb, ["-s", serial] + instrument,
            cwd: package, label: "Run the Android host's tests",
            environment: context.environment.stateuiVariables, mode: .observe
        ))
        return TestPlan(
            application: context.application?.name, host: id,
            suites: [TestSuitePlan(
                name: "lib/StateUI/StateUI.Android/Tests",
                detail: "the Android host's package, run by instrumentation on \(serial) (\(abi))",
                steps: build.steps, actions: build.actions, postSteps: postSteps,
                requiresDevice: true, host: id
            )]
        )
    }

    // MARK: - Run

    public func runPlan(
        _ request: RunRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> RunPlan {
        let application = try HostSupport.application(context)
        let toolchain = try await discover()
        let serial = try await serial(request.device, toolchain: toolchain)
        let abi = try await deviceABI(serial: serial, toolchain: toolchain)
        let out = application.buildDirectory(for: id)
        let apk = apkURL(
            out.appendingPathComponent("gradle/outputs/apk/\(request.configuration.rawValue)"),
            package: application.directory, product: application.product(for: id),
            configuration: request.configuration
        )
        let namespace = await packageName(apk: apk, toolchain: toolchain)
            ?? packageName(package: application.directory)
            ?? "com.stateui.\(application.name.lowercased())"
        let activity = activityName(package: application.directory) ?? "stateui.android.StateUIActivity"
        let facts = out.appendingPathComponent("debugger.json")
        let log = out.appendingPathComponent("run.log")

        var steps: [ProcessInvocation] = [
            HostSupport.run(
                toolchain.adb, ["-s", serial, "install", "-r", apk.path],
                cwd: application.directory, label: "Install \(application.name) on \(serial)"
            ),
            HostSupport.run(
                toolchain.adb, ["-s", serial, "shell", "am", "force-stop", namespace],
                cwd: application.directory, label: "Stop a running \(application.name)", allowFailure: true
            ),
        ]
        var start = ["-s", serial, "shell", "am", "start", "-W", "-n", "\(namespace)/\(activity)"]
        for (name, value) in context.environment.stateuiVariables.sorted(by: { $0.key < $1.key }) {
            start.append(contentsOf: ["-e", name, value])
        }
        steps.append(HostSupport.run(
            toolchain.adb, start, cwd: application.directory,
            label: "Start \(application.name) on \(serial)"
        ))
        if !request.detach {
            steps.append(HostSupport.run(
                HostSupport.currentExecutable(environment: environment),
                ["__android-logcat", toolchain.adb.path, serial, namespace],
                cwd: application.directory, label: "Follow \(application.name)'s log",
                mode: .observe
            ))
        }
        return RunPlan(
            application: application.name, host: id, configuration: request.configuration,
            build: request.noBuild ? nil : build, steps: steps, detached: request.detach,
            factsFile: facts, logFile: log,
            notes: [
                "The device is \(serial), whose ABI is \(abi).",
                request.detach
                    ? "The application is started without following logcat."
                    : "logcat follows the application's process until it exits.",
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
        let toolchain = try await discover()
        let abi = try await abi(request.architecture ?? request.device, toolchain: toolchain)
        let release = try await headPlan(
            name: application.name, package: application.directory, product: application.product(for: id),
            configuration: .release, abi: abi, toolchain: toolchain,
            resources: application.directory.appendingPathComponent("Resources", isDirectory: true),
            context: context, extra: []
        )
        let apk = apkURL(
            application.buildDirectory(for: id)
                .appendingPathComponent("gradle/outputs/apk/release"),
            package: application.directory, product: application.product(for: id), configuration: .release
        )
        return DeployPlan(
            application: application.name, host: id, configuration: .release,
            build: build ?? release,
            actions: [
                .remove(destination),
                .createDirectory(destination),
                .copy(apk, to: destination.appendingPathComponent("\(application.name).apk")),
            ],
            destination: destination,
            notes: ["The destination holds the APK built for \(abi)."]
        )
    }

    // MARK: - Debug

    public func debugPlan(
        _ request: DebugRequest, context: ProjectContext, build: BuildPlan?
    ) async throws -> DebugPlan {
        let application = try HostSupport.application(context)
        let toolchain = try await discover()
        let serial = try await serial(request.device, toolchain: toolchain)
        let abi = try await deviceABI(serial: serial, toolchain: toolchain)
        let out = application.buildDirectory(for: id)
        let apk = apkURL(
            out.appendingPathComponent("gradle/outputs/apk/\(request.configuration.rawValue)"),
            package: application.directory, product: application.product(for: id),
            configuration: request.configuration
        )
        guard let namespace = await packageName(apk: apk, toolchain: toolchain)
            ?? packageName(package: application.directory) else {
            throw ToolingError.invalidConfiguration(
                "\(application.name) has no Android namespace.",
                context: ["application": application.name],
                suggestion: "Add `namespace = \"…\"` to Platforms/Android/build.gradle.kts."
            )
        }
        let activity = activityName(package: application.directory) ?? "stateui.android.StateUIActivity"
        let facts = out.appendingPathComponent("debugger.json")

        var preLaunch: [ProcessInvocation] = [
            HostSupport.run(
                toolchain.adb, ["-s", serial, "install", "-r", apk.path],
                cwd: application.directory, label: "Install \(application.name) on \(serial)"
            ),
            HostSupport.run(
                toolchain.adb, ["-s", serial, "shell", "am", "force-stop", namespace],
                cwd: application.directory, label: "Stop a running \(application.name)", allowFailure: true
            ),
        ]
        var start = ["-s", serial, "shell", "am", "start", "-W", "-n", "\(namespace)/\(activity)"]
        for (name, value) in context.environment.stateuiVariables.sorted(by: { $0.key < $1.key }) {
            start.append(contentsOf: ["-e", name, value])
        }
        preLaunch.append(HostSupport.run(
            toolchain.adb, start, cwd: application.directory,
            label: "Start \(application.name) on \(serial)"
        ))
        preLaunch.append(HostSupport.run(
            HostSupport.currentExecutable(environment: environment),
            ["__android-debug", toolchain.adb.path, serial, namespace, abi, toolchain.ndk.path, facts.path],
            cwd: application.directory, label: "Ready lldb-server on \(serial)"
        ))

        return DebugPlan(
            adapter: .lldbDAP, request: .attach, host: id, application: application.name,
            configuration: request.configuration, name: "StateUI: \(application.name) (Android)",
            program: out.appendingPathComponent("symbols/\(abi)/lib\(application.product(for: id)).so").path,
            workingDirectory: application.directory,
            environment: ["STATEUI_HOST": id.rawValue],
            initCommands: [
                "platform select remote-android",
                "settings set target.source-map . \(application.directory.path)",
            ],
            attachCommands: [
                "platform connect unix-abstract:///\(namespace)/stateui-debugger.sock",
            ],
            build: build, preLaunch: preLaunch, factsFile: facts,
            notes: [
                "The application is installed and started on \(serial), then lldb-server runs inside its sandbox.",
                "debugger.json names the device, package and process.",
            ]
        )
    }

    public func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        let toolchain = try? await discover()
        return LSPEnvironment(
            host: id, environment: ["STATEUI_HOST": id.rawValue],
            scratchPath: id.indexDirectory, swiftSDK: toolchain?.swiftSDKID,
            triple: HostCompilation.androidTriple,
            notes: toolchain == nil
                ? ["The Android toolchain was not found; the editor compiles for this machine."]
                : []
        )
    }

    // MARK: - Head plan

    private func headPlan(
        name: String, package: URL, product: String, configuration: BuildConfiguration,
        abi: String, toolchain: AndroidToolchain, resources: URL, context: ProjectContext,
        extra: [String]
    ) async throws -> BuildPlan {
        guard let triple = HostCompilation.androidTriple(for: abi) else {
            throw ToolingError.invalidArguments(
                "The ABI \(abi) is not supported.",
                suggestion: "Use arm64-v8a or x86_64."
            )
        }
        guard let checkout = context.checkout else {
            throw ToolingError.projectNotFound("The application does not name a StateUI checkout.")
        }
        let head = package.appendingPathComponent("Platforms/Android", isDirectory: true)
        guard FileSystem.isDirectory(head) else {
            throw ToolingError.unsupportedHost(
                "\(name) has no Android head at \(head.path)."
            )
        }
        guard let gradle = toolchain.gradle else {
            throw ToolingError.toolchainMissing(
                "Gradle \(AndroidToolchain.gradleVersion) was not found.",
                suggestion: "Install it, or let the Gradle wrapper download it once."
            )
        }

        let application = Application(
            name: name, directory: package, manifest: package.appendingPathComponent("Package.swift"),
            heads: [], checkout: checkout, bundleScript: nil
        )
        let out = application.buildDirectory(for: id)
        let scratch = out
        let build = try swiftBuilder.buildInvocation(
            application: application, host: id, configuration: configuration, scratch: scratch,
            product: product, swiftSDK: toolchain.swiftSDKID, triple: triple, extra: extra,
            executable: toolchain.swift, label: "Build \(product) for Android (\(abi))"
        )
        let bin = await swiftBuilder.binPath(
            application: application, host: id, configuration: configuration, scratch: scratch,
            swiftSDK: toolchain.swiftSDKID, triple: triple, executable: toolchain.swift
        )

        let libraries = out.appendingPathComponent("jniLibs/\(abi)", isDirectory: true)
        let symbols = out.appendingPathComponent("symbols/\(abi)", isDirectory: true)
        let assets = out.appendingPathComponent("assets", isDirectory: true)
        let resourceDirectory = out.appendingPathComponent("res", isDirectory: true)
        let tools = out.appendingPathComponent("tools", isDirectory: true)

        let packaging = AndroidPackaging(runner: runner, toolchain: toolchain, abi: abi)
        let closure = await packaging.closure(product: product, bin: bin)

        var actions: [FileAction] = [
            .remove(libraries),
            .remove(symbols),
            .createDirectory(libraries),
            .createDirectory(symbols),
            .createDirectory(assets),
            .createDirectory(resourceDirectory.appendingPathComponent("drawable", isDirectory: true)),
            .createDirectory(tools),
        ]
        for library in closure {
            actions.append(.copy(library.source, to: symbols.appendingPathComponent(library.name)))
        }
        let hostDrawables = checkout.appendingPathComponent("lib/StateUI/StateUI.Android/Resources/drawable", isDirectory: true)
        if FileSystem.isDirectory(hostDrawables) {
            actions.append(.copyMatching(
                hostDrawables, matching: ".xml",
                to: resourceDirectory.appendingPathComponent("drawable", isDirectory: true)
            ))
        }

        var steps: [ProcessInvocation] = [build]
        var postSteps: [ProcessInvocation] = []

        if let strip = toolchain.ndkTool("llvm-strip") {
            for library in closure {
                postSteps.append(HostSupport.run(
                    strip, ["--strip-unneeded", "-o", libraries.appendingPathComponent(library.name).path,
                            library.source.path],
                    cwd: package, label: "Strip \(library.name)"
                ))
            }
        } else {
            for library in closure {
                actions.append(.copy(library.source, to: libraries.appendingPathComponent(library.name)))
            }
        }

        let rasterizerScriptURL = checkout.appendingPathComponent("tools/stateui/Support/rasterize-images.swift")
        let rasterizerScript = FileSystem.exists(rasterizerScriptURL) ? rasterizerScriptURL : nil
        if let compiler = await compiler(), let checkoutScript = rasterizerScript,
           FileSystem.isDirectory(resources.appendingPathComponent("Images", isDirectory: true)) {
            let rasterizer = tools.appendingPathComponent("rasterize-images")
            steps.append(HostSupport.run(
                compiler, ["-O", checkoutScript.path, "-o", rasterizer.path],
                cwd: package, label: "Compile the picture rasterizer"
            ))
            postSteps.append(HostSupport.run(
                rasterizer, [resources.appendingPathComponent("Images").path,
                             assets.appendingPathComponent("images").path],
                cwd: package, label: "Draw the application's pictures for Android"
            ))
        }

        let drawerScriptURL = checkout.appendingPathComponent("tools/stateui/Support/draw-app-icon-android.swift")
        let drawerScriptPath = FileSystem.exists(drawerScriptURL) ? drawerScriptURL : nil
        if let compiler = await compiler(), let drawerScript = drawerScriptPath,
           FileSystem.isDirectory(resources.appendingPathComponent("AppIcon", isDirectory: true)) {
            let drawer = tools.appendingPathComponent("draw-app-icon")
            steps.append(HostSupport.run(
                compiler, ["-O", drawerScript.path, "-o", drawer.path],
                cwd: package, label: "Compile the icon drawer"
            ))
            postSteps.append(HostSupport.run(
                drawer, [resources.appendingPathComponent("AppIcon").path, resourceDirectory.path],
                cwd: package, label: "Draw the application's icon"
            ))
        }

        let gradleEnvironment = [
            "JAVA_HOME": toolchain.javaHome.path,
            "ANDROID_HOME": toolchain.sdk.path,
            "ANDROID_NDK_ROOT": toolchain.ndk.path,
        ]
        let task = "assemble\(configuration.gradleTaskSuffix)"
        let gradleArguments = [
            "--project-dir", head.path,
            "--project-cache-dir", out.appendingPathComponent("gradle-project").path,
            "--console=plain", "--quiet",
            "-Pstateui.build=\(out.appendingPathComponent("gradle").path)",
            "-Pstateui.java=\(checkout.appendingPathComponent("lib/StateUI/StateUI.Android/Java").path)",
            "-Pstateui.libraries=\(out.appendingPathComponent("jniLibs").path)",
            "-Pstateui.assets=\(assets.path)",
            "-Pstateui.res=\(resourceDirectory.path)",
            task,
        ]
        postSteps.append(ProcessInvocation(
            executable: gradle, arguments: gradleArguments, environment: gradleEnvironment,
            workingDirectory: head, label: "Package \(product) with Gradle (\(configuration.rawValue))"
        ))

        let apk = apkURL(
            out.appendingPathComponent("gradle/outputs/apk/\(configuration.rawValue)"),
            package: package, product: product, configuration: configuration
        )
        return BuildPlan(
            application: name, host: id, configuration: configuration,
            steps: steps, actions: actions, postSteps: postSteps, outputs: [apk],
            notes: [
                "STATEUI_HOST=android compiles \(product) into a dynamic library for \(abi).",
                "The DT_NEEDED closure is packaged and stripped; its unstripped copies stay in symbols/\(abi).",
                "Gradle packages the host's Java layer and the head's resources; no .scripts/Android script is invoked.",
            ]
        )
    }

    // MARK: - Discovery

    private func discover() async throws -> AndroidToolchain {
        try await AndroidToolchain.discover(environment: environment, platform: platform, runner: runner)
    }

    private func deviceList(_ toolchain: AndroidToolchain) async -> [Device] {
        guard let output = await runner.output(
            toolchain.adb, ["devices", "-l"], label: "adb devices"
        ) else { return [] }
        var found: [Device] = []
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let serial = fields[0]
            let model = fields.first(where: { $0.hasPrefix("model:") })?
                .replacingOccurrences(of: "model:", with: "")
            let kind: Device.Kind = serial.hasPrefix("emulator-") ? .emulator : .physical
            found.append(Device(
                id: serial, name: model ?? serial, host: id, kind: kind,
                platform: "Android", state: "device"
            ))
        }
        if let emulator = toolchain.emulator,
           let avds = await runner.output(emulator, ["-list-avds"], label: "emulator -list-avds") {
            let running = Set(found.filter { $0.kind == .emulator }.map(\.name))
            for name in avds.split(whereSeparator: \.isNewline).map(String.init)
            where !name.isEmpty && !running.contains(name) {
                found.append(Device(
                    id: name, name: name, host: id, kind: .avd, platform: "Android", state: "stopped"
                ))
            }
        }
        return found
    }

    private func serial(_ requested: String?, toolchain: AndroidToolchain) async throws -> String {
        if let requested, !requested.isEmpty { return requested }
        if let named = environment["ANDROID_SERIAL"], !named.isEmpty { return named }
        let attached = await deviceList(toolchain).filter { $0.kind == .physical || $0.kind == .emulator }
        switch attached.count {
        case 0:
            throw ToolingError.deviceNotFound(
                "No Android device or emulator is attached.",
                suggestion: "Start an emulator, attach a device, or name one with --device."
            )
        case 1:
            return attached[0].id
        default:
            throw ToolingError.deviceNotFound(
                "Several Android devices are attached: \(attached.map(\.id).joined(separator: ", ")).",
                suggestion: "Name one with --device."
            )
        }
    }

    private func abi(_ requested: String?, toolchain: AndroidToolchain) async throws -> String {
        if let requested, ["arm64-v8a", "x86_64"].contains(requested) { return requested }
        let serial = try await serial(requested, toolchain: toolchain)
        return try await deviceABI(serial: serial, toolchain: toolchain)
    }

    private func deviceABI(serial: String, toolchain: AndroidToolchain) async throws -> String {
        guard let output = await runner.output(
            toolchain.adb, ["-s", serial, "shell", "getprop", "ro.product.cpu.abi"],
            label: "adb getprop ro.product.cpu.abi"
        ) else {
            throw ToolingError.deviceNotFound("The ABI of \(serial) could not be read.")
        }
        let abi = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["arm64-v8a", "x86_64"].contains(abi) else {
            throw ToolingError.deviceNotFound(
                "\(serial) reports the ABI \(abi), which this tool does not build for.",
                suggestion: "Use an arm64-v8a or x86_64 device."
            )
        }
        return abi
    }

    private func compiler() async -> URL? {
        if platform.operatingSystem == .macOS, let xcrun = runner.which("xcrun"),
           let output = await runner.output(xcrun, ["--find", "swiftc"], label: "xcrun --find swiftc") {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if FileSystem.isExecutable(URL(fileURLWithPath: path)) { return URL(fileURLWithPath: path) }
        }
        return runner.which("swiftc")
    }

    private func packageName(package: URL) -> String? {
        let gradle = package.appendingPathComponent("Platforms/Android/build.gradle.kts")
        guard let text = try? FileSystem.read(gradle),
              let range = text.range(of: #"namespace\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = String(text[range])
        guard let value = match.range(of: #""([^"]+)""#, options: .regularExpression) else { return nil }
        return String(match[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func packageName(apk: URL, toolchain: AndroidToolchain) async -> String? {
        guard FileSystem.exists(apk),
              let output = await runner.output(
                toolchain.aapt2, ["dump", "packagename", apk.path], label: "aapt2 dump packagename"
              ) else { return nil }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func activityName(package: URL) -> String? {
        let manifest = package.appendingPathComponent("Platforms/Android/AndroidManifest.xml")
        guard let text = try? FileSystem.read(manifest),
              let range = text.range(
                of: #"<activity[^>]*android:name\s*=\s*"([^"]+)""#,
                options: .regularExpression
              ) else { return nil }
        let element = String(text[range])
        guard let value = element.range(of: #""([^"]+)""#, options: .regularExpression) else { return nil }
        return String(element[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func apkURL(
        _ candidate: URL?, package: URL, product: String, configuration: BuildConfiguration
    ) -> URL {
        if let candidate, FileSystem.isDirectory(candidate) {
            if let found = firstAPK(in: candidate) { return found }
        }
        if let candidate, FileSystem.exists(candidate) { return candidate }
        let app = package.lastPathComponent
        return package.appendingPathComponent(
            ".build/android/gradle/outputs/apk/\(configuration.rawValue)/\(app)-\(configuration.rawValue).apk"
        )
    }

    private func firstAPK(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "apk" {
            return url
        }
        return nil
    }
}
