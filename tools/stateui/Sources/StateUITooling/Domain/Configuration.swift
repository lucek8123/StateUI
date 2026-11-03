// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The versioned StateUI development configuration.
///
/// `config.json` holds shared project defaults; `local.json` holds this
/// developer's selections and is gitignored. Both use the same schema.
public struct StateUIConfiguration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var defaultHost: HostID?
    public var defaultApplication: String?
    public var configuration: BuildConfiguration?
    public var devices: [String: String]
    public var browsers: [String: String]
    public var toolchains: [String: String]
    public var outputDirectory: String?

    public init(
        schemaVersion: Int = StateUIConfiguration.currentSchemaVersion,
        defaultHost: HostID? = nil,
        defaultApplication: String? = nil,
        configuration: BuildConfiguration? = nil,
        devices: [String: String] = [:],
        browsers: [String: String] = [:],
        toolchains: [String: String] = [:],
        outputDirectory: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.defaultHost = defaultHost
        self.defaultApplication = defaultApplication
        self.configuration = configuration
        self.devices = devices
        self.browsers = browsers
        self.toolchains = toolchains
        self.outputDirectory = outputDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, defaultHost, defaultApplication, configuration
        case devices, browsers, toolchains, outputDirectory
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? StateUIConfiguration.currentSchemaVersion
        self.defaultHost = try container.decodeIfPresent(HostID.self, forKey: .defaultHost)
        self.defaultApplication = try container.decodeIfPresent(String.self, forKey: .defaultApplication)
        self.configuration = try container.decodeIfPresent(BuildConfiguration.self, forKey: .configuration)
        self.devices = try container.decodeIfPresent([String: String].self, forKey: .devices) ?? [:]
        self.browsers = try container.decodeIfPresent([String: String].self, forKey: .browsers) ?? [:]
        self.toolchains = try container.decodeIfPresent([String: String].self, forKey: .toolchains) ?? [:]
        self.outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory)
    }

    public func validate() throws {
        guard schemaVersion == StateUIConfiguration.currentSchemaVersion else {
            throw ToolingError.invalidConfiguration(
                "Unsupported configuration schema version \(schemaVersion).",
                context: ["supported": "\(StateUIConfiguration.currentSchemaVersion)"],
                suggestion: "Update stateui, or migrate .stateui/config.json to schema \(StateUIConfiguration.currentSchemaVersion)."
            )
        }
        if let name = defaultApplication, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolingError.invalidConfiguration("defaultApplication is empty.")
        }
        for key in devices.keys where HostID(parsing: key) == nil {
            throw ToolingError.invalidConfiguration("devices names an unknown host: \(key).")
        }
        for key in browsers.keys where HostID(parsing: key) == nil {
            throw ToolingError.invalidConfiguration("browsers names an unknown host: \(key).")
        }
        if let directory = outputDirectory, directory.isEmpty {
            throw ToolingError.invalidConfiguration("outputDirectory is empty.")
        }
    }

    /// `overlay` wins over the receiver, field by field. Device and browser
    /// maps merge by host.
    public func merged(with overlay: StateUIConfiguration) -> StateUIConfiguration {
        StateUIConfiguration(
            schemaVersion: max(schemaVersion, overlay.schemaVersion),
            defaultHost: overlay.defaultHost ?? defaultHost,
            defaultApplication: overlay.defaultApplication ?? defaultApplication,
            configuration: overlay.configuration ?? configuration,
            devices: devices.merging(overlay.devices) { _, new in new },
            browsers: browsers.merging(overlay.browsers) { _, new in new },
            toolchains: toolchains.merging(overlay.toolchains) { _, new in new },
            outputDirectory: overlay.outputDirectory ?? outputDirectory
        )
    }

    public func json() throws -> String {
        try JSON.encoder(pretty: true).encode(self).string()
    }
}

/// Where a checkout keeps its shared and local configuration files.
public struct ConfigurationPaths: Codable, Sendable, Hashable {
    public let shared: URL
    public let local: URL

    public init(root: URL) {
        let directory = root.appendingPathComponent(".stateui", isDirectory: true)
        self.shared = directory.appendingPathComponent("config.json")
        self.local = directory.appendingPathComponent("local.json")
    }

    public var directory: URL { shared.deletingLastPathComponent() }
}
