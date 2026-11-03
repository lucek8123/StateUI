// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

final class ProjectTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("project")
    }

    override func tearDownWithError() throws {
        TestFixture.remove(root)
    }

    func testCheckoutDiscoveryFindsApplicationsAndHeads() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery", "HelloWorld"], hosts: [.gtk, .web])
        let tooling = Tooling.fixture(at: root)
        let project = try tooling.project()
        XCTAssertEqual(project.kind, .checkout)
        XCTAssertEqual(project.checkout, root)
        XCTAssertEqual(project.applications.map(\.name), ["Gallery", "HelloWorld"])
        let gallery = try XCTUnwrap(project.application(named: "Gallery"))
        XCTAssertEqual(Set(gallery.availableHosts), [.gtk, .web])
        XCTAssertEqual(project.configurationDirectory.path, root.appendingPathComponent(".stateui").path)
    }

    func testDiscoveryWalksUpFromAnApplicationDirectory() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let nested = root.appendingPathComponent("apps/Gallery/Platforms/GTK")
        let project = try ProjectDiscovery().discover(explicit: nested)
        XCTAssertEqual(project.root.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(project.applications.map(\.name), ["Gallery"])
    }

    /// A group's applications name no checkout of their own; the checkout the
    /// group was found with is the one they are described against.
    func testApplicationResolverKeepsTheCheckoutHint() throws {
        let application = root.appendingPathComponent("apps/Widgets")
        try TestFixture.write(
            "// swift-tools-version: 6.0\nimport PackageDescription\n",
            to: application.appendingPathComponent("Package.swift")
        )
        try TestFixture.write("// head\n", to: application.appendingPathComponent("Platforms/GTK/main.swift"))
        let hint = root.appendingPathComponent("StateUI", isDirectory: true)
        let found = ApplicationResolver().applications(in: root, checkoutHint: hint)
        XCTAssertEqual(found.first?.checkout, hint)
    }

    func testDiscoveryRejectsAnEmptyDirectory() throws {
        XCTAssertThrowsError(try ProjectDiscovery().discover(explicit: root)) { error in
            XCTAssertEqual(error.toolingError.code, "projectNotFound")
        }
    }

    func testLocalConfigurationMergesOverSharedAndIsGitignored() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let shared = StateUIConfiguration(
            defaultHost: .gtk, defaultApplication: "Gallery", configuration: .release
        )
        try ConfigurationService().saveShared(root: root, config: shared)
        try ConfigurationService().saveLocal(root: root) { local in
            local.defaultHost = .web
            local.devices["android"] = "emulator-5554"
        }
        let merged = try ConfigurationService().load(root: root)
        XCTAssertEqual(merged.defaultHost, .web)
        XCTAssertEqual(merged.defaultApplication, "Gallery")
        XCTAssertEqual(merged.configuration, .release)
        XCTAssertEqual(merged.devices["android"], "emulator-5554")

        let gitignore = try FileSystem.read(root.appendingPathComponent(".gitignore"))
        XCTAssertTrue(gitignore.contains(".stateui/local.json"))
    }

    func testConfigurationRejectsAFutureSchema() throws {
        try FileSystem.makeDirectory(root.appendingPathComponent(".stateui"))
        try TestFixture.write(
            #"{"schemaVersion": 99, "defaultHost": "gtk"}"#,
            to: root.appendingPathComponent(".stateui/config.json")
        )
        XCTAssertThrowsError(try ConfigurationService().load(root: root)) { error in
            XCTAssertEqual(error.toolingError.code, "invalidConfiguration")
        }
    }

    func testResolveUsesStoredSelectionsAndDefaultsToOneHead() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let tooling = Tooling.fixture(at: root)
        let workspace = try tooling.resolve()
        XCTAssertEqual(workspace.application?.name, "Gallery")
        XCTAssertEqual(workspace.host, .gtk)
        XCTAssertEqual(workspace.configuration, .debug)
    }

    func testScaffoldCopiesHelloWorldAndRenamesIt() throws {
        let checkout = try TestFixture.makeCheckout(
            at: root, applications: ["HelloWorld"], hosts: [.gtk]
        )
        try TestFixture.write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "HelloWorld",
                dependencies: [.package(path: "../..")],
                targets: [.executableTarget(name: "HelloWorldGTK", path: "Sources/HelloWorldGTK")]
            )
            """,
            to: checkout.appendingPathComponent("apps/HelloWorld/Package.swift")
        )
        try TestFixture.write(
            "// HelloWorld\n",
            to: checkout.appendingPathComponent("apps/HelloWorld/Platforms/GTK/main.swift")
        )
        try TestFixture.write(
            "print(\"HelloWorld\")\n",
            to: checkout.appendingPathComponent("apps/HelloWorld/Sources/HelloWorldGTK/main.swift")
        )

        let tooling = Tooling.fixture(at: checkout)
        let project = try tooling.project()
        let created = try ScaffoldService().create(name: "Widgets", appsDirectory: nil, project: project)
        XCTAssertEqual(created.standardizedFileURL, checkout.appendingPathComponent("apps/Widgets").standardizedFileURL)
        let package = try FileSystem.read(created.appendingPathComponent("Package.swift"))
        XCTAssertTrue(package.contains("name: \"Widgets\""))
        XCTAssertFalse(package.contains("HelloWorld"))
        let source = try FileSystem.read(
            created.appendingPathComponent("Sources/WidgetsGTK/main.swift")
        )
        XCTAssertTrue(source.contains("Widgets"))
    }

    func testScaffoldRejectsDuplicateAndInvalidNames() throws {
        let checkout = try TestFixture.makeCheckout(
            at: root, applications: ["HelloWorld"], hosts: [.gtk]
        )
        let project = try Tooling.fixture(at: checkout).project()
        XCTAssertThrowsError(try ScaffoldService().create(name: "HelloWorld", appsDirectory: nil, project: project))
        XCTAssertThrowsError(try ScaffoldService().create(name: "1Bad", appsDirectory: nil, project: project))
        XCTAssertThrowsError(try ScaffoldService().create(name: "StateUI", appsDirectory: nil, project: project))
    }

    /// An editor's settings file need not exist yet: configuring a host writes one, keeping
    /// whatever keys were already there. Nothing naming a host or an application is written,
    /// because the selection is the checkout's own and the editors read it from the tool.
    func testLSPConfigureWritesSettingsWhenTheEditorHasNone() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let tooling = Tooling.fixture(
            at: root, executor: ScriptedProcessExecutor(),
            environment: Environment(["SWIFT_BIN": "/bin/sh"]),
            platform: Platform(operatingSystem: .linux, architecture: .x86_64)
        )
        let outcome = try await LSPService(tooling: tooling).configure(host: .gtk)
        XCTAssertEqual(outcome.status, .succeeded)
        let settings = try FileSystem.read(root.appendingPathComponent(".vscode/settings.json"))
        XCTAssertTrue(settings.contains("\"search.exclude\""))
        XCTAssertFalse(settings.contains("stateui.host"))
        XCTAssertFalse(settings.contains("stateui.application"))
    }

    /// Existing settings survive configuration; only the keys the tool owns change. A host
    /// the repository named itself is left as the repository wrote it.
    func testLSPConfigureKeepsUnrelatedSettings() async throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        try TestFixture.write(
            #"{"editor.tabSize": 2, "stateui.host": "web"}"#,
            to: root.appendingPathComponent(".vscode/settings.json")
        )
        let tooling = Tooling.fixture(
            at: root, executor: ScriptedProcessExecutor(),
            environment: Environment(["SWIFT_BIN": "/bin/sh"]),
            platform: Platform(operatingSystem: .linux, architecture: .x86_64)
        )
        _ = try await LSPService(tooling: tooling).configure(host: .gtk)
        let settings = try FileSystem.read(root.appendingPathComponent(".vscode/settings.json"))
        XCTAssertTrue(settings.contains("\"editor.tabSize\" : 2"))
        XCTAssertTrue(settings.contains("\"stateui.host\" : \"web\""))
        XCTAssertTrue(settings.contains("\"search.exclude\""))
    }

    func testProjectServiceSelectsAndPersistsHostApplicationAndDevice() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk, .android])
        let tooling = Tooling.fixture(at: root)
        let service = ProjectService(tooling: tooling)
        try service.select(
            host: .android, application: "Gallery", configuration: .release,
            device: "emulator-5554", deviceHost: .android
        )
        let configuration = try tooling.loadConfiguration(tooling.project())
        XCTAssertEqual(configuration.defaultHost, .android)
        XCTAssertEqual(configuration.defaultApplication, "Gallery")
        XCTAssertEqual(configuration.configuration, .release)
        XCTAssertEqual(configuration.devices["android"], "emulator-5554")
    }

    /// A typed name no discovery answers is refused rather than stored: an editor's
    /// picker offers only what the checkout holds, so the named path is the one that can
    /// select something nothing can build.
    func testProjectServiceRefusesAnApplicationThatStandsNowhere() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery", "HelloWorld"], hosts: [.gtk])
        let tooling = Tooling.fixture(at: root)
        let service = ProjectService(tooling: tooling)

        do {
            try service.select(application: "NoSuchApp")
            XCTFail("a name nothing answers was stored")
        } catch {
            let structured = error.toolingError
            XCTAssertEqual(structured.code, "applicationNotFound")
            XCTAssertTrue(structured.message.contains("NoSuchApp"))
            XCTAssertEqual(structured.context["applications"], "Gallery, HelloWorld")
        }

        // Nothing was written, so the selection the checkout already held stands.
        let configuration = try tooling.loadConfiguration(tooling.project())
        XCTAssertNil(configuration.defaultApplication)
    }

    func testProjectServiceStoresAnApplicationTheCheckoutHolds() throws {
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
        let tooling = Tooling.fixture(at: root)
        try ProjectService(tooling: tooling).select(application: "Gallery")
        XCTAssertEqual(try tooling.loadConfiguration(tooling.project()).defaultApplication, "Gallery")
    }
}
