// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a project group holds: one folder, one application per StateUI release, and a workspace
/// that opens all of them. The binary writes what a group needs and nothing else.
public struct ProjectGroup: Codable, Sendable {
    public let path: String
    public let releases: [String]
    public let applications: [String]
    /// Whether each release was cloned or was already sitting in the group.
    public let cloned: [String]
    public let reused: [String]
    public let files: [String]
    public let notes: [String]

    public init(path: String, releases: [String], applications: [String], cloned: [String], reused: [String], files: [String], notes: [String] = []) {
        self.path = path
        self.releases = releases
        self.applications = applications
        self.cloned = cloned
        self.reused = reused
        self.files = files
        self.notes = notes
    }
}

/// A group's planned steps and files: cloning each release, writing the workspace. Running it is
/// separate, so `stateui group create --dry-run` says what a group would become. What the group
/// holds, and why it was built that way, is carried by the group itself.
public struct GroupPlan: Codable, Sendable {
    public let path: String
    public let steps: [ProcessInvocation]
    public let actions: [FileAction]
    public let group: ProjectGroup

    public init(path: String, steps: [ProcessInvocation], actions: [FileAction], group: ProjectGroup) {
        self.path = path
        self.steps = steps
        self.actions = actions
        self.group = group
    }
}

/// The rules a group is built from. Pure, so they are tested without a repository.
public enum GroupLayout {
    /// A release and the branch its remote holds it under. The release is what a group is
    /// named by; the remote and branch are what cloning it asks git for.
    public struct ReleaseBranch: Codable, Sendable, Hashable {
        public let release: String
        /// The remote the branch is on: `origin`.
        public let remote: String
        /// As that remote holds it, without the remote's prefix: `1.2-release`.
        public let branch: String

        /// The remote ref a checkout lists: `origin/1.2-release`.
        public var ref: String { "\(remote)/\(branch)" }

        public init(release: String, remote: String, branch: String) {
            self.release = release
            self.remote = remote
            self.branch = branch
        }
    }

