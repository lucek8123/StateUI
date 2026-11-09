// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

/// What each host's suite stands on: the plans the tooling writes for the machine,
/// the hosts and the budgets, checked without running anything.
final class PlanTests: XCTestCase {
    private var root: URL!
    /// The compiler is named rather than found, so a plan never depends on what a
    /// machine happens to have installed. PATH is kept, for what a plan probes: node.
    private var environment: Environment {
        Environment([
            "SWIFT_BIN": TestFixture.shell,
            "PATH": Environment.current["PATH"] ?? "",
        ])
    }
    private let linux = Platform(operatingSystem: .linux, architecture: .x86_64)
    private let macos = Platform(operatingSystem: .macOS, architecture: .arm64)
    private let windows = Platform(operatingSystem: .windows, architecture: .x86_64)

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("plans")
    }

    override func tearDown() {
        TestFixture.remove(root)
    }

    private func runner() -> CommandRunner {
        CommandRunner(executor: ScriptedProcessExecutor(), environment: environment)
    }

    /// A checkout whose application declares the hosts, resolved as the tool resolves it.
    private func context(applications: [String] = ["Gallery"], hosts: [HostID] = [.gtk, .web]) throws -> ProjectContext {
        try TestFixture.makeCheckout(at: root, applications: applications, hosts: hosts)
        return try Tooling.fixture(at: root, environment: environment).resolve().context
    }

    // MARK: - The suites standing on the machine

    func testNativeSuitesListTheMachinePackagesAndSkipMissingOnes() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery", "HelloWorld"], hosts: [.gtk])
        let suites = try NativeTestSuites.suites(
            builder: SwiftBuilder(runner: runner(), environment: environment),
            checkout: root, platform: linux
        )
        XCTAssertEqual(
            suites.map(\.name),
            ["the repository's own packages", "apps/Gallery", "apps/HelloWorld"]
        )
        XCTAssertFalse(suites.contains(where: { $0.name.contains("AppKit") }))
        for suite in suites {
            XCTAssertFalse(suite.steps[0].arguments.contains("--filter"))
        }
    }

    func testNativeSuitesOnmacOSCompileTheAppKitPackages() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        try TestFixture.write(
            "// host\n", to: root.appendingPathComponent("lib/StateUI/StateUI.AppKit/Package.swift")
        )
        let suites = try NativeTestSuites.suites(
            builder: SwiftBuilder(runner: runner(), environment: environment),
            checkout: root, platform: macos
        )
        XCTAssertEqual(
            suites.map(\.name),
            [
                "the repository's own packages", "lib/StateUI/StateUI.AppKit", "apps/Gallery",
                "apps/Gallery as an AppKit head",
            ]
        )
        let appKit = try XCTUnwrap(suites.first(where: { $0.name == "lib/StateUI/StateUI.AppKit" }))
        XCTAssertEqual(appKit.steps[0].environment["STATEUI_HOST"], "appkit")
        // The head's run keeps its own scratch directory, so the two runs do not share one.
        let head = try XCTUnwrap(suites.first(where: { $0.name == "apps/Gallery as an AppKit head" }))
        XCTAssertTrue(head.steps[0].arguments.contains("--scratch-path"))
    }

    func testNativeSuitesPassAFilterToEveryPackage() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let suites = try NativeTestSuites.suites(
            builder: SwiftBuilder(runner: runner(), environment: environment),
            checkout: root, platform: linux, filter: "Picker"
        )
        for suite in suites {
            XCTAssertEqual(suite.steps[0].arguments, ["test", "--package-path", suite.steps[0].workingDirectory.path, "--filter", "Picker"])
        }
    }

    func testFoundationSuiteRunsWholeOnTheMachineItStandsOn() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let suite = try NativeTestSuites.foundation(
            builder: SwiftBuilder(runner: runner(), environment: environment),
            checkout: root, platform: linux
        )
        XCTAssertEqual(suite.name, "StateUIFoundation on Linux")
        XCTAssertEqual(suite.steps[0].arguments, [
            "test", "--package-path", root.path, "--filter", "StateUIFoundationTests",
        ])
        // The root package names no host, so its run names none either.
        XCTAssertNil(suite.steps[0].environment["STATEUI_HOST"])
    }

    func testTestServiceNativeSuiteAsksNoHostDriver() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let executor = ScriptedProcessExecutor()
        let tooling = Tooling.fixture(at: root, executor: executor, environment: environment, platform: linux)
        let outcome = try await TestService(tooling: tooling).run(
            TestRequest(application: "Gallery", host: .gtk, suite: "native", dryRun: true)
        )
        XCTAssertEqual(outcome.status, .planned)
        XCTAssertTrue(outcome.notes.contains { $0.contains("the foundation and the library") })
        // A suite standing on the machine asks no host driver, so nothing is probed.
        let recorded = await executor.recorded()
        XCTAssertEqual(recorded.count, 0)
    }

    // MARK: - The head laid beside its build

    /// A GTK build writes its executable again, so a copy that is already
    /// running is stopped first; the icon and the entry GNOME shows for the
    /// head's ID are installed for the user beside the build.
    func testGTKBuildStopsARunningHeadAndInstallsTheDesktopsIconAndEntry() async throws {
        let ctx = try context(hosts: [.gtk])
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try TestFixture.fakeTool(named: "pkill", in: bin)
        let local = Environment([
            "SWIFT_BIN": TestFixture.shell,
            "PATH": bin.path,
            "XDG_DATA_HOME": root.appendingPathComponent("xdg", isDirectory: true).path,
        ])
        let driver = GTKHostDriver(
            runner: CommandRunner(executor: ScriptedProcessExecutor(), environment: local),
            environment: local, platform: linux
        )
        let plan = try await driver.buildPlan(BuildRequest(application: "Gallery", host: .gtk), context: ctx)

        XCTAssertEqual(plan.steps.map(\.label), ["Stop a running GalleryGTK", "Build GalleryGTK (debug)"])
        let stop = plan.steps[0]
        XCTAssertTrue(stop.allowFailure, "nothing running is not an error")
        XCTAssertEqual(stop.arguments, ["-f", "^\(plan.outputs[0].path)( |$)"], "the copy is found by its path")

        let icon = try XCTUnwrap(plan.actions.first(where: { $0.destination?.lastPathComponent == "com.stateui.gallery.svg" }))
        XCTAssertEqual(icon.kind, .copy)
        XCTAssertEqual(icon.source?.lastPathComponent, "appicon_gnome.svg")
        XCTAssertTrue(icon.destination!.path.hasSuffix("/xdg/icons/hicolor/scalable/apps/com.stateui.gallery.svg"))

        let entry = try XCTUnwrap(plan.actions.first(where: { $0.kind == .write }))
        XCTAssertEqual(entry.destination?.lastPathComponent, "com.stateui.gallery.desktop")
        XCTAssertTrue(entry.destination!.path.hasSuffix("/xdg/applications/com.stateui.gallery.desktop"))
        let text = try XCTUnwrap(entry.contents)
        for line in [
            "Name=Gallery", "Exec=\(plan.outputs[0].path)", "Icon=com.stateui.gallery",
            "StartupWMClass=GalleryGTK", "Terminal=false", "Categories=Development;",
        ] {
            XCTAssertTrue(text.contains(line), "the entry does not say \(line)")
        }
    }

    /// Where the head declares no ID, or the application holds no GNOME artwork,
    /// the build lays neither - the head runs, it just shows no icon.
    func testGTKBuildLaysNoDesktopEntryWhereTheHeadNamesNoID() async throws {
        let ctx = try context(hosts: [.gtk])
        try TestFixture.write("// a head with no ID\n", to: root.appendingPathComponent("apps/Gallery/Platforms/GTK/main.swift"))
        let driver = GTKHostDriver(runner: runner(), environment: environment, platform: linux)
        let plan = try await driver.buildPlan(BuildRequest(application: "Gallery", host: .gtk), context: ctx)
        XCTAssertFalse(plan.actions.contains(where: { $0.kind == .write }))
        XCTAssertFalse(plan.actions.contains(where: { $0.destination?.path.contains("hicolor") == true }))
    }

    // MARK: - The bundle that carries an icon

    /// A macOS machine as the plans see it: `PATH` holds the icon tools, so the
    /// bundle draws an icon and its `Info.plist` names it. Linux reads the plan;
    /// assembling the bundle itself needs macOS.
    func testAppKitBuildNamesTheIconItDrew() async throws {
        let stubs = root.appendingPathComponent("stubs", isDirectory: true)
        for name in ["mkdir", "sips", "iconutil", "codesign"] {
            try TestFixture.fakeTool(named: name, in: stubs)
        }
        let local = Environment(["SWIFT_BIN": TestFixture.shell, "PATH": stubs.path])
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.appKit])
        try TestFixture.write(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>\n",
            to: root.appendingPathComponent("apps/Gallery/Resources/AppIcon/appicon_macos.svg")
        )
        let context = try Tooling.fixture(at: root, environment: local, platform: macos).resolve().context
        let driver = AppKitHostDriver(
            runner: CommandRunner(executor: ScriptedProcessExecutor(), environment: local),
            environment: local, platform: macos
        )
        let plan = try await driver.buildPlan(
            BuildRequest(application: "Gallery", host: .appKit), context: context
        )

        XCTAssertTrue(plan.steps.contains { $0.label == "Assemble StateUI.icns" })
        let copied = try XCTUnwrap(plan.actions.first(where: { $0.destination?.lastPathComponent == "StateUI.icns" }))
        XCTAssertEqual(copied.kind, .copy)
        let plist = try XCTUnwrap(plan.actions.first(where: { $0.destination?.lastPathComponent == "Info.plist" })?.contents)
        XCTAssertTrue(plist.contains("CFBundleIconFile"), "the bundle does not name its icon")
        XCTAssertTrue(plist.contains("StateUI.icns"), "the bundle names the wrong icon")
    }

    /// With no icon tools on `PATH` the bundle lays no icon, and its `Info.plist`
    /// names nothing: a bundle that shows no custom icon is not a failure, and
    /// naming a file the plan never copied would be.
    func testAppKitBuildNamesNoIconWhenTheToolsAreAbsent() async throws {
        let local = Environment(["SWIFT_BIN": TestFixture.shell, "PATH": ""])
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.appKit])
        let context = try Tooling.fixture(at: root, environment: local, platform: macos).resolve().context
        let driver = AppKitHostDriver(
            runner: CommandRunner(executor: ScriptedProcessExecutor(), environment: local),
            environment: local, platform: macos
        )
        let plan = try await driver.buildPlan(
            BuildRequest(application: "Gallery", host: .appKit), context: context
        )
        XCTAssertFalse(plan.actions.contains { $0.destination?.lastPathComponent == "StateUI.icns" })
        XCTAssertFalse(plan.steps.contains { $0.label == "Assemble StateUI.icns" })
        let plist = try XCTUnwrap(plan.actions.first(where: { $0.destination?.lastPathComponent == "Info.plist" })?.contents)
        XCTAssertFalse(plist.contains("CFBundleIconFile"))
    }

    // MARK: - WinUI on Windows

    /// A Windows machine as the plans see it: PATH holds `taskkill`, the checkout
    /// holds the repository's WinUI tool and the host's testing package. Linux
    /// reads the plans; only the steps themselves need Windows.
    private func windowsContext(applications: [String] = ["Gallery"]) throws -> ProjectContext {
        let stubs = root.appendingPathComponent("stubs", isDirectory: true)
        try TestFixture.fakeTool(named: "taskkill", in: stubs)
        let local = Environment(["SWIFT_BIN": TestFixture.shell, "PATH": stubs.path])
        try TestFixture.makeCheckout(at: root, applications: applications, hosts: [.winUI])
        try TestFixture.write(
            "// the WinUI tool\n", to: root.appendingPathComponent("tools/stateui/Support/winui-tools.swift")
        )
        try TestFixture.write(
            "// tests\n", to: root.appendingPathComponent("lib/StateUI/StateUI.WinUI/Testing/Package.swift")
        )
        return try Tooling.fixture(at: root, environment: local).resolve().context
    }

    private func winUIDriver(_ context: ProjectContext) -> WinUIHostDriver {
        WinUIHostDriver(
            runner: CommandRunner(executor: ScriptedProcessExecutor(), environment: context.environment),
            environment: context.environment, platform: windows
        )
    }

    /// Windows stops the head that runs, generates the projection the relay
    /// includes, builds, then lays the Windows App SDK beside the executable.
    /// Nothing reaches the SDK by copying the NuGet cache, and no step reads a
    /// script of `.scripts/`.
    func testWinUIBuildStopsTheHeadGeneratesTheProjectionAndLaysTheSDKBesideIt() async throws {
        let ctx = try windowsContext()
        let driver = winUIDriver(ctx)
        let plan = try await driver.buildPlan(
            BuildRequest(application: "Gallery", host: .winUI, configuration: .debug, architecture: "x64"),
            context: ctx
        )

        #if os(Windows)
        XCTAssertEqual(
            plan.steps.map(\.label),
            ["Stop a running GalleryWinUI", "Build the WinUI tool",
             "Generate the C++/WinRT projection", "Build GalleryWinUI (debug)"]
        )
        #else
        XCTAssertEqual(
            plan.steps.map(\.label),
            ["Stop a running GalleryWinUI", "Generate the C++/WinRT projection", "Build GalleryWinUI (debug)"]
        )
        #endif
        let stop = plan.steps[0]
        XCTAssertTrue(stop.allowFailure, "a head that is not running is not an error")
        XCTAssertEqual(stop.arguments, ["/IM", "GalleryWinUI.exe", "/F"])

        #if os(Windows)
        // Swift's interpreter mode is unsupported on Windows: the tool is compiled first, and the executable runs.
        let compile = plan.steps[1]
        XCTAssertEqual(compile.label, "Build the WinUI tool")
        XCTAssertEqual(compile.executable.lastPathComponent, "swiftc.exe")
        XCTAssertEqual(Array(compile.arguments.prefix(3)), ["-O", "-static", "-o"])
        XCTAssertTrue(compile.arguments.contains { $0.hasSuffix("stateui-winui-tools.exe") })
        XCTAssertTrue(compile.arguments.last?.hasSuffix("tools/stateui/Support/winui-tools.swift") ?? false)
        let projection = plan.steps[2]
        XCTAssertEqual(projection.executable.lastPathComponent, "stateui-winui-tools.exe")
        XCTAssertEqual(projection.arguments.first, "projection")
        #else
        let projection = plan.steps[1]
        XCTAssertEqual(projection.executable.path, TestFixture.shell)
        XCTAssertTrue(projection.arguments[0].hasSuffix("tools/stateui/Support/winui-tools.swift"))
        XCTAssertEqual(projection.arguments[1], "projection")
        #endif
        XCTAssertTrue(projection.arguments.contains("--projection"))
        XCTAssertTrue(projection.arguments.contains { $0.hasSuffix("lib/StateUI/StateUI.WinUI/.projection") })
        XCTAssertEqual(projection.arguments.filter { $0 == "--package" }.count, 5)
        XCTAssertTrue(projection.arguments.contains("microsoft.windows.cppwinrt=3.0.260818.1"))
        XCTAssertTrue(projection.arguments.contains("microsoft.web.webview2=1.0.3179.45"))

        // The architecture the head is built for travels to the compiler.
        let build = plan.steps.last!
        XCTAssertTrue(build.environment.contains(where: { $0.value == "winui" }), "the manifest reads the host")
        XCTAssertEqual(build.arguments.filter { $0 == "--arch" }.count, 1)
        XCTAssertTrue(build.arguments.contains("x86_64"))

        // The SDK is laid by a step, not by copying what a cache happens to hold.
        XCTAssertFalse(plan.actions.contains { $0.source?.path.contains(".nuget") == true })
        #if os(Windows)
        XCTAssertEqual(plan.postSteps.map(\.label), ["Build the WinUI tool", "Lay the Windows App SDK beside GalleryWinUI"])
        #else
        XCTAssertEqual(plan.postSteps.map(\.label), ["Lay the Windows App SDK beside GalleryWinUI"])
        #endif
        let laid = try XCTUnwrap(plan.postSteps.first(where: { $0.label == "Lay the Windows App SDK beside GalleryWinUI" }))
        XCTAssertTrue(laid.arguments.contains("--directory"))
        XCTAssertTrue(laid.arguments.contains { $0.hasSuffix("GalleryWinUI.exe") })
        XCTAssertTrue(laid.arguments.contains("x64"))
        XCTAssertEqual(laid.arguments.filter { $0 == "--package" }.count, 4)
        XCTAssertFalse(
            laid.arguments.contains("microsoft.windows.cppwinrt=3.0.260818.1"),
            "the projection's package lays nothing beside the head"
        )

        for step in plan.steps + plan.postSteps {
            XCTAssertFalse(step.displayCommand.contains(".scripts"), "\(step.label) reads a script")
        }
        XCTAssertFalse(plan.actions.contains { $0.source?.path.contains(".scripts") == true })
        XCTAssertEqual(plan.outputs.map(\.lastPathComponent), ["GalleryWinUI.exe"])
    }

    /// A deployed folder holds the head and the runtime it needs on a machine
    /// with nothing installed; what only a build reads stays behind, and the
    /// Swift runtime is laid by nothing - it stands on the toolchain's path.
    func testWinUIDeployLaysTheCPlusRuntimeAndKeepsTheBuildProductsBehind() async throws {
        let ctx = try windowsContext()
        let destination = root.appendingPathComponent("artifacts/Gallery/WinUI/x64", isDirectory: true)
        let driver = winUIDriver(ctx)
        let plan = try await driver.deployPlan(
            DeployRequest(application: "Gallery", host: .winUI, destination: destination),
            context: ctx, build: nil
        )

        #if os(Windows)
        XCTAssertEqual(plan.postSteps.map(\.label), ["Build the WinUI tool", "Lay the C++ runtime for x64"])
        #else
        XCTAssertEqual(plan.postSteps.map(\.label), ["Lay the C++ runtime for x64"])
        #endif
        let runtime = try XCTUnwrap(plan.postSteps.first(where: { $0.label == "Lay the C++ runtime for x64" }))
        XCTAssertTrue(runtime.arguments.contains(destination.path))
        XCTAssertTrue(runtime.arguments.contains("--architecture"))

        let copy = try XCTUnwrap(plan.actions.first(where: { $0.kind == .copyTree }))
        for exclusion in [".swiftmodule", ".lib", ".exp", ".pdb", ".objlib", "plutil.exe"] {
            XCTAssertTrue(copy.excluding.contains(exclusion), "the copy does not exclude \(exclusion)")
        }
        XCTAssertTrue(
            plan.notes.contains { $0.contains("Swift runtime") },
            "a deployed folder needs the toolchain's own Swift runtime on its search path"
        )
        XCTAssertFalse(plan.build?.steps.contains { $0.displayCommand.contains(".scripts") } ?? false)
    }

    /// The host's tests are built with the projection standing, then the runner
    /// is laid out as a head of its own before each test runs in its own process.
    func testWinUISuiteGeneratesTheProjectionThenLaysTheSDKBesidetheRunner() async throws {
        let ctx = try windowsContext()
        let driver = winUIDriver(ctx)
        let plan = try await driver.testPlan(TestRequest(application: "Gallery", host: .winUI), context: ctx)
        let suite = try XCTUnwrap(plan.suites.first(where: { $0.name.hasSuffix("StateUI.WinUI/Testing") }))

        #if os(Windows)
        XCTAssertEqual(
            suite.steps.map(\.label),
            ["Build the WinUI tool", "Generate the C++/WinRT projection", "Build the WinUI host's tests"]
        )
        XCTAssertEqual(
            suite.postSteps.map(\.label),
            ["Build the WinUI tool", "Lay the Windows App SDK beside the test runner", "Test the WinUI host"]
        )
        #else
        XCTAssertEqual(suite.steps.map(\.label), ["Generate the C++/WinRT projection", "Build the WinUI host's tests"])
        XCTAssertEqual(suite.postSteps.map(\.label), ["Lay the Windows App SDK beside the test runner", "Test the WinUI host"])
        #endif
        let laid = try XCTUnwrap(
            suite.postSteps.first(where: { $0.label == "Lay the Windows App SDK beside the test runner" })
        )
        XCTAssertTrue(
            laid.arguments.contains { $0.hasSuffix("StateUIWinUITests-test-runner.exe") },
            "the runner is laid as a head is"
        )
        XCTAssertFalse(
            laid.arguments.contains { $0.lowercased().contains("webview2loader") },
            "the tool names the loader, the backend's script lays it"
        )
        let test = try XCTUnwrap(suite.postSteps.first(where: { $0.label == "Test the WinUI host" }))
        XCTAssertTrue(test.arguments.contains("--skip-build"))
        XCTAssertTrue(test.arguments.contains("--num-workers"))
        XCTAssertTrue(test.environment.contains(where: { $0.value == "winui" }))
    }

    /// Windows runs WinUI where the toolchain stands; any other operating system
    /// is refused as an operating system, not as a missing toolchain.
    func testWinUIAvailabilityDistinguishesTheOperatingSystemFromTheToolchain() async throws {
        let ctx = try windowsContext()
        let onWindows = await winUIDriver(ctx).availability(ctx)
        XCTAssertEqual(onWindows.status, .ready)

        let here = WinUIHostDriver(
            runner: CommandRunner(executor: ScriptedProcessExecutor(), environment: environment),
            environment: environment, platform: linux
        )
        let onLinux = await here.availability(ctx)
        XCTAssertEqual(onLinux.status, .unsupportedOperatingSystem)
    }

    // MARK: - The host's own suites

    func testGTKSuiteRunsTheFoundationWholeThenTheHostPackage() async throws {
        let ctx = try context(hosts: [.gtk])
        try TestFixture.write(
            "// tests\n", to: root.appendingPathComponent("lib/StateUI/StateUI.GTK/Testing/Package.swift")
        )
        let driver = GTKHostDriver(runner: runner(), environment: environment, platform: linux)
        let plan = try await driver.testPlan(TestRequest(application: "Gallery", host: .gtk), context: ctx)
        XCTAssertEqual(
            plan.suites.map(\.name),
            ["StateUIFoundation on Linux", "lib/StateUI/StateUI.GTK/Testing"]
        )
        XCTAssertEqual(plan.suites[1].steps[0].environment["STATEUI_HOST"], "gtk")

        // A part named runs that part alone, so the foundation is not run whole.
        let filtered = try await driver.testPlan(
            TestRequest(application: "Gallery", host: .gtk, filter: "Picker"), context: ctx
        )
        XCTAssertEqual(filtered.suites.map(\.name), ["lib/StateUI/StateUI.GTK/Testing"])
        XCTAssertTrue(filtered.suites[0].steps[0].arguments.contains("Picker"))
    }

    func testWebSuiteRunsInNodeUnlessABrowsersPageIsNeeded() async throws {
        guard FileSystem.findExecutable("node", environment: environment) != nil else {
            throw XCTSkip("Node.js is not on this machine.")
        }
        let ctx = try context(hosts: [.web])
        try TestFixture.write(
            "// tests\n", to: root.appendingPathComponent("lib/StateUI/StateUI.Web/Testing/Package.swift")
        )
        let driver = webDriver()
        let plain = try await driver.testPlan(TestRequest(application: "Gallery", host: .web), context: ctx)
        let suite = try XCTUnwrap(plain.suites.first)
        XCTAssertEqual(suite.steps.count, 2)
        let run = try XCTUnwrap(suite.steps.last)
        XCTAssertEqual(run.arguments.first, "__web-test")
        XCTAssertTrue(run.arguments.contains(root.appendingPathComponent("lib/StateUI/StateUI.Web/JavaScript/stateui-web.js").path))

        let inBrowser = try await driver.testPlan(
            TestRequest(application: "Gallery", host: .web, browser: true), context: ctx
        )
        XCTAssertEqual(inBrowser.suites.first?.steps.last?.arguments.first, "__web-browser-test")
        XCTAssertTrue(inBrowser.suites[0].detail.contains("browser's own page"))

        // The host's own tests that run a host, and no conformance family.
        let hostOnly = try await driver.testPlan(
            TestRequest(application: "Gallery", host: .web, suite: "host", browser: true), context: ctx
        )
        XCTAssertEqual(hostOnly.suites.first?.steps.last?.arguments.last, "--host")
    }

    func testWebSuiteBuiltOnlyStopsAfterTheRunnerIsBuilt() async throws {
        guard FileSystem.findExecutable("node", environment: environment) != nil else {
            throw XCTSkip("Node.js is not on this machine.")
        }
        let ctx = try context(hosts: [.web])
        try TestFixture.write(
            "// tests\n", to: root.appendingPathComponent("lib/StateUI/StateUI.Web/Testing/Package.swift")
        )
        let plan = try await webDriver().testPlan(
            TestRequest(application: "Gallery", host: .web, buildOnly: true), context: ctx
        )
        let suite = try XCTUnwrap(plan.suites.first)
        XCTAssertEqual(suite.steps.count, 1)
        XCTAssertTrue(suite.detail.contains("not run"))
        XCTAssertEqual(suite.outputs.count, 1)
        XCTAssertTrue(suite.outputs[0].path.hasSuffix("StateUIWebTests-test-runner.wasm"))
    }

    /// The WebAssembly SDK the toolchain's release names, answered as `swift sdk list` answers.
    private func sdkExecutor() -> ScriptedProcessExecutor {
        ScriptedProcessExecutor(answers: [
            "swift --version": ScriptedProcessExecutor.Answer(
                result: ProcessResult(exitCode: 0, standardOutput: "Swift version 6.4.2 (swiftly)")
            ),
            "swift sdk list": ScriptedProcessExecutor.Answer(
                result: ProcessResult(exitCode: 0, standardOutput: "SwiftWasm-6.4.2_wasm")
            ),
        ])
    }

    private func webDriver() -> WebHostDriver {
        WebHostDriver(
            runner: CommandRunner(executor: sdkExecutor(), environment: environment),
            environment: environment, platform: linux
        )
    }

    /// A tooling whose Swift is a stand-in that answers the WebAssembly SDK and builds
    /// nothing, so a build succeeds without a real toolchain. Everything else - gzip
    /// above all - runs as it does on this machine.
    private func webTooling() throws -> Tooling {
        let swift = root.appendingPathComponent("fake-swift", isDirectory: false)
        try TestFixture.write(
            """
            #!/bin/sh
            case "$*" in
              *--version*) echo "Swift version 6.4.2 (swiftly)" ;;
              *"sdk list"*) echo "SwiftWasm-6.4.2_wasm" ;;
              *) exit 0 ;;
            esac
            """,
            to: swift
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
        return Tooling.fixture(
            at: root, executor: RealProcessExecutor(),
            environment: Environment([
                "SWIFT_BIN": swift.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "",
            ]),
            platform: linux
        )
    }

    func testConformanceFlagsBecomeTheEnvironmentTheSuiteReads() {
        XCTAssertEqual(
            TestRequest(updateExports: true).conformanceEnvironment,
            ["STATEUI_UPDATE_EXPORTS": "1"]
        )
        XCTAssertEqual(
            TestRequest(updateExports: true, staleOnly: true).conformanceEnvironment,
            ["STATEUI_UPDATE_EXPORTS": "1", "STATEUI_STALE_ONLY": "1"]
        )
        XCTAssertTrue(TestRequest().conformanceEnvironment.isEmpty)
    }

    func testConformanceFilterNamesTheHostsClassAndFamily() {
        XCTAssertEqual(
            TestRequest(conformance: true).conformanceFilter(for: .winUI),
            "WinUIConformanceTests"
        )
        XCTAssertEqual(
            TestRequest(filter: "Button", conformance: true).conformanceFilter(for: .winUI),
            "WinUIConformanceTests.testButton"
        )
        XCTAssertEqual(
            TestRequest(filter: "WinUIConformanceTests.testButton", conformance: true)
                .conformanceFilter(for: .winUI),
            "WinUIConformanceTests.testButton"
        )
        XCTAssertNil(TestRequest().conformanceFilter(for: .winUI))
        XCTAssertEqual(HostID.android.conformanceClass, "AndroidConformanceTests")
        XCTAssertEqual(HostID.web.conformanceClass, "StateUIWebTests.WebConformanceTests")
    }

    func testAllAvailableRequestCarriesTheHostAndConformance() {
        let request = TestRequest(filter: "Button", conformance: true, allAvailableHosts: true)
        let winUI = request.forHost(.winUI, device: nil, browser: false)
        XCTAssertEqual(winUI.host, HostID.winUI)
        XCTAssertTrue(winUI.conformance)
        XCTAssertTrue(winUI.allAvailableHosts)
        XCTAssertEqual(winUI.filter, "Button")
    }

    func testCommandLineAcceptsConformance() throws {
        let parsed = try CommandLineParser.parse(["test", "--conformance", "--host", "all-available"])
        XCTAssertTrue(parsed.flag("conformance"))
        XCTAssertEqual(parsed.value("host"), "all-available")
    }

    func testCommandLineAcceptsTheTestFlagsThatCarryNoValue() throws {
        let parsed = try CommandLineParser.parse([
            "test", "--host", "web", "--in-browser", "--build-only",
            "--update-exports", "--stale", "--architecture", "x86_64", "--suite", "host",
        ])
        XCTAssertTrue(parsed.flag("in-browser"))
        XCTAssertTrue(parsed.flag("build-only"))
        XCTAssertTrue(parsed.flag("update-exports"))
        XCTAssertTrue(parsed.flag("stale"))
        XCTAssertEqual(parsed.value("architecture"), "x86_64")
        XCTAssertEqual(parsed.value("suite"), "host")
    }

    // MARK: - The budgets a shipped module is held to

    func testSizeBudgetWeighsEachVerdictAgainstItsBudget() throws {
        let module = URL(fileURLWithPath: "/site/GalleryWeb.wasm")
        XCTAssertEqual(SizeBudget(application: "Gallery", module: module, bytes: 5_700_001, budget: 5_700_000).verdict, .over)
        XCTAssertEqual(SizeBudget(application: "Gallery", module: module, bytes: 5_699_999, budget: 5_700_000).verdict, .within)
        // A twentieth or more under is a twentieth *or more*: the boundary itself counts.
        XCTAssertEqual(SizeBudget(application: "Gallery", module: module, bytes: 5_415_000, budget: 5_700_000).verdict, .muchUnder)
        XCTAssertEqual(SizeBudget(application: "Gallery", module: module, bytes: 5_415_001, budget: 5_700_000).verdict, .within)
        XCTAssertTrue(
            SizeReport(host: .web, configuration: .release, budgets: [
                SizeBudget(application: "Gallery", module: module, bytes: 6_000_000, budget: 5_700_000),
            ]).failed
        )
        XCTAssertFalse(
            SizeReport(host: .web, configuration: .release, budgets: [
                SizeBudget(application: "Gallery", module: module, bytes: 5_000_000, budget: 5_700_000),
            ]).failed
        )
    }

    func testSizeSentenceNamesTheBudgetItStandsTo() {
        let module = URL(fileURLWithPath: "/site/HelloWorldWeb.wasm")
        XCTAssertEqual(
            SizeBudget(application: "HelloWorld", module: module, bytes: 4_800_000, budget: 4_730_000).sentence,
            "HelloWorld: 4800000 bytes gzipped, over its budget of 4730000"
        )
        XCTAssertEqual(
            SizeBudget(application: "HelloWorld", module: module, bytes: 4_400_000, budget: 4_730_000).sentence,
            "HelloWorld: 4400000 bytes gzipped, a twentieth or more under its budget of 4730000 - lower it"
        )
        XCTAssertEqual(
            SizeBudget(application: "HelloWorld", module: module, bytes: 4_700_000, budget: 4_730_000).sentence,
            "HelloWorld: 4700000 bytes gzipped, within its budget of 4730000"
        )
    }

    func testSizeServiceHoldsNothingForAHostThatShipsNoPage() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        do {
            _ = try await SizeService(tooling: Tooling.fixture(at: root, environment: environment)).budgets(host: .gtk)
            XCTFail("Expected a host that ships no page to be refused.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "unsupportedHost")
        }
    }

    func testSizeServiceMeasuresEachModuleAsAPageFetchesIt() async throws {
        guard FileSystem.findExecutable("gzip") != nil else { throw XCTSkip("gzip is not on this machine.") }
        try TestFixture.makeCheckout(at: root, applications: ["HelloWorld", "Gallery"], hosts: [.web])
        // The page the module ships in, so the build the service runs stands on real assets.
        let javascript = root.appendingPathComponent("lib/StateUI/StateUI.Web/JavaScript", isDirectory: true)
        for asset in ["index.html", "stateui-web.js", "stateui-web.css"] {
            try TestFixture.write("// \(asset)\n", to: javascript.appendingPathComponent(asset))
        }
        try TestFixture.write(
            #"budgets=( "HelloWorld 20" "Gallery 100000" )"#,
            to: root.appendingPathComponent(".scripts/Web/size-budgets.sh")
        )
        // Incompressible bytes, so the gzipped weight is the module's own, not a pattern's.
        // SwiftPM writes the module where its bin path stands; the page layout copies it to the site.
        var bytes = Data()
        for _ in 0..<200 { bytes.append(UInt8.random(in: 0...255)) }
        for application in ["HelloWorld", "Gallery"] {
            let module = root.appendingPathComponent(
                "apps/\(application)/.build/web/release/\(application)Web.wasm"
            )
            try FileManager.default.createDirectory(
                at: module.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try bytes.write(to: module)
        }

        let report = try await SizeService(tooling: try webTooling()).budgets(host: .web)
        XCTAssertEqual(report.configuration, .release)
        XCTAssertEqual(report.budgets.map(\.application), ["Gallery", "HelloWorld"])
        XCTAssertEqual(report.budgets.map(\.verdict), [.muchUnder, .over])
        XCTAssertTrue(report.failed)
    }

    func testSizeServiceReportsNoBudgetsFileAsAMissingRecord() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.web])
        do {
            _ = try await SizeService(tooling: Tooling.fixture(at: root, environment: environment)).budgets(host: .web)
            XCTFail("Expected the budgets' absence to be reported.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "projectNotFound")
        }
    }

    // MARK: - Debug preparation

    /// Preparing a debugger builds the artifact the same way a normal build
    /// does: its steps, its file actions and its post-steps. Then it starts the
    /// application the debugger attaches to.
    func testDebugPreparationRunsTheWholeBuildThenStartsTheApplication() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let executor = ScriptedProcessExecutor()
        let tooling = Tooling.fixture(at: root, executor: executor, environment: environment, platform: linux)
        let built = root.appendingPathComponent("artifact.bin")
        let shell = URL(fileURLWithPath: "/bin/sh")
        let build = BuildPlan(
            application: "Gallery", host: .gtk, configuration: .debug,
            steps: [HostSupport.run(shell, ["-c", "true"], cwd: root, label: "build step")],
            actions: [.write("built", to: built)],
            postSteps: [HostSupport.run(shell, ["-c", "true"], cwd: root, label: "after step")],
            outputs: [built], notes: ["the artifact was assembled"]
        )
        let plan = DebugPlan(
            adapter: .lldbDAP, request: .launch, host: .gtk, application: "Gallery",
            configuration: .debug, name: "StateUI: Gallery (GTK)", build: build,
            preLaunch: [HostSupport.run(shell, ["-c", "true"], cwd: root, label: "start app")]
        )

        let outcome = try await DebugService(tooling: tooling).prepare(plan)

        XCTAssertEqual(outcome.status, .succeeded)
        XCTAssertEqual(outcome.outputs, [built])
        XCTAssertEqual(try String(contentsOf: built, encoding: .utf8), "built")
        let labels = await executor.recorded().map(\.label)
        XCTAssertEqual(labels, ["build step", "after step", "start app"])
    }
}
