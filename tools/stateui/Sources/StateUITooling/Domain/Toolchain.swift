// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One component a host needs, and how it is recognised.
public struct ToolchainRequirement: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case executable
        case version
        case environment
        case file
        case custom
    }

    public let name: String
    public let kind: Kind
    public let hosts: [HostID]
    public let minimumVersion: String?
    public let blocking: Bool
    public let advice: String
    public let environmentVariables: [String]

    public init(
        name: String, kind: Kind = .version, hosts: [HostID], minimumVersion: String? = nil,
        blocking: Bool = true, advice: String, environmentVariables: [String] = []
    ) {
        self.name = name
        self.kind = kind
        self.hosts = hosts
        self.minimumVersion = minimumVersion
        self.blocking = blocking
        self.advice = advice
        self.environmentVariables = environmentVariables
    }
}

/// What a toolchain check found for one component.
public struct ToolchainFinding: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case found
        case tooOld = "too-old"
        case missing
        case notApplicable = "not-applicable"
    }

    public let component: String
    public let neededBy: [HostID]
    public let status: Status
    public let version: String?
    public let executable: String?
    public let requiredVersion: String?
    public let requiredPlatform: String?
    public let environmentVariables: [String: String]
    public let advice: String
    public let blocking: Bool

    public init(
        component: String, neededBy: [HostID], status: Status, version: String? = nil,
        executable: String? = nil, requiredVersion: String? = nil, requiredPlatform: String? = nil,
        environmentVariables: [String: String] = [:], advice: String, blocking: Bool = true
    ) {
        self.component = component
        self.neededBy = neededBy
        self.status = status
        self.version = version
        self.executable = executable
        self.requiredVersion = requiredVersion
        self.requiredPlatform = requiredPlatform
        self.environmentVariables = environmentVariables
        self.advice = advice
        self.blocking = blocking
    }

    public var isSatisfied: Bool { status == .found || status == .notApplicable }
}

/// Every finding for the hosts a doctor run checked.
public struct ToolchainReport: Codable, Sendable {
    public let platform: Platform
    public let findings: [ToolchainFinding]

    public init(platform: Platform, findings: [ToolchainFinding]) {
        self.platform = platform
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case platform, findings, ready
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = try container.decode(Platform.self, forKey: .platform)
        self.findings = try container.decode([ToolchainFinding].self, forKey: .findings)
    }

    /// `ready` is computed from the findings, but a client reading `doctor`
    /// should not have to repeat the rule; it is written beside them.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(findings, forKey: .findings)
        try container.encode(ready, forKey: .ready)
    }

    public var missing: [ToolchainFinding] {
        findings.filter { !$0.isSatisfied && $0.blocking }
    }

    public var ready: Bool { missing.isEmpty }
}

/// A physical device, simulator, emulator or local target a host can run on.
public struct Device: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case physical
        case simulator
        case emulator
        case avd
        case local
    }

    public let id: String
    public let name: String
    public let host: HostID
    public let kind: Kind
    public let platform: String?
    public let osVersion: String?
    public let state: String?
    public let architecture: String?
    public let isAvailable: Bool

    public init(
        id: String, name: String, host: HostID, kind: Kind, platform: String? = nil,
        osVersion: String? = nil, state: String? = nil, architecture: String? = nil,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.kind = kind
        self.platform = platform
        self.osVersion = osVersion
        self.state = state
        self.architecture = architecture
        self.isAvailable = isAvailable
    }
}

/// A browser a Web application can be served to.
public struct Browser: Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let executable: String
    public let isDefault: Bool
    public let isChromium: Bool

    public init(id: String, name: String, executable: String, isDefault: Bool, isChromium: Bool) {
        self.id = id
        self.name = name
        self.executable = executable
        self.isDefault = isDefault
        self.isChromium = isChromium
    }
}