    /// A group name is used as a folder and as a workspace file name; anything that would not
    /// open as one, or would not be cloneable into, is refused.
    public static func groupNameProblem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "A project group needs a name." }
        if trimmed.hasPrefix(".") || trimmed.hasPrefix("/") { return "\(trimmed) is not a group name; name a folder, not a path." }
        if trimmed.contains("/") || trimmed.contains("\\") { return "\(trimmed) names a path; give the group one name and use --destination to say where." }
        if trimmed.contains("..") { return "\(trimmed) reaches outside the folder it is meant to sit in." }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: ":*?\"<>|")) != nil {
            return "\(trimmed) holds a character a workspace file cannot."
        }
        return nil
    }

    /// The release, remote and branch a remote ref names. `origin/1.2-release` is release
    /// `1.2` on remote `origin` at branch `1.2-release`; `origin/release/1.2` is the same
    /// release at branch `release/1.2`. A branch that holds no release - `origin/main` -
    /// names nothing.
    public static func branch(of ref: String) -> ReleaseBranch? {
        var trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("remotes/") { trimmed.removeFirst("remotes/".count) }
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let remote = String(trimmed[..<slash])
        let branch = String(trimmed[trimmed.index(after: slash)...])
        if branch.isEmpty || remote.isEmpty { return nil }
        if branch.hasSuffix("-release") {
            let release = String(branch.dropLast("-release".count))
            return release.isEmpty ? nil : ReleaseBranch(release: release, remote: remote, branch: branch)
        }
        if branch.hasPrefix("release/") {
            let release = String(branch.dropFirst("release/".count))
            return release.isEmpty ? nil : ReleaseBranch(release: release, remote: remote, branch: branch)
        }
        return nil
    }

    /// The numbers a release is made of: `1.10` is `[1, 10]`. A release that names no
    /// version - `preview`, say - has none, and a floor that names no version asks for
    /// nothing.
    public static func version(of release: String) -> [Int]? {
        let parts = release.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// Whether a release is at or above a floor. `1.2.3` is at or above `1.2`; `1.2` is
    /// below `1.2.3`. A release that names no version is kept: a floor is about versions,
    /// and a branch called `preview-release` is a release even though it counts as none.
    public static func isAtLeast(_ release: String, floor: String) -> Bool {
        guard let minimum = version(of: floor) else { return true }
        guard let candidate = version(of: release) else { return true }
        for (releaseNumber, minimumNumber) in zip(candidate, minimum) {
            if releaseNumber != minimumNumber { return releaseNumber > minimumNumber }
        }
        return candidate.count >= minimum.count
    }

    /// Why a floor cannot be used. Empty asks for nothing; anything else has to count as
    /// a version.
    public static func floorProblem(_ floor: String) -> String? {
        let trimmed = floor.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard version(of: trimmed) != nil else {
            return "\(trimmed) is not a release version; give one like 0.5.0."
        }
        return nil
    }

    /// Whether one release is older than another. Versions come before releases that
    /// count as no version, and among themselves by number, so `1.10` is newer than `1.2`
    /// rather than shorter than it.
    public static func isOlder(_ left: String, _ right: String) -> Bool {
        guard let leftNumbers = version(of: left) else {
            // A release that names no version comes after every version, and among
            // themselves by name.
            return version(of: right) == nil && left < right
        }
        guard let rightNumbers = version(of: right) else { return true }
        return leftNumbers.lexicographicallyPrecedes(rightNumbers)
    }

    /// The oldest release a list holds. Nothing to choose from answers with no release.
    public static func oldest(_ releases: [String]) -> String? {
        releases.min(by: isOlder)
    }

    /// The releases a checkout's remote has, oldest first, dropping those below the floor
    /// when one is given. An empty floor drops nothing; a floor that names no version is
    /// refused by `floorProblem`, not quietly ignored.
    public static func releases(in refs: [String], floor: String? = nil) -> [String] {
        branches(in: refs, floor: floor).map(\.release)
    }

    /// The branches behind those releases, in the same order: cloning needs the branch a
    /// remote holds, which is not the name the group is filed under.
    public static func branches(in refs: [String], floor: String? = nil) -> [ReleaseBranch] {
        var seen: [ReleaseBranch] = []
        for ref in refs {
            guard let candidate = branch(of: ref), !seen.contains(where: { $0.release == candidate.release }) else { continue }
            seen.append(candidate)
        }
        let trimmed = floor?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return seen.filter { isAtLeast($0.release, floor: trimmed) }.sorted { isOlder($0.release, $1.release) }
        }
        return seen.sorted { isOlder($0.release, $1.release) }
    }

    /// What a group's own folder ignores: StateUI's build folders, packages resolved against a
    /// local path, and anything a head left behind.
    public static func ignoreEntries(checkoutPath: String) -> [String] {
        var entries = ["apps/", ".vscode/", "artifacts/", ".build/", ".swiftpm/"]
        if checkoutPath != "." { entries.append(checkoutPath) }
        return entries
    }

    /// A workspace file that opens every release in the group, each pinned to its own
    /// checkout: the path is relative to the group's folder, which is where the clone lands.
    public static func workspaceFolders(releases: [String], groupPath: String) -> [[String: String]] {
        releases.map { release in
            ["name": release, "path": "\(groupPath)/\(release)"]
        }
    }

    /// Editor settings for a group: the build folders a search should skip, and the floor
    /// the group itself was built at - `stateui minimumRelease`, the oldest release the
    /// editors offer. Nothing here names a host or an application: the selection is the
    /// checkout's own, in `.stateui/config.json`, and the editors read that from the tool.
    public static func settings(releases: [String]) -> String {
        var settings: [String: Any] = [:]
        if let oldest = oldest(releases), let numbers = version(of: oldest), numbers.count == 3 {
            settings["stateui.minimumRelease"] = oldest
        }
        settings["search.exclude"] = [
            "**/.build": true, "**/.swiftpm": true, "**/artifacts": true,
            "**/node_modules": true, "**/dist": true, "**/out": true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Debug configurations, one per release. Every key is one the debugger's schema
    /// accepts: `project` is a path from the group's folder, the same one the status bar
    /// and the tasks pass, and `host` is the host the checkout was set to when the group
    /// was made - when it names one. Extra arguments are the application's own business,
    /// so a configuration carries none.
    public static func launchConfiguration(releases: [String], application: String?, host: HostID? = nil) -> String {
        let app = application ?? ""
        let configurations = releases.map { release in
            var configuration: [String: Any] = [
                "name": "StateUI: \(app) (\(release))",
                "type": "stateui",
                "request": "launch",
                "application": app,
                "project": "apps/\(release)",
                "configuration": "debug",
            ]
            if let host { configuration["host"] = host.rawValue }
            return configuration
        }
        let document: [String: Any] = ["version": "0.2.0", "configurations": configurations]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Cloning a release into the group: its branch fetched alone, from the remote that
    /// holds it. A checkout on disk is not the source to clone from - it carries the
    /// branches it checked out, not every branch the remote has - so the remote's own URL
    /// is what a clone is asked for.
    public static func cloneArguments(url: String, branch: String, destination: String) -> [String] {
        ["clone", "--branch", branch, "--single-branch", url, destination]
    }
}

/// Builds project groups from a checkout's release branches.
public struct GroupService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    /// Git, found where the editor's own PATH points - not beside the checkout, which is
    /// where a bare name is looked up and would find nothing.
    private func git() throws -> URL {
        guard let git = FileSystem.findExecutable("git", environment: tooling.environment) else {
            throw ToolingError.executableNotFound("git")
        }
        return git
    }

    /// The releases a checkout's remote offers, oldest first, dropping those below the
    /// floor. `checkout` names another repository; the default is the StateUI checkout the
    /// project was resolved from. A floor is a version like `0.5.0`; one naming no version
    /// is refused.
    public func releases(checkout: URL? = nil, project: URL? = nil, floor: String? = nil) async throws -> [String] {
        try await listed(checkout: checkout, project: project, floor: floor).map(\.release)
    }

    /// The branches behind the releases the remote offers, because cloning a release asks
    /// git for the branch the source holds, not the name the group is filed under.
    private func listed(checkout: URL? = nil, project: URL? = nil, floor: String? = nil) async throws -> [GroupLayout.ReleaseBranch] {
        let trimmed = floor?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, let problem = GroupLayout.floorProblem(trimmed) {
            throw ToolingError.invalidArguments(
                problem,
                context: ["floor": trimmed],
                suggestion: "A release floor is a version like `0.5.0`."
            )
        }
        let root = try self.checkout(checkout: checkout, project: project)
        let invocation = ProcessInvocation(
            executable: try git(),
            arguments: ["branch", "--remotes", "--format=%(refname:short)"],
            workingDirectory: root,
            label: "reading the checkout's release branches",
            captureOutput: true
        )
        let result: ProcessResult
        do {
            result = try await tooling.executor.execute(invocation)
        } catch {
            throw ToolingError.commandFailed(
                "`git branch --remotes` could not run in \(root.path): \(error.toolingError.message)",
                context: ["root": root.path],
                suggestion: "Install Git and fetch the checkout's remote first: `git fetch --all`."
            )
        }
        guard result.exitCode == 0 else {
            throw ToolingError.commandFailed(
                "`git branch --remotes` failed in \(root.path): \(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))",
                context: ["root": root.path, "exitCode": "\(result.exitCode)"],
                suggestion: "Fetch the remote first: `git fetch --all` inside the checkout."
            )
        }
        let refs = result.standardOutput.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }
        let found = GroupLayout.branches(in: refs, floor: trimmed)
        if found.isEmpty {
            let message = trimmed.flatMap { $0.isEmpty ? nil : "\(root.path) has no release at or above \($0)." }
                ?? "\(root.path) has no release branches on its remote."
            throw ToolingError.projectNotFound(
                message,
                context: ["remotes": refs.joined(separator: ", ")],
                suggestion: "A project group holds one application per release; `origin/<release>-release` branches are what it clones."
            )
        }
        return found
    }

    /// The URL a remote's branches live at, read from the checkout. A release branch is a
    /// head of the remote, so it is fetched from there rather than from the checkout, which
    /// only carries the branches it checked out itself.
    private func remoteURL(named remote: String, in root: URL) async throws -> String {
        let invocation = ProcessInvocation(
            executable: try git(),
            arguments: ["remote", "get-url", remote],
            workingDirectory: root,
            label: "reading the remote \(remote)",
            captureOutput: true
        )
        let result: ProcessResult
        do {
            result = try await tooling.executor.execute(invocation)
        } catch {
            throw ToolingError.commandFailed(
                "`git remote get-url \(remote)` could not run in \(root.path): \(error.toolingError.message)",
                context: ["remote": remote, "root": root.path],
                suggestion: "The remote the release branches are on has to be reachable: `git remote show \(remote)`."
            )
        }
        let url = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !url.isEmpty else {
            throw ToolingError.commandFailed(
                "\(root.path) has no remote named \(remote) to clone a release from.",
                context: ["remote": remote, "root": root.path, "exitCode": "\(result.exitCode)"],
                suggestion: "Fetch the release branches first: `git fetch --all` inside the checkout."
            )
        }
        return url
    }

    public func plan(
        name: String, releases requested: [String]? = nil, at: URL? = nil,
        checkout: URL? = nil, project: URL? = nil, floor: String? = nil
    ) async throws -> GroupPlan {
        if let problem = GroupLayout.groupNameProblem(name) {
            throw ToolingError.invalidArguments(problem, suggestion: "`stateui group create <name> --destination <folder>`.")
        }
        let root = try self.checkout(checkout: checkout, project: project)
        let config = try tooling.loadConfiguration(try tooling.project(explicit: project))
        let groupPath = (at ?? tooling.cwd.appendingPathComponent(name, isDirectory: true)).standardizedFileURL.path
        let trimmed = floor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let offered = try await listed(checkout: root, project: project, floor: trimmed)
        let available = offered.map(\.release)
        let requested = requested ?? available
        for release in requested {
            guard available.contains(release) else {
                let message = trimmed.flatMap { $0.isEmpty ? nil : "\(root.path) has no release \(release) at or above \($0)." }
                    ?? "\(root.path) has no release \(release)."
                throw ToolingError.invalidArguments(
                    message,
                    context: ["releases": available.joined(separator: ", ")],
                    suggestion: "Pick one of the releases the remote has."
                )
            }
        }

        var steps: [ProcessInvocation] = []
        var cloned: [String] = []
        var reused: [String] = []
        var urls: [String: String] = [:]
        let git = try self.git()
        for candidate in offered where requested.contains(candidate.release) {
            let destination = URL(fileURLWithPath: groupPath).appendingPathComponent("apps", isDirectory: true).appendingPathComponent(candidate.release, isDirectory: true)
            if FileSystem.isDirectory(destination) {
                reused.append(candidate.release)
                continue
            }
            if urls[candidate.remote] == nil {
                urls[candidate.remote] = try await remoteURL(named: candidate.remote, in: root)
            }
            guard let url = urls[candidate.remote] else { continue }
            cloned.append(candidate.release)
            steps.append(ProcessInvocation(
                executable: git,
                arguments: GroupLayout.cloneArguments(url: url, branch: candidate.branch, destination: destination.path),
                workingDirectory: root,
                label: "cloning release \(candidate.release)"
            ))
        }

        let actions: [FileAction] = [
            FileAction(
                kind: .write, destination: URL(fileURLWithPath: groupPath).appendingPathComponent(".gitignore"),
                contents: GroupLayout.ignoreEntries(
                    checkoutPath: FileSystem.relativePath(
                        from: URL(fileURLWithPath: groupPath), to: root
                    )
                ).joined(separator: "\n") + "\n"
            ),
            FileAction(
                kind: .write, destination: URL(fileURLWithPath: groupPath).appendingPathComponent("workspace.code-workspace"),
                contents: workspaceFile(releases: requested, groupPath: "apps")
            ),
            FileAction(
                kind: .write, destination: URL(fileURLWithPath: groupPath).appendingPathComponent(".vscode/settings.json"),
                contents: GroupLayout.settings(releases: requested)
            ),
            FileAction(
                kind: .write, destination: URL(fileURLWithPath: groupPath).appendingPathComponent(".vscode/launch.json"),
                contents: GroupLayout.launchConfiguration(releases: requested, application: config.defaultApplication, host: config.defaultHost)
            ),
        ]

        var notes = [
            "A group is a folder of clones, one per release; nothing in it is StateUI's own build.",
            "Open \(URL(fileURLWithPath: groupPath).appendingPathComponent("workspace.code-workspace").path) to work on every release at once.",
        ]
        if let trimmed, !trimmed.isEmpty {
            notes.append("Releases below \(trimmed) are not offered; the group's settings record the floor it was built at.")
        }
        let group = ProjectGroup(
            path: groupPath, releases: requested, applications: requested,
            cloned: cloned, reused: reused,
            files: actions.compactMap { $0.destination?.path },
            notes: notes
        )
        return GroupPlan(path: groupPath, steps: steps, actions: actions, group: group)
    }

    public func run(
        name: String, releases requested: [String]? = nil, at: URL? = nil,
        checkout: URL? = nil, project: URL? = nil, floor: String? = nil, dryRun: Bool = false
    ) async throws -> ExecutionOutcome {
        let plan = try await plan(name: name, releases: requested, at: at, checkout: checkout, project: project, floor: floor)
        let outcome = try await tooling.execute(steps: plan.steps, actions: plan.actions, dryRun: dryRun)
        guard outcome.status == .succeeded || outcome.status == .planned else { return outcome }
        var notes = plan.group.notes
        if !plan.group.cloned.isEmpty {
            notes.append("Cloned \(plan.group.cloned.joined(separator: ", ")) into \(plan.path)/apps.")
        }
        if !plan.group.reused.isEmpty {
            notes.append("Kept the releases already in the group: \(plan.group.reused.joined(separator: ", ")).")
        }
        return ExecutionOutcome(
            status: outcome.status, duration: outcome.duration,
            outputs: plan.group.files.map { URL(fileURLWithPath: $0) }, notes: notes + outcome.notes
        )
    }

    private func checkout(checkout: URL?, project: URL?) throws -> URL {
        if let checkout { return checkout }
        return try tooling.project(explicit: project).root
    }

    /// A VS Code workspace file: every release as its own folder, so the editor sees one
    /// application per release rather than one repository with several checkouts inside it.
    private func workspaceFile(releases: [String], groupPath: String) -> String {
        let document: [String: Any] = ["folders": GroupLayout.workspaceFolders(releases: releases, groupPath: "apps")]
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
