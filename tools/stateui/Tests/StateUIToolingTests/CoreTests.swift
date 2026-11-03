// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import StateUITooling

final class CoreTests: XCTestCase {
    func testHostParsing() {
        XCTAssertEqual(HostID(parsing: "macOS"), .appKit)
        XCTAssertEqual(HostID(parsing: "ios"), .uiKit)
        XCTAssertEqual(HostID(parsing: "web-assembly"), .web)
        XCTAssertNil(HostID(parsing: "beos"))
    }

    func testCommandLineParsing() throws {
        let parsed = try CommandLineParser.parse([
            "build", "--host", "gtk", "--configuration=release", "--dry-run", "extra",
        ])
        XCTAssertEqual(parsed.positionals, ["build", "extra"])
        XCTAssertEqual(parsed.value("host"), "gtk")
        XCTAssertEqual(parsed.value("configuration"), "release")
        XCTAssertTrue(parsed.flag("dry-run"))
    }

    /// A positional names the application a command works on. `--application` wins
    /// over it, a sub-command the command reads is not an application, and what is
    /// left beside the application travels to the toolchain.
    func testAPositionalNamesTheApplication() throws {
        let build = try CommandLineParser.parse(["HelloWorld", "--host", "gtk"])
        XCTAssertEqual(build.application().name, "HelloWorld")
        XCTAssertEqual(build.application().extras, [])

        let named = try CommandLineParser.parse(["--application", "Gallery"])
        XCTAssertEqual(named.application().name, "Gallery")

        let none = try CommandLineParser.parse(["--host", "gtk"])
        XCTAssertNil(none.application().name)

        let passed = try CommandLineParser.parse(["Gallery", "--", "-X", "swiftc", "-DPROBE"])
        XCTAssertEqual(passed.application().name, "Gallery")
        XCTAssertEqual(passed.application().extras, ["-X", "swiftc", "-DPROBE"])

        let plan = try CommandLineParser.parse(["plan", "Gallery", "--host", "gtk"])
        XCTAssertEqual(plan.application(besides: ["plan", "prepare"]).name, "Gallery")
        XCTAssertEqual(plan.application(besides: ["plan", "prepare"]).extras, [])

        let prepare = try CommandLineParser.parse(["prepare", "Gallery"])
        XCTAssertEqual(prepare.application(besides: ["plan", "prepare"]).name, "Gallery")

        let info = try CommandLineParser.parse(["info", "Gallery"])
        XCTAssertEqual(info.application(besides: ["list", "info"]).name, "Gallery")
        XCTAssertEqual(info.application(besides: ["list", "info"]).extras, [])

        let listed = try CommandLineParser.parse(["list"])
        XCTAssertNil(listed.application(besides: ["list", "info"]).name)
    }

    /// The options the executable reads must be options the parser accepts.
    /// `--device-host` and `--minimum` were read by commands but never declared, so a
    /// command asking for them failed with "Unknown option" before the tool ran anything.
    func testTheOptionsTheCommandsReadAreOptionsTheParserAccepts() throws {
        let parsed = try CommandLineParser.parse([
            "config", "set", "--host", "android", "--device", "emulator-5554",
            "--device-host", "android", "--minimum", "0.5.0",
        ])
        XCTAssertEqual(parsed.value("device"), "emulator-5554")
        XCTAssertEqual(parsed.value("device-host"), "android")
        XCTAssertEqual(parsed.value("minimum"), "0.5.0")
    }

    func testConfigurationRoundTrip() throws {
        let configuration = StateUIConfiguration(
            defaultHost: .android, defaultApplication: "Gallery",
            configuration: .release, devices: ["android": "emulator-5554"]
        )
        let text = try configuration.json()
        let decoded = try JSON.decoder().decode(StateUIConfiguration.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, configuration)
    }

    func testConfigurationRejectsUnknownSchema() {
        let configuration = StateUIConfiguration(schemaVersion: 99)
        XCTAssertThrowsError(try configuration.validate())
    }

    func testVersionComparison() {
        XCTAssertTrue(Version.atLeast("6.4.1", "6.4"))
        XCTAssertFalse(Version.atLeast("6.3.9", "6.4"))
        XCTAssertEqual(Version.swiftRelease(in: "Swift version 6.4.0 (swift-6.4-RELEASE)"), "6.4")
    }

