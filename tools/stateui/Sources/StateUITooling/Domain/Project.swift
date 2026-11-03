// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The optimization a build uses.
public enum BuildConfiguration: String, Codable, Sendable, CaseIterable, Hashable {
    case debug
    case release

    public init?(parsing raw: String) {
        switch raw.lowercased() {
        case "debug", "d": self = .debug
        case "release", "r": self = .release
        default: return nil
        }
    }

    public var gradleTaskSuffix: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// What a discovered directory is: a checkout, a group, an application, or none of them.
public enum ProjectKind: String, Codable, Sendable {
    case checkout
    case group
    case application
    case unknown
}

/// The project a command runs against and the applications it holds.
public struct ProjectInfo: Codable, Sendable, Hashable {
    public let root: URL
    public let kind: ProjectKind
    public let applications: [Application]
    public let checkout: URL?
    public let configurationDirectory: URL

    public init(
        root: URL, kind: ProjectKind, applications: [Application],
        checkout: URL?, configurationDirectory: URL
    ) {
        self.root = root
        self.kind = kind
        self.applications = applications
        self.checkout = checkout
        self.configurationDirectory = configurationDirectory
    }

    public func application(named name: String) -> Application? {
        applications.first { $0.name == name }
    }
}

/// Everything a host driver needs to plan against.
public struct ProjectContext: Sendable {
    public let project: ProjectInfo
    public let application: Application?
    public let host: HostID?
    public let configuration: BuildConfiguration
    public let config: StateUIConfiguration
    public let environment: Environment
    public let platform: Platform

    public init(
        project: ProjectInfo, application: Application?, host: HostID?,
        configuration: BuildConfiguration, config: StateUIConfiguration,
        environment: Environment = .current, platform: Platform = .current
    ) {
        self.project = project
        self.application = application
        self.host = host
        self.configuration = configuration
        self.config = config
        self.environment = environment
        self.platform = platform
    }

    public var root: URL { project.root }
    public var checkout: URL? { project.checkout ?? (project.kind == .checkout ? project.root : nil) }

    public func requiringApplication() throws -> Application {
        guard let application else {
            throw ToolingError.applicationNotFound(
                "No StateUI application was resolved.",
                suggestion: "Pass an application name, or run `stateui apps` in a StateUI project."
            )
        }
        return application
    }

    public func requiringHost() throws -> HostID {
        guard let host else {
            throw ToolingError.hostUnavailable(
                "No StateUI host was selected or requested.",
                suggestion: "Pass --host, or run `stateui host set <host>`."
            )
        }
        return host
    }
}

/// One host's entry point in an application.
public struct ApplicationHead: Codable, Sendable, Hashable {
    public let host: HostID
    public let path: URL

    public init(host: HostID, path: URL) {
        self.host = host
        self.path = path
    }
}

/// An application's manifest, directory and per-host heads.
public struct Application: Codable, Sendable, Hashable {
    public let name: String
    public let directory: URL
    public let manifest: URL
    public let heads: [ApplicationHead]
    public let checkout: URL?
    public let bundleScript: URL?
    public let isWorkspaceRoot: Bool

    public init(
        name: String, directory: URL, manifest: URL, heads: [ApplicationHead],
        checkout: URL?, bundleScript: URL?, isWorkspaceRoot: Bool = false
    ) {
        self.name = name
        self.directory = directory
        self.manifest = manifest
        self.heads = heads
        self.checkout = checkout
        self.bundleScript = bundleScript
        self.isWorkspaceRoot = isWorkspaceRoot
    }

    public func hasHead(for host: HostID) -> Bool {
        heads.contains { $0.host == host }
    }

    public func product(for host: HostID) -> String {
        "\(name)\(host.productSuffix)"
    }

    public var availableHosts: [HostID] {
        heads.map(\.host)
    }

    public var buildRoot: URL {
        directory.appendingPathComponent(".build", isDirectory: true)
    }

    public func buildDirectory(for host: HostID) -> URL {
        buildRoot.appendingPathComponent(host.buildDirectoryName, isDirectory: true)
    }
}
