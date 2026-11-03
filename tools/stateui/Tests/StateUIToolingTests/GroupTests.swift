// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

/// The rules a project group is built from: the releases a remote offers, the floor
/// the editors ask for, and the files a group folder holds. Git is asked for by name,
/// which means the environment's PATH - not beside the checkout, where a bare name
/// would be looked for and find nothing.
final class GroupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestFixture.temporaryDirectory("group")
        try TestFixture.makeCheckout(at: root, applications: ["Gallery"], hosts: [.gtk])
    }

    override func tearDownWithError() throws {
        TestFixture.remove(root)
    }

    /// The refs `git branch --remotes` would print: scrambled newest-first order, and
    /// a branch that names no release beside the releases.
    private var refs: String {
        "origin/1.10.0-release\norigin/1.2.0-release\norigin/0.5.0-release\norigin/main\n"
    }

    /// An executor that answers the branch listing and the remote's URL, and lets every
    /// other invocation pass.
    private func branchExecutor(remoteURL: String = "/tmp/opencode/stateui-remote") -> ScriptedProcessExecutor {
        ScriptedProcessExecutor(answers: [
            "reading the checkout's release branches": .init(
                result: ProcessResult(exitCode: 0, standardOutput: refs)
            ),
            "reading the remote origin": .init(
                result: ProcessResult(exitCode: 0, standardOutput: remoteURL + "\n")
            ),
        ])
    }

    /// Git, found where the environment is told to look, and the executor beside it.
    private func tooling(withGit git: URL, remoteURL: String = "/tmp/opencode/stateui-remote") -> (Tooling, ScriptedProcessExecutor) {
        let executor = branchExecutor(remoteURL: remoteURL)
        return (
            Tooling.fixture(
                at: root, executor: executor,
                environment: Environment(["PATH": git.deletingLastPathComponent().path]),
                platform: Platform(operatingSystem: .linux, architecture: .x86_64)
            ),
            executor
        )
    }

    /// Every key a debug configuration may carry: `name`, `type` and `request` are
    /// VS Code's own, and the four the `stateui` debugger's schema in
    /// `editors/vscode/package.json` accepts.
    private var acceptedLaunchKeys: Set<String> {
        ["name", "type", "request", "application", "configuration", "project", "host"]
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// The refusal names the option the command actually takes: `--destination`, the one
    /// `stateui group create` reads, not a name the parser would reject.
    func testAGroupNameRefusalNamesTheOptionTheCommandTakes() throws {
        let problem = try XCTUnwrap(GroupLayout.groupNameProblem("groups/MyGroup"))
        XCTAssertTrue(problem.contains("--destination"))
        XCTAssertFalse(problem.contains("--at"))
    }

    /// A remote ref names the release a group is filed under, the remote it lives on, and
    /// the branch git has to be asked for. `origin/` is the remote, not part of the branch.
    func testARemoteRefNamesTheReleaseAndTheBranchBehindIt() {
        XCTAssertEqual(GroupLayout.branch(of: "origin/1.2-release"), .init(release: "1.2", remote: "origin", branch: "1.2-release"))
        XCTAssertEqual(GroupLayout.branch(of: "remotes/origin/1.2-release"), .init(release: "1.2", remote: "origin", branch: "1.2-release"))
        XCTAssertEqual(GroupLayout.branch(of: "origin/release/1.2"), .init(release: "1.2", remote: "origin", branch: "release/1.2"))
        XCTAssertEqual(GroupLayout.branch(of: "upstream/2.0-release")?.remote, "upstream")
        XCTAssertNil(GroupLayout.branch(of: "origin/main"))
        XCTAssertNil(GroupLayout.branch(of: "origin/release"))
        XCTAssertNil(GroupLayout.branch(of: "origin/released"))
        XCTAssertNil(GroupLayout.branch(of: "1.2-release"))
        XCTAssertEqual(GroupLayout.releases(in: ["origin/1.2-release", "origin/release/1.2"]), ["1.2"])
        XCTAssertEqual(GroupLayout.branches(in: ["origin/release/1.2", "origin/1.2-release"]).map(\.branch), ["release/1.2"])
    }

    func testReleaseBranchesAreOrderedByNumberNotByLength() {
        XCTAssertEqual(
            GroupLayout.releases(in: ["origin/1.10-release", "origin/1.2-release", "origin/0.5-release", "origin/main"]),
            ["0.5", "1.2", "1.10"]
        )
    }

    func testAFloorKeepsTheReleasesAtOrAboveIt() {
        let branches = ["origin/1.2-release", "origin/1.10-release", "origin/0.5-release"]
        XCTAssertEqual(GroupLayout.releases(in: branches, floor: "1.0"), ["1.2", "1.10"])
        XCTAssertEqual(GroupLayout.releases(in: branches, floor: "1.2"), ["1.2", "1.10"])
        // `1.2` is older than `1.2.0`, so a floor naming a patch level drops it.
        XCTAssertEqual(GroupLayout.releases(in: branches, floor: "1.2.0"), ["1.10"])
        // A release that names no version is still a release, and a floor keeps it.
        XCTAssertEqual(GroupLayout.releases(in: ["origin/preview-release"], floor: "1.0"), ["preview"])
        XCTAssertEqual(GroupLayout.releases(in: branches, floor: ""), ["0.5", "1.2", "1.10"])
    }

    func testAFloorThatNamesNoVersionIsRefusedRatherThanIgnored() {
        XCTAssertNil(GroupLayout.floorProblem(""))
        XCTAssertNil(GroupLayout.floorProblem("  0.5.0 "))
        guard let problem = GroupLayout.floorProblem("preview") else {
            return XCTFail("A floor that names no version should be refused.")
        }
        XCTAssertTrue(problem.contains("preview"))
        XCTAssertTrue(problem.contains("0.5.0"))
    }

    /// The keys a group writes are the keys an editor reads. `search.exclude` is VS
    /// Code's own; `stateui.minimumRelease` is declared in `editors/vscode/package.json`
    /// and the binary applies it. Nothing here names a host or an application, because
    /// the selection is the checkout's own, in `.stateui/config.json`, and the editors
    /// read that from the tool.
    func testGroupSettingsCarryOnlyTheKeysTheEditorsRead() throws {
        let incomplete = try json(GroupLayout.settings(releases: ["0.5", "1.2"]))
        XCTAssertEqual(Set(incomplete.keys), ["search.exclude"])

        let grouped = try json(GroupLayout.settings(releases: ["1.2.0", "0.5.0", "1.10.0"]))
        XCTAssertEqual(Set(grouped.keys), ["search.exclude", "stateui.minimumRelease"])
        XCTAssertEqual(grouped["stateui.minimumRelease"] as? String, "0.5.0")
        XCTAssertNil(grouped["stateui.defaultHost"])
        XCTAssertNil(grouped["stateui.defaultApplication"])
        XCTAssertNil(grouped["stateui.host"])

        // A release that names no version is no floor, and a floor written as a value
        // the extension's pattern rejects would be marked as invalid.
        let nameless = try json(GroupLayout.settings(releases: ["preview", "1.2"]))
        XCTAssertEqual(Set(nameless.keys), ["search.exclude"])
    }

    /// Every key a debug configuration carries is one the debugger's schema accepts, and
    /// a configuration names no arguments: those are the application's own business.
    func testLaunchConfigurationsUseTheKeysTheDebuggerAccepts() throws {
        let pinned = try json(GroupLayout.launchConfiguration(releases: ["1.2.0"], application: "Gallery", host: .gtk))
        let configurations = try XCTUnwrap(pinned["configurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(Set(configurations[0].keys), acceptedLaunchKeys)
        XCTAssertEqual(configurations[0]["type"] as? String, "stateui")
        XCTAssertEqual(configurations[0]["application"] as? String, "Gallery")
        XCTAssertEqual(configurations[0]["project"] as? String, "apps/1.2.0")
        XCTAssertEqual(configurations[0]["host"] as? String, "gtk")
        XCTAssertNil(configurations[0]["args"])

        let unpinned = try json(GroupLayout.launchConfiguration(releases: ["1.2.0"], application: "Gallery"))
        let withoutHost = try XCTUnwrap(unpinned["configurations"] as? [[String: Any]])
        XCTAssertEqual(Set(withoutHost[0].keys), acceptedLaunchKeys.subtracting(["host"]))
    }

    /// Git is looked for where PATH points. Resolving it beside the checkout is what
    /// made `group releases` fail on every machine, because nothing lives there.
    func testGitIsFoundOnThePathTheEnvironmentNames() async throws {
        let git = try TestFixture.fakeTool(named: "git", in: root.appendingPathComponent("fakebin", isDirectory: true))
        let (tooling, executor) = tooling(withGit: git)
        let releases = try await GroupService(tooling: tooling).releases()
        XCTAssertEqual(releases, ["0.5.0", "1.2.0", "1.10.0"])

        let recorded = await executor.recorded()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.executable, git)
        XCTAssertEqual(recorded.first?.arguments, ["branch", "--remotes", "--format=%(refname:short)"])
    }

    func testGitNothingOnThePathCanFindIsRefusedByName() async throws {
        let executor = branchExecutor()
        let tooling = Tooling.fixture(
            at: root, executor: executor,
            environment: Environment(["PATH": ""]),
            platform: Platform(operatingSystem: .linux, architecture: .x86_64)
        )
        do {
            _ = try await GroupService(tooling: tooling).releases()
            XCTFail("Expected a checkout whose remote cannot be read to be refused.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "executableNotFound")
            XCTAssertTrue(error.toolingError.message.contains("git"))
        }
        let read = await executor.recorded()
        XCTAssertTrue(read.isEmpty)
    }

    /// A release the caller names that sits below the floor is refused with the floor in
    /// the message, so the refusal says why it is not offered.
    func testAReleaseBelowTheFloorIsRefusedWithTheFloorNamed() async throws {
        let git = try TestFixture.fakeTool(named: "git", in: root.appendingPathComponent("fakebin", isDirectory: true))
        let (tooling, _) = tooling(withGit: git)
        do {
            _ = try await GroupService(tooling: tooling).plan(
                name: "MyApp", releases: ["0.4.0"],
                at: root.appendingPathComponent("MyApp", isDirectory: true), floor: "0.5.0"
            )
            XCTFail("Expected a release below the floor to be refused.")
        } catch {
            XCTAssertEqual(error.toolingError.code, "invalidArguments")
            XCTAssertTrue(error.toolingError.message.contains("0.4.0"))
            XCTAssertTrue(error.toolingError.message.contains("0.5.0"))
        }
    }

    /// A group built at a floor holds the releases the floor offers, in order, and the
    /// files it writes are the workspace, the ignore list, the settings carrying the
    /// floor, and one debug configuration per release. Nothing is run: a plan is the
    /// steps, not their execution.
    func testTheGroupTheFloorOffersIsLaidOutFromTheFilesTheEditorsRead() async throws {
        let git = try TestFixture.fakeTool(named: "git", in: root.appendingPathComponent("fakebin", isDirectory: true))
        try ConfigurationService().saveShared(
            root: root,
            config: StateUIConfiguration(defaultHost: .gtk, defaultApplication: "Gallery", configuration: .debug)
        )
        let remoteURL = "/tmp/opencode/stateui-release-remote"
        let (tooling, executor) = tooling(withGit: git, remoteURL: remoteURL)
        let groupPath = root.appendingPathComponent("MyApp", isDirectory: true)
        let plan = try await GroupService(tooling: tooling).plan(name: "MyApp", at: groupPath, floor: "0.5.0")

        XCTAssertEqual(plan.group.releases, ["0.5.0", "1.2.0", "1.10.0"])
        XCTAssertEqual(plan.group.cloned, ["0.5.0", "1.2.0", "1.10.0"])
        XCTAssertTrue(plan.steps.allSatisfy { $0.executable == git })
        XCTAssertEqual(plan.steps.count, 3)
        // Each clone asks git for the branch as its remote holds it, cloned from that
        // remote's URL - not from the checkout on disk, which carries only the branches
        // it checked out itself.
        XCTAssertEqual(plan.steps.map { $0.arguments[2] }, ["0.5.0-release", "1.2.0-release", "1.10.0-release"])
        XCTAssertEqual(plan.steps.map { $0.arguments[4] }, [remoteURL, remoteURL, remoteURL])
        XCTAssertFalse(plan.steps.contains { $0.arguments.contains { $0.hasPrefix("origin/") } })
        XCTAssertFalse(plan.steps.contains { $0.arguments.contains { $0 == root.path } })
        XCTAssertTrue(plan.group.notes.contains { $0.contains("Releases below 0.5.0") })

        // Planning reads the listing and the remote once each; nothing is cloned yet.
        let read = await executor.recorded()
        XCTAssertEqual(read.map(\.label), ["reading the checkout's release branches", "reading the remote origin"])

        func action(_ name: String) throws -> String {
            try XCTUnwrap(plan.actions.first(where: { $0.destination?.lastPathComponent == name })?.contents)
        }

        let settings = try json(action("settings.json"))
        XCTAssertEqual(Set(settings.keys), ["search.exclude", "stateui.minimumRelease"])
        XCTAssertEqual(settings["stateui.minimumRelease"] as? String, "0.5.0")

        let launch = try json(action("launch.json"))
        let configurations = try XCTUnwrap(launch["configurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 3)
        XCTAssertEqual(Set(configurations[0].keys), acceptedLaunchKeys)
        XCTAssertEqual(configurations.map { $0["project"] as? String }, ["apps/0.5.0", "apps/1.2.0", "apps/1.10.0"])
        XCTAssertFalse(configurations.contains { $0["args"] != nil })

        let workspace = try json(action("workspace.code-workspace"))
        let folders = try XCTUnwrap(workspace["folders"] as? [[String: String]])
        XCTAssertEqual(folders.map { $0["name"] ?? "" }, ["0.5.0", "1.2.0", "1.10.0"])
        XCTAssertEqual(folders.map { $0["path"] ?? "" }, ["apps/0.5.0", "apps/1.2.0", "apps/1.10.0"])

        XCTAssertTrue(try action(".gitignore").contains("apps/"))
    }
}
