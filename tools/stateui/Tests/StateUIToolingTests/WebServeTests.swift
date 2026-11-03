// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

/// Giving up the page a Web run left serving. The server is a detached process, so what
/// the tests hand to `stop` is the facts file it writes beside the build plus a process
/// that holds the port named there.
final class WebServeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("webserve")
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.web])
    }

    override func tearDown() {
        TestFixture.remove(root)
        root = nil
    }

    private func factsFile(port: Int, url: String, pid: Int32?) throws -> URL {
        let directory = root
            .appendingPathComponent("apps/Gallery/.build/web", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("server.json")
        var facts: [String: Any] = ["url": url, "port": port, "root": directory.path]
        if let pid { facts["pid"] = Int(pid) }
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted]).write(to: file)
        return file
    }

    /// A process that outlives the test unless something gives it up: `stop` is what
    /// gives it up, so the test asserts it went.
    private func spawnHoldingProcess() throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        return child
    }

    func testStopGivesUpThePageTheFactsName() throws {
        let child = try spawnHoldingProcess()
        XCTAssertTrue(child.isRunning)
        let file = try factsFile(port: 8460, url: "http://localhost:8460/", pid: Int32(child.processIdentifier))

        let page = try WebServerService(tooling: Tooling.fixture(at: root)).stop()
        XCTAssertEqual(page.url, "http://localhost:8460/")
        XCTAssertEqual(page.port, 8460)
        XCTAssertEqual(page.pid, Int32(child.processIdentifier))

        var waited = 0
        while child.isRunning && waited < 60 { usleep(50_000); waited += 1 }
        XCTAssertFalse(child.isRunning, "the process the facts named is still serving")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the facts outlived the page")
        child.waitUntilExit()
    }

    func testStopRefusesWhenNoPageIsServed() throws {
        do {
            _ = try WebServerService(tooling: Tooling.fixture(at: root)).stop()
            XCTFail("stop answered when nothing serves a page")
        } catch {
            let structured = error.toolingError
            XCTAssertEqual(structured.code, "notServing")
            XCTAssertTrue(structured.message.contains("Gallery"))
        }
    }

    /// Facts can outlive the process they name - a run killed by other means leaves the
    /// file behind - so the refusal says nothing is listening and takes the file with it.
    func testStopClearsFactsThatNameNoLiveProcess() throws {
        let file = try factsFile(port: 8460, url: "http://localhost:8460/", pid: 999_999)

        do {
            _ = try WebServerService(tooling: Tooling.fixture(at: root)).stop()
            XCTFail("stop answered for a process that is not there")
        } catch {
            XCTAssertEqual(error.toolingError.code, "notServing")
            XCTAssertTrue(error.toolingError.message.contains("is not listening"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Facts written by an older binary name no process, so they cannot be treated as
    /// something stoppable, and are left where the developer can read them.
    func testStopRefusesFactsNamingNoProcess() throws {
        let file = try factsFile(port: 8460, url: "http://localhost:8460/", pid: nil)

        do {
            _ = try WebServerService(tooling: Tooling.fixture(at: root)).stop()
            XCTFail("stop answered for facts that name nothing")
        } catch {
            XCTAssertEqual(error.toolingError.code, "notServing")
            XCTAssertTrue(error.toolingError.message.contains("names no served page"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "facts naming nothing are left alone")
    }

    func testRPCStopsTheServedPageAndReportsIt() async throws {
        let child = try spawnHoldingProcess()
        _ = try factsFile(port: 8461, url: "http://localhost:8461/", pid: Int32(child.processIdentifier))

        let result = try await ToolingRPC(tooling: Tooling.fixture(at: root)).handle(method: "web/stop", params: nil)
        XCTAssertEqual(result["stopped"], JSONValue.bool(true))
        XCTAssertEqual(result["port"], JSONValue.int(8461))
        XCTAssertEqual(result["pid"], JSONValue.int(Int(child.processIdentifier)))

        var waited = 0
        while child.isRunning && waited < 60 { usleep(50_000); waited += 1 }
        XCTAssertFalse(child.isRunning)
        child.waitUntilExit()
    }

    func testInitializeNamesTheAbilityToGiveUpAServedPage() async throws {
        let result = try await ToolingRPC(tooling: Tooling.fixture(at: root)).handle(
            method: "initialize", params: .object(["protocolVersion": .int(ToolingVersion.protocolVersion)])
        )
        XCTAssertEqual(result["capabilities"]?["stopServed"], JSONValue.bool(true))
    }

    /// A detached Web run must start its server rather than skip it: the step is a
    /// background one, so the executor launches it and `stop` has a process to give up. An
    /// observed step would be skipped when detached, and the run would answer a URL
    /// nothing serves.
    func testWebRunPlanServesAsABackgroundStep() async throws {
        let tooling = Tooling.fixture(at: root)
        let workspace = try tooling.resolve(application: "Gallery", host: .web)
        let driver = try tooling.driver(for: .web)
        let plan = try await driver.runPlan(
            RunRequest(application: "Gallery", host: .web, configuration: .debug, detach: true),
            context: workspace.context,
            build: nil
        )

        XCTAssertTrue(plan.detached)
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.mode, .background)
        XCTAssertTrue(step.label.contains("Serve Gallery"))
        XCTAssertTrue(step.arguments.contains("__serve-web"))
    }
}
