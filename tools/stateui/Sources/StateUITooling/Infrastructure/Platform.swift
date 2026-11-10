// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The one place the toolchain asks what machine it is on.
public struct Platform: Codable, Sendable, Hashable {
    public enum OperatingSystem: String, Codable, Sendable {
        case macOS
        case linux
        case windows
        case unknown
    }

    public enum Architecture: String, Codable, Sendable {
        case arm64
        case x86_64
        case unknown
    }

    public let operatingSystem: OperatingSystem
    public let architecture: Architecture

    public init(operatingSystem: OperatingSystem, architecture: Architecture) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
    }

    public static let current: Platform = {
        #if os(macOS)
        let os = OperatingSystem.macOS
        #elseif os(Linux)
        let os = OperatingSystem.linux
        #elseif os(Windows)
        let os = OperatingSystem.windows
        #else
        let os = OperatingSystem.unknown
        #endif

        #if arch(arm64)
        let architecture = Architecture.arm64
        #elseif arch(x86_64)
        let architecture = Architecture.x86_64
        #else
        let architecture = Architecture.unknown
        #endif
        return Platform(operatingSystem: os, architecture: architecture)
    }()

    public var executableSuffix: String { operatingSystem == .windows ? ".exe" : "" }
    public var pathSeparator: String { operatingSystem == .windows ? "\\" : "/" }
    public var pathListSeparator: String { operatingSystem == .windows ? ";" : ":" }

    public var description: String { "\(operatingSystem.rawValue) \(architecture.rawValue)" }
}

/// The process environment, with the lookups the toolchain needs.
public struct Environment: Sendable {
    public let values: [String: String]

    public init(_ values: [String: String]) {
        self.values = values
    }

    public static let current = Environment(ProcessInfo.processInfo.environment)

    public subscript(_ name: String) -> String? {
        if let exact = values[name] { return exact }
        #if os(Windows)
        return values.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
        #else
        return nil
        #endif
    }

    public func value(for names: String...) -> String? {
        for name in names {
            if let value = self[name], !value.isEmpty { return value }
        }
        return nil
    }

    public var pathDirectories: [URL] {
        (self["PATH"] ?? "").split(separator: Character(Platform.current.pathListSeparator))
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func merging(_ overrides: [String: String]) -> [String: String] {
        values.merging(overrides) { _, new in new }
    }

    /// `overrides` over the environment, without the variables `names` hand over to a child.
    public func merging(_ overrides: [String: String], unsetting names: [String]) -> [String: String] {
        var merged = values.merging(overrides) { _, new in new }
        for name in names { merged.removeValue(forKey: name) }
        return merged
    }

    /// Every variable beginning with `STATEUI_`, which a run passes to the application.
    public var stateuiVariables: [String: String] {
        values.filter { $0.key.hasPrefix("STATEUI_") }
    }
}
