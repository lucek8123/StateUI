// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

/// The proofs a suite owes - its API records, its conformance verdicts, a host's listing - and the
/// environment a run stands in.
final class ArchitectureTests: XCTestCase {
    private var root: URL!
    private var environment: Environment {
        Environment([
            "SWIFT_BIN": TestFixture.shell,
            "PATH": Environment.current["PATH"] ?? "",
            "STATEUI_ACCENT": "blue",
        ])
    }

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("architecture")
    }

    override func tearDown() {
        TestFixture.remove(root)
    }

    private func tooling(_ executor: any ProcessExecuting = ScriptedProcessExecutor()) throws -> Tooling {
        try TestFixture.makeCheckout(at: root)
        return Tooling.fixture(at: root, executor: executor, environment: environment)
    }

    // MARK: - Revisions

    func testConformanceRevisionReadsEveryHostsThenTheHosts() throws {
        try TestFixture.write(
            """
            # family every-host host
            Button 3
            android Button 5
            DatePicker 2
            """,
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        let service = ConformanceService(checkout: root)
        XCTAssertEqual(try service.revision(host: .android, family: "Button"), "3.5")
        XCTAssertEqual(try service.revision(host: .android, family: "DatePicker"), "2.1")
        XCTAssertEqual(try service.revision(host: .gtk, family: "Button"), "3.1")
    }

    func testFamiliesReadsAMainActorConformanceMethod() throws {
        try TestFixture.write(
            """
            @MainActor func testButton() { conform(ButtonTests.self) }
            func testSomethingElse() { }
            """,
            to: root.appendingPathComponent(
                "lib/StateUI/StateUI.AppKit/Tests/Conformance/AppKitConformanceTests.swift"
            )
        )
        XCTAssertEqual(try ConformanceService(checkout: root).families(host: .appKit), ["Button"])
    }

    func testStaleFamiliesAreThoseWhoseMarksStandAtAnotherRevision() throws {
        try TestFixture.write(
            "Button 3\nDatePicker 2\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        try TestFixture.write(
            """
            func testButton() throws { try conform() }
            func testDatePicker() throws { try conform() }
            """,
            to: root.appendingPathComponent(
                "lib/StateUI/StateUI.Android/Tests/Sources/Conformance/AndroidConformanceTests.swift"
            )
        )
        try TestFixture.write(
            "# revision 3.1\nmark\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nmark\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/DatePicker.txt")
        )
        let service = ConformanceService(checkout: root)
        XCTAssertEqual(try service.families(host: .android), ["Button", "DatePicker"])
        XCTAssertEqual(try service.staleFamilies(host: .android), ["DatePicker"])
    }

    // MARK: - Exports

    func testExportCheckHoldsTheDeviceVerdictsToTheExports() async throws {
        try TestFixture.write(
            "Button 1\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        try TestFixture.write(
            "declared\n",
            to: root.appendingPathComponent("lib/StateUI/exports/android.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nverdict\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
        )
        let executor = ScriptedProcessExecutor(answers: [
            "android.txt": answer("declared\n"),
            "marks/android": answer("Button.txt\n"),
            "marks/android/Button.txt": answer("verdict\n"),
        ])
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: false, staleOnly: false, filtered: false
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling(executor))
        XCTAssertEqual(outcome.status, .passed, outcome.detail ?? "")
    }

    func testExportCheckFailsWhenAVerdictChanged() async throws {
        try TestFixture.write(
            "Button 1\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        try TestFixture.write(
            "declared\n",
            to: root.appendingPathComponent("lib/StateUI/exports/android.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nverdict\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
        )
        let executor = ScriptedProcessExecutor(answers: [
            "android.txt": answer("declared\n"),
            "marks/android": answer("Button.txt\n"),
            "marks/android/Button.txt": answer("another verdict\n"),
        ])
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: false, staleOnly: false, filtered: false
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling(executor))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.detail?.contains("Button.txt") == true)
    }

    func testStaleExportCheckComparesVerdictsWithoutTheRevisionLine() async throws {
        try TestFixture.write(
            "Button 2\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nverdict\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nother\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/DatePicker.txt")
        )
        let executor = ScriptedProcessExecutor(answers: [
            "marks/android": answer("Button.txt\n"),
            "marks/android/Button.txt": answer("verdict\n"),
        ])
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: false, staleOnly: true, filtered: true
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling(executor))
        XCTAssertEqual(outcome.status, .passed, outcome.detail ?? "")
    }

    func testExportCheckReadsAColumnarMarksListing() async throws {
        try TestFixture.write(
            "Button 1\nDatePicker 1\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        try TestFixture.write(
            "declared\n",
            to: root.appendingPathComponent("lib/StateUI/exports/android.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nverdict\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
        )
        try TestFixture.write(
            "# revision 1.1\nother\n",
            to: root.appendingPathComponent("lib/StateUI/exports/marks/android/DatePicker.txt")
        )
        let executor = ScriptedProcessExecutor(answers: [
            "android.txt": answer("declared\n"),
            // `ls` writes columns when its output is not a terminal, and no newline at all.
            "marks/android": answer("Button.txt   DatePicker.txt"),
            "marks/android/Button.txt": answer("verdict\n"),
            "marks/android/DatePicker.txt": answer("other\n"),
        ])
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: false, staleOnly: false, filtered: false
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling(executor))
        XCTAssertEqual(outcome.status, .passed, outcome.detail ?? "")
        XCTAssertEqual(outcome.detail, "2 verdicts hold")
    }

    func testExportCheckWritesTheDeviceVerdictsUnderTheirRevision() async throws {
        try TestFixture.write(
            "Button 2\n",
            to: root.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
        )
        let executor = ScriptedProcessExecutor(answers: [
            "android.txt": answer("declared\n"),
            "marks/android": answer("Button.txt\n"),
            "marks/android/Button.txt": answer("verdict\n"),
        ])
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: true, staleOnly: false, filtered: false
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling(executor))
        XCTAssertEqual(outcome.status, .passed, outcome.detail ?? "")
        XCTAssertEqual(
            try FileSystem.read(root.appendingPathComponent("lib/StateUI/exports/android.txt")),
            "declared\n"
        )
        XCTAssertEqual(
            try FileSystem.read(
                root.appendingPathComponent("lib/StateUI/exports/marks/android/Button.txt")
            ),
            "# revision 2.1\nverdict\n"
        )
    }

    func testFilteredExportCheckIsSkipped() async throws {
        let check = ConformanceExportsCheck(
            host: .android, device: "emulator-5554", adb: URL(fileURLWithPath: "/adb"),
            package: "com.stateui.android.tests", update: false, staleOnly: false, filtered: true
        )
        let outcome = await ExportService(checkout: root).check(check, tooling: try tooling())
        XCTAssertEqual(outcome.status, .skipped)
    }

    func testVerdictsAloneDropsOnlyTheRevisionLine() {
        XCTAssertEqual(
            ExportService.verdictsAlone("# revision 1.1\none\ntwo\n"),
            "one\ntwo"
        )
    }

    // MARK: - API records

    func testAPIReportInvocationCarriesTheModuleAndUnsetsTheHost() throws {
        let executor = ScriptedProcessExecutor()
        let service = APIReportService(tooling: try tooling(executor))
        let module = APIModule(
            name: "StateUIWeb", modules: URL(fileURLWithPath: "/products"),
            triple: "wasm32-unknown-wasip1", sdk: "/sdk",
            arguments: ["-Xcc", "-fmodule-map-file=/CStateUIWeb/module.modulemap"]
        )
        let invocations = try service.invocations(
            modules: [module], repository: root, environment: ["STATEUI_UPDATE_EXPORTS": "1"]
        )
        XCTAssertEqual(invocations.count, 1)
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(Array(invocation.arguments.prefix(4)), [
            "test", "--package-path", root.path, "--filter",
        ])
        XCTAssertEqual(invocation.environment["STATEUI_API_MODULE"], "StateUIWeb")
        XCTAssertEqual(invocation.environment["STATEUI_API_MODULES"], "/products")
        XCTAssertEqual(invocation.environment["STATEUI_API_TRIPLE"], "wasm32-unknown-wasip1")
        XCTAssertEqual(invocation.environment["STATEUI_API_SDK"], "/sdk")
        XCTAssertEqual(
            invocation.environment["STATEUI_API_ARGUMENTS"],
            "-Xcc -fmodule-map-file=/CStateUIWeb/module.modulemap"
        )
        XCTAssertEqual(invocation.environment["STATEUI_UPDATE_EXPORTS"], "1")
        XCTAssertEqual(invocation.unsetEnvironment, ["STATEUI_HOST"])
    }

    // MARK: - Android listing

    func testAndroidListingFindsATestListedNowhere() throws {
        let package = root.appendingPathComponent("lib/StateUI/StateUI.Android/Tests", isDirectory: true)
        let runner = package.appendingPathComponent("Sources/Support/AndroidTestRunner.swift")
        try TestFixture.write(
            """
            class Thing: XCTestCase {
                static var allTests = [("testThing", testThing)]
                func testThing() {}
                func testUnlisted() {}
            }
            """,
            to: package.appendingPathComponent("Sources/Host/Thing.swift")
        )
        try TestFixture.write(
            "let testCases = [testCase(Thing.allTests)]\n", to: runner
        )
        let outcome = AndroidTestListing.check(AndroidListingCheck(package: package, runner: runner))
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.detail?.contains("testUnlisted") == true)
    }

    func testAndroidListingPassesWhenEveryTestAndCaseIsListed() throws {
        let package = root.appendingPathComponent("lib/StateUI/StateUI.Android/Tests", isDirectory: true)
        let runner = package.appendingPathComponent("Sources/Support/AndroidTestRunner.swift")
        try TestFixture.write(
            """
            class Thing: XCTestCase {
                static var allTests = [("testThing", testThing)]
                func testThing() {}
            }
            """,
            to: package.appendingPathComponent("Sources/Host/Thing.swift")
        )
        try TestFixture.write(
            "let testCases = [testCase(Thing.allTests)]\n", to: runner
        )
        let outcome = AndroidTestListing.check(AndroidListingCheck(package: package, runner: runner))
        XCTAssertEqual(outcome.status, .passed, outcome.detail ?? "")
    }

    // MARK: - Session

    func testTestSessionMergesTheConformanceFlagsOverTheApplicationsVariables() throws {
        let workspace = try tooling().resolve()
        let request = TestRequest(conformance: true, updateExports: true, staleOnly: true)
        let values = TestSession(request: request, context: workspace.context)
            .environment(prefix: "SIMCTL_CHILD_")
        XCTAssertEqual(values["SIMCTL_CHILD_STATEUI_ACCENT"], "blue")
        XCTAssertEqual(values["SIMCTL_CHILD_STATEUI_UPDATE_EXPORTS"], "1")
        XCTAssertEqual(values["SIMCTL_CHILD_STATEUI_STALE_ONLY"], "1")
    }

    // MARK: - Boot

    func testOnlyAHostWithADeviceCanBootOne() async throws {
        do {
            _ = try await DeviceService(tooling: try tooling()).boot(host: .gtk, name: "anything")
            XCTFail("GTK has no device this tool can start.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "unsupportedHost")
        }
    }

    private func answer(_ text: String) -> ScriptedProcessExecutor.Answer {
        ScriptedProcessExecutor.Answer(result: ProcessResult(exitCode: 0, standardOutput: text))
    }
}
