// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ApplicationResolver: Sendable {
    public init() {}

    public func applications(in root: URL, checkoutHint: URL? = nil) -> [Application] {
        var found: [Application] = []
        let apps = root.appendingPathComponent("apps", isDirectory: true)
        if FileSystem.isDirectory(apps) {
            for child in FileSystem.children(apps) where FileSystem.isDirectory(child) {
                if let application = describe(
                    child, root: root, isWorkspaceRoot: false, checkoutHint: checkoutHint
                ) {
                    found.append(application)
                }
            }
        }
        if let application = describe(
            root, root: root, isWorkspaceRoot: true, checkoutHint: checkoutHint
        ) {
            found.append(application)
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func describe(
        _ directory: URL, root: URL, isWorkspaceRoot: Bool, checkoutHint: URL? = nil
    ) -> Application? {
        let manifest = directory.appendingPathComponent("Package.swift")
        guard FileSystem.exists(manifest) else { return nil }
        let heads = HostID.allCases.compactMap { host -> ApplicationHead? in
            let marker = directory.appendingPathComponent(host.headMarker)
            return FileSystem.exists(marker) ? ApplicationHead(host: host, path: marker) : nil
        }
        guard !heads.isEmpty else { return nil }
        let name = directory.lastPathComponent
        let checkout = checkoutNamed(by: manifest, from: directory)
        return Application(
            name: name,
            directory: directory.standardizedFileURL,
            manifest: manifest,
            heads: heads,
            checkout: checkout ?? checkoutHint,
            bundleScript: nil,
            isWorkspaceRoot: isWorkspaceRoot
        )
    }

    /// The first path dependency in a manifest that resolves to a StateUI checkout.
    public func checkoutNamed(by manifest: URL, from directory: URL) -> URL? {
        guard let text = try? FileSystem.read(manifest) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let textLine = String(line)
            let trimmed = textLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || !trimmed.contains(".package(") { continue }
            guard let regex = try? NSRegularExpression(pattern: #"path:\s*"([^"]+)""#) else { continue }
            let range = NSRange(textLine.startIndex..<textLine.endIndex, in: textLine)
            for match in regex.matches(in: textLine, range: range) {
                guard match.numberOfRanges == 2,
                      let pathRange = Range(match.range(at: 1), in: textLine) else { continue }
                let resolved = directory.appendingPathComponent(String(textLine[pathRange])).standardizedFileURL
                if ProjectDiscovery.isCheckout(resolved) { return resolved }
            }
        }
        return nil
    }
}

public struct ProjectDiscovery: Sendable {
    public let applications: ApplicationResolver

    public init(applications: ApplicationResolver = ApplicationResolver()) {
        self.applications = applications
    }

    public func discover(explicit: URL? = nil, cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> ProjectInfo {
        let start = explicit?.standardizedFileURL ?? cwd.standardizedFileURL
        guard FileSystem.exists(start) else {
            throw ToolingError.projectNotFound(
                "The project path does not exist: \(start.path)",
                context: ["path": start.path]
            )
        }

        var candidates: [URL] = [start]
        if !FileSystem.isDirectory(start) { candidates = [start.deletingLastPathComponent()] }
        var parent = candidates[0].deletingLastPathComponent()
        while parent.path != "/" && parent.path != candidates[0].path {
            candidates.append(parent)
            parent = parent.deletingLastPathComponent()
        }

        for candidate in candidates {
            if let project = project(at: candidate) { return project }
        }
        throw ToolingError.projectNotFound(
            "No StateUI checkout, project group or application was found from \(start.path).",
            context: ["path": start.path],
            suggestion: "Run stateui from a StateUI checkout or project group, or pass --project."
        )
    }

    private func project(at directory: URL) -> ProjectInfo? {
        let configuration = ConfigurationPaths(root: directory)

        // A StateUI checkout.
        if Self.isCheckout(directory) {
            let checkout = directory
            let apps = applications.applications(in: checkout, checkoutHint: checkout)
            return ProjectInfo(
                root: checkout, kind: .checkout, applications: apps,
                checkout: checkout, configurationDirectory: configuration.directory
            )
        }

        // A project group: apps/ with at least one application, and a cloned
        // StateUI/ or an application that names a checkout.
        let appsDirectory = directory.appendingPathComponent("apps", isDirectory: true)
        if FileSystem.isDirectory(appsDirectory) {
            let apps = applications.applications(in: directory)
            if !apps.isEmpty || FileSystem.exists(configuration.shared) {
                let checkout = apps.compactMap(\.checkout).first
                    ?? [directory.appendingPathComponent("StateUI")].first(where: Self.isCheckout)
                return ProjectInfo(
                    root: directory, kind: .group, applications: apps,
                    checkout: checkout, configurationDirectory: configuration.directory
                )
            }
        }

        // A workspace opened on one application.
        if let application = applications.describe(directory, root: directory, isWorkspaceRoot: true) {
            let parent = directory.deletingLastPathComponent()
            let root = parent.lastPathComponent == "apps" ? parent.deletingLastPathComponent() : directory
            let projectApps = root == directory ? [application] : applications.applications(in: root)
            return ProjectInfo(
                root: root, kind: .application, applications: projectApps,
                checkout: application.checkout, configurationDirectory: ConfigurationPaths(root: root).directory
            )
        }

        // A .stateui directory alone is enough to identify a project.
        if FileSystem.isDirectory(configuration.directory) {
            return ProjectInfo(
                root: directory, kind: .group, applications: applications.applications(in: directory),
                checkout: nil, configurationDirectory: configuration.directory
            )
        }
        return nil
    }

    public static func isCheckout(_ directory: URL) -> Bool {
        FileSystem.isDirectory(directory.appendingPathComponent("lib/StateUI/Core/Sources"))
            && FileSystem.exists(directory.appendingPathComponent("Package.swift"))
            && FileSystem.isDirectory(directory.appendingPathComponent("apps"))
    }

    public static func isProjectGroup(_ directory: URL) -> Bool {
        FileSystem.isDirectory(directory.appendingPathComponent("apps"))
            && !isCheckout(directory)
    }
}

public struct ConfigurationService: Sendable {
    public init() {}

    public func load(root: URL) throws -> StateUIConfiguration {
        let paths = ConfigurationPaths(root: root)
        let shared = try read(paths.shared)
        let local = try read(paths.local)
        try shared.validate()
        try local.validate()
        return shared.merged(with: local)
    }

    public func loadPaths(root: URL) throws -> (shared: StateUIConfiguration, local: StateUIConfiguration) {
        let paths = ConfigurationPaths(root: root)
        let shared = try read(paths.shared)
        let local = try read(paths.local)
        try shared.validate()
        try local.validate()
        return (shared, local)
    }

    private func read(_ url: URL) throws -> StateUIConfiguration {
        guard FileSystem.exists(url) else { return StateUIConfiguration() }
        do {
            let data = try Data(contentsOf: url)
            return try JSON.decoder().decode(StateUIConfiguration.self, from: data)
        } catch let error as ToolingError {
            throw error
        } catch {
            throw ToolingError.invalidConfiguration(
                "\(url.path) is not valid StateUI configuration.",
                context: ["path": url.path, "reason": error.localizedDescription],
                suggestion: "Fix the JSON, or remove the file to use defaults."
            )
        }
    }

    public func saveLocal(root: URL, mutate: (inout StateUIConfiguration) -> Void) throws {
        let paths = ConfigurationPaths(root: root)
        var local = try read(paths.local)
        mutate(&local)
        local.schemaVersion = StateUIConfiguration.currentSchemaVersion
        try local.validate()
        try FileSystem.write(try local.json(), to: paths.local)
        try ensureGitignore(root: root)
    }

    public func saveShared(root: URL, config: StateUIConfiguration) throws {
        let paths = ConfigurationPaths(root: root)
        var config = config
        config.schemaVersion = StateUIConfiguration.currentSchemaVersion
        try config.validate()
        try FileSystem.write(try config.json(), to: paths.shared)
    }

    private func ensureGitignore(root: URL) throws {
        let url = root.appendingPathComponent(".gitignore")
        let line = ".stateui/local.json"
        let existing = (try? FileSystem.read(url)) ?? ""
        guard !existing.split(separator: "\n").contains(Substring(line)) else { return }
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try FileSystem.write(existing + separator + "# StateUI developer selections\n" + line + "\n", to: url)
    }
}