    func testFraming() throws {
        let body = Data(#"{"jsonrpc":"2.0","method":"exit"}"#.utf8)
        let frame = RPCFraming.frame(body)
        let prefix = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        XCTAssertEqual(frame.prefix(prefix.count), prefix)
        XCTAssertEqual(RPCFraming.contentLength(in: Data("Content-Length: 42\r\n".utf8)), 42)
    }

    func testJSONValueRoundTrip() throws {
        let value = JSONValue.object([
            "name": .string("StateUI"),
            "count": .int(3),
            "ok": .bool(true),
            "items": .array([.string("a"), .null]),
        ])
        let data = try JSON.encoder().encode(value)
        let decoded = try JSON.decoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testScaffoldRejectsBadNames() {
        let project = ProjectInfo(
            root: URL(fileURLWithPath: "/tmp/stateui"),
            kind: .checkout,
            applications: [],
            checkout: URL(fileURLWithPath: "/tmp/stateui"),
            configurationDirectory: URL(fileURLWithPath: "/tmp/stateui/.stateui")
        )
        XCTAssertThrowsError(try ScaffoldService().create(name: "Bad.Name", appsDirectory: nil, project: project))
        XCTAssertThrowsError(try ScaffoldService().create(name: "StateUI", appsDirectory: nil, project: project))
    }

    /// GNOME shows a head's window under the ID the head passes the host, and
    /// the entry that starts it names that ID as its icon.
    func testGTKDesktopReadsTheHeadsOwnIDAndWritesItsEntry() throws {
        let root = try TestFixture.temporaryDirectory("desktop")
        defer { TestFixture.remove(root) }

        let main = try TestFixture.write(
            "exit(StateUIGTK.run(applicationID: \"com.stateui.gallery\"))\n",
            to: root.appendingPathComponent("Platforms/GTK/main.swift")
        )
        XCTAssertEqual(GTKDesktop.applicationID(in: main), "com.stateui.gallery")
        XCTAssertNil(
            GTKDesktop.applicationID(
                in: try TestFixture.write("// no id\n", to: root.appendingPathComponent("Platforms/GTK/other.swift"))
            ),
            "a head that names no ID has no entry to write")

        XCTAssertEqual(
            GTKDesktop.dataDirectory(Environment(["XDG_DATA_HOME": "/srv/xdg"])),
            URL(fileURLWithPath: "/srv/xdg"),
            "the spec's variable names where the user's data stands")
        for unset in [Environment([:]), Environment(["XDG_DATA_HOME": ""])] {
            XCTAssertEqual(
                GTKDesktop.dataDirectory(unset),
                FileSystem.home().appendingPathComponent(".local/share", isDirectory: true),
                "where the variable is unset or empty, the spec's default stands")
        }

        XCTAssertEqual(
            GTKDesktop.entry(
                name: "Gallery", executable: URL(fileURLWithPath: "/build/GalleryGTK"),
                applicationID: "com.stateui.gallery", wmClass: "GalleryGTK"
            ),
            """
            [Desktop Entry]
            Type=Application
            Name=Gallery
            Exec=/build/GalleryGTK
            Icon=com.stateui.gallery
            StartupWMClass=GalleryGTK
            Terminal=false
            Categories=Development;

            """
        )
    }

    /// A report narrowed to one host names only what that host asks for, and a
    /// requirement states the version and platform it stands on rather than a
    /// generic "toolchain missing".
    func testToolchainReportNamesOnlyWhatTheRequestedHostNeeds() async throws {
        let executor = ScriptedProcessExecutor()
        let service = ToolchainService(
            executor: executor, environment: Environment(["PATH": ""]),
            platform: Platform(operatingSystem: .linux, architecture: .x86_64)
        )

        let gtk = await service.report(hosts: [.gtk])
        XCTAssertFalse(gtk.findings.contains { $0.component.hasPrefix("Android") }, "GTK asks for nothing Android needs")
        XCTAssertTrue(gtk.findings.contains { $0.component.hasPrefix("Swift") })

        let android = await service.report(hosts: [.android])
        let finding = try XCTUnwrap(android.findings.first(where: { $0.component.hasPrefix("Android") }))
        XCTAssertEqual(finding.status, .missing)
        XCTAssertTrue(finding.blocking, "without the Android toolchain no Android head is built")
        XCTAssertFalse(finding.advice.isEmpty, "a missing toolchain says what to install")
        XCTAssertFalse(gtk.missing.contains { $0.component.hasPrefix("Android") })
    }
}
