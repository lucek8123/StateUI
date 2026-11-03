// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Describes the current project and the applications and hosts it holds.
public struct ProjectService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func apps(project explicit: URL? = nil) throws -> [Application] {
        try tooling.project(explicit: explicit).applications
    }

    public func hosts(project explicit: URL? = nil) async throws -> [HostAvailability] {
        let project = try tooling.project(explicit: explicit)
        let config = try tooling.loadConfiguration(project)
        let context = ProjectContext(
            project: project, application: nil, host: nil, configuration: .debug,
            config: config, environment: tooling.environment, platform: tooling.platform
        )
        return await tooling.registry.availability(context)
    }

    public func devices(host: HostID, project explicit: URL? = nil) async throws -> [Device] {
        let workspace = try tooling.resolve(project: explicit, host: host)
        return try await tooling.driver(for: host).devices(workspace.context)
    }

    public func browsers(project explicit: URL? = nil) async throws -> [Browser] {
        let workspace = try tooling.resolve(project: explicit, host: .web)
        return try await tooling.driver(for: .web).browsers(workspace.context)
    }

    public func doctor(hosts: [HostID]? = nil) async -> ToolchainReport {
        await tooling.toolchainService.report(hosts: hosts)
    }

    public func select(
        host: HostID? = nil, application: String? = nil, configuration: BuildConfiguration? = nil,
        device: String? = nil, deviceHost: HostID? = nil, browser: String? = nil,
        project explicit: URL? = nil
    ) throws {
        let project = try tooling.project(explicit: explicit)
        // A name nothing in the checkout answers is refused rather than stored: an
        // editor's picker offers only discovered applications, so a typed name is the
        // one path that can select something no build can find.
        if let application {
            guard project.application(named: application) != nil else {
                throw ToolingError.applicationNotFound(
                    "\(project.root.path) has no application named \(application).",
                    context: ["applications": project.applications.map(\.name).joined(separator: ", ")],
                    suggestion: "Run `stateui apps` to list what stands here."
                )
            }
        }
        try tooling.configurationService.saveLocal(root: project.root) { local in
            if let host { local.defaultHost = host }
            if let application { local.defaultApplication = application }
            if let configuration { local.configuration = configuration }
            if let device, let deviceHost { local.devices[deviceHost.rawValue] = device }
            if let browser { local.browsers[HostID.web.rawValue] = browser }
        }
    }
}

/// Creates a new application from the HelloWorld model, natively.
public struct ScaffoldService: Sendable {
    public init() {}

    public func create(name: String, appsDirectory: URL?, project: ProjectInfo) throws -> URL {
        guard name.range(of: #"^[A-Za-z][A-Za-z0-9]*$"#, options: .regularExpression) != nil else {
            throw ToolingError.invalidArguments(
                "'\(name)' cannot name an application: letters and digits only, starting with a letter.",
                suggestion: "Pick a name without dots; Finder reads Name.App as a bundle."
            )
        }
        guard name != "StateUI" else {
            throw ToolingError.invalidArguments(
                "'StateUI' is the library. Pick a name of the application's own."
            )
        }
        guard let checkout = project.checkout ?? (project.kind == .checkout ? project.root : nil) else {
            throw ToolingError.projectNotFound(
                "The project does not name a StateUI checkout, whose HelloWorld is the model."
            )
        }
        let model = checkout.appendingPathComponent("apps/HelloWorld", isDirectory: true)
        guard FileSystem.isDirectory(model) else {
            throw ToolingError.projectNotFound("HelloWorld is not at \(model.path).")
        }
        let directory = (appsDirectory ?? project.root.appendingPathComponent("apps", isDirectory: true))
            .appendingPathComponent(name, isDirectory: true)
        guard !FileSystem.exists(directory) else {
            throw ToolingError.invalidArguments("\(directory.path) already exists.")
        }

        try FileSystem.makeDirectory(directory.deletingLastPathComponent())
        try copyModel(from: model, to: directory)

        let lower = name.lowercased()
        try renamePaths(in: directory, replacing: "HelloWorld", with: name)
        try replaceContents(
            in: directory, replacements: [("HelloWorld", name), ("helloworld", lower)]
        )

        // The model's package points at ../..; a new application may stand
        // anywhere, so the checkout is named relatively.
        let package = directory.appendingPathComponent("Package.swift")
        if let text = try? FileSystem.read(package) {
            let relative = FileSystem.relativePath(from: directory, to: checkout)
            if relative != "../.." {
                let rewritten = text
                    .replacingOccurrences(of: "\"../../lib/StateUI.Head\"", with: "\"\(relative)/lib/StateUI.Head\"")
                    .replacingOccurrences(of: "\"../../lib/StateUI/StateUI.Testing\"", with: "\"\(relative)/lib/StateUI/StateUI.Testing\"")
                    .replacingOccurrences(of: "\"../..\"", with: "\"\(relative)\"")
                try FileSystem.write(rewritten, to: package)
            }
        }
        return directory
    }

    private func copyModel(from source: URL, to destination: URL) throws {
        try FileSystem.makeDirectory(destination)
        let skipped: Set<String> = [".build", ".gradle", ".swiftpm", "artifacts", ".DS_Store"]
        for entry in FileSystem.children(source) {
            let name = entry.lastPathComponent
            if skipped.contains(name) { continue }
            let target = destination.appendingPathComponent(name)
            if FileSystem.isDirectory(entry) {
                try copyModel(from: entry, to: target)
            } else {
                try FileSystem.copy(entry, to: target)
            }
        }
    }

    private func renamePaths(in directory: URL, replacing token: String, with replacement: String) throws {
        let entries = FileSystem.children(directory)
        for entry in entries {
            let name = entry.lastPathComponent
            if FileSystem.isDirectory(entry) {
                try renamePaths(in: entry, replacing: token, with: replacement)
            }
            if name.contains(token) {
                let renamed = name.replacingOccurrences(of: token, with: replacement)
                try FileManager.default.moveItem(
                    at: entry, to: entry.deletingLastPathComponent().appendingPathComponent(renamed)
                )
            }
        }
    }

    private func replaceContents(
        in directory: URL, replacements: [(String, String)]
    ) throws {
        let extensions: Set<String> = ["swift", "xml", "kts", "json", "md", "plist", "html", "js", "css"]
        for entry in FileSystem.children(directory) {
            if FileSystem.isDirectory(entry) {
                try replaceContents(in: entry, replacements: replacements)
            } else if extensions.contains(entry.pathExtension),
                      var text = try? FileSystem.read(entry) {
                for (token, replacement) in replacements {
                    text = text.replacingOccurrences(of: token, with: replacement)
                }
                try FileSystem.write(text, to: entry)
            }
        }
    }
}
