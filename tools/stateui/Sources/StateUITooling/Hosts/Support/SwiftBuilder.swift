// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The SwiftPM command line every host's build shares. Arguments are always
/// separate; `STATEUI_HOST` is the only variable a manifest reads.
public struct SwiftBuilder: Sendable {
    public let runner: CommandRunner
    public let environment: Environment
    public let platform: Platform

    public init(runner: CommandRunner, environment: Environment = .current, platform: Platform = .current) {
        self.runner = runner
        self.environment = environment
        self.platform = platform
    }

    public func swift(override: URL? = nil) throws -> URL {
        if let override, FileSystem.isExecutable(override) { return override }
        if let named = environment["SWIFT_BIN"], !named.isEmpty {
            let url = FileSystem.expand(named)
            if FileSystem.isExecutable(url) { return url }
        }
        if let found = runner.which("swift") { return found }
        for candidate in Self.installedToolchains(environment: environment, platform: platform)
        where FileSystem.isExecutable(candidate) {
            return candidate
        }
        throw ToolingError.toolchainMissing(
            "The Swift compiler was not found.",
            suggestion: "Install Swift 6.4, or set SWIFT_BIN to its executable."
        )
    }

    /// The toolchains a Windows installer lays under the user's or the machine's programs, whether or not the
    /// shell that runs the tool has its bin on PATH.
    private static func installedToolchains(environment: Environment, platform: Platform) -> [URL] {
        guard platform.operatingSystem == .windows else { return [] }
        var candidates: [URL] = []
        let roots = [
            ("LOCALAPPDATA", "Programs/Swift/Toolchains"),
            ("ProgramFiles", "Swift/Toolchains"),
        ]
        for (variable, relative) in roots {
            guard let value = environment[variable], !value.isEmpty else { continue }
            let root = URL(fileURLWithPath: value).appendingPathComponent(relative, isDirectory: true)
            for toolchain in FileSystem.children(root) {
                candidates.append(toolchain.appendingPathComponent(
                    "usr/bin/swift" + platform.executableSuffix
                ))
            }
        }
        return candidates
    }

    public func buildArguments(
        application: Application, host: HostID, configuration: BuildConfiguration,
        scratch: URL? = nil, product: String? = nil, swiftSDK: String? = nil,
        triple: String? = nil, sdk: URL? = nil, extra: [String] = []
    ) -> [String] {
        var arguments = [
            "build",
            "--package-path", application.directory.path,
            "--scratch-path", (scratch ?? application.buildDirectory(for: host)).path,
            "--configuration", configuration.rawValue,
        ]
        if let sdk {
            arguments.append(contentsOf: ["--sdk", sdk.path])
        }
        if let triple {
            arguments.append(contentsOf: ["--triple", triple])
        }
        if let swiftSDK {
            arguments.append(contentsOf: ["--swift-sdk", swiftSDK])
        }
        arguments.append(contentsOf: ["--product", product ?? application.product(for: host)])
        arguments.append(contentsOf: extra)
        return arguments
    }

    public func buildInvocation(
        application: Application, host: HostID, configuration: BuildConfiguration,
        scratch: URL? = nil, product: String? = nil, swiftSDK: String? = nil,
        triple: String? = nil, sdk: URL? = nil, extra: [String] = [],
        executable: URL? = nil, label: String? = nil
    ) throws -> ProcessInvocation {
        let swift = try swift(override: executable)
        return ProcessInvocation(
            executable: swift,
            arguments: buildArguments(
                application: application, host: host, configuration: configuration,
                scratch: scratch, product: product, swiftSDK: swiftSDK, triple: triple,
                sdk: sdk, extra: extra
            ),
            environment: ["STATEUI_HOST": host.rawValue],
            workingDirectory: application.directory,
            label: label ?? "Build \(application.product(for: host)) (\(configuration.rawValue))"
        )
    }

    /// Where SwiftPM wrote this build's products. A probe, not a plan step:
    /// the path is needed to name the executable a debugger launches.
    public func binPath(
        application: Application, host: HostID, configuration: BuildConfiguration,
        scratch: URL? = nil, swiftSDK: String? = nil, triple: String? = nil,
        sdk: URL? = nil, executable: URL? = nil
    ) async -> URL {
        let build = scratch ?? application.buildDirectory(for: host)
        let fallback = build.appendingPathComponent(configuration.rawValue, isDirectory: true)
        guard let swift = try? swift(override: executable) else { return fallback }
        var arguments = buildArguments(
            application: application, host: host, configuration: configuration,
            scratch: scratch, swiftSDK: swiftSDK, triple: triple, sdk: sdk
        )
        if let index = arguments.firstIndex(of: "--product") {
            arguments.removeSubrange(index..<min(index + 2, arguments.count))
        }
        arguments.append("--show-bin-path")
        guard let output = await runner.output(swift, arguments, workingDirectory: application.directory,
                                               environment: ["STATEUI_HOST": host.rawValue],
                                               label: "swift build --show-bin-path"),
              let line = output.split(whereSeparator: { $0.isNewline })
                .map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return fallback
        }
        return URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
    }

    /// The paths a Swift SDK was configured with: `sdkRootPath`, `swiftResourcesPath`, and the rest of
    /// `swift sdk configure --show-configuration`. A build for another platform names them to its API record.
    public func swiftSDKConfiguration(id: String, triple: String? = nil) async -> [String: String] {
        guard let swift = try? swift() else { return [:] }
        var arguments = ["sdk", "configure", "--show-configuration", id]
        if let triple { arguments.append(triple) }
        guard let output = await runner.output(
            swift, arguments, label: "swift sdk configure --show-configuration"
        ) else { return [:] }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { values[key] = value }
        }
        return values
    }

    public func xcodeSDKPath(_ name: String) async -> URL? {
        guard let xcrun = runner.which("xcrun"),
              let output = await runner.output(xcrun, ["--sdk", name, "--show-sdk-path"], label: "xcrun --show-sdk-path"),
              !output.contains("error") else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    public func swiftSDKID(family: String) async -> String? {
        guard let swift = try? swift(),
              let version = await runner.output(swift, ["--version"], label: "swift --version"),
              let release = Version.swiftRelease(in: version),
              let list = await runner.output(swift, ["sdk", "list"], label: "swift sdk list") else {
            return nil
        }
        return list.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { $0.lowercased().hasSuffix("_\(family)") }
            .filter { id in
                guard let version = Version.first(in: id) else { return false }
                return Version.sameRelease(Version.swiftRelease(in: version) ?? "", release)
            }
            .last
    }

    public func swiftSDKBundle(id: String) -> URL? {
        let roots = [
            FileSystem.home().appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"),
            FileSystem.home().appendingPathComponent(".swiftpm/swift-sdks"),
        ]
        for root in roots {
            for entry in FileSystem.children(root) where entry.pathExtension == "artifactbundle" {
                let info = entry.appendingPathComponent("info.json")
                if let text = try? FileSystem.read(info), text.contains("\"\(id)\"") {
                    return entry
                }
            }
        }
        return nil
    }

    public func xcrun() throws -> URL {
        guard let xcrun = runner.which("xcrun") else {
            throw ToolingError.toolchainMissing(
                "xcrun was not found.",
                suggestion: "Install Xcode 27 and select it with xcode-select."
            )
        }
        return xcrun
    }
}

/// The triple and SDK a host's heads are compiled for when that is not this
/// machine.
public enum HostCompilation {
    /// The simulator's architecture is the machine's: an Intel Mac runs x86_64
    /// simulators, and an arm64 triple it cannot run is not a universal build.
    public static var uikitSimulatorTriple: String {
        let architecture = Platform.current.architecture == .x86_64 ? "x86_64" : "arm64"
        return "\(architecture)-apple-ios26.0-simulator"
    }
    public static let uikitDeviceTriple = "arm64-apple-ios26.0"
    public static let androidTriple = "aarch64-unknown-linux-android28"
    public static let androidX8664Triple = "x86_64-unknown-linux-android28"
    public static let webTriple = "wasm32-unknown-wasip1"

    public static func androidTriple(for abi: String) -> String? {
        switch abi {
        case "arm64-v8a": return androidTriple
        case "x86_64": return androidX8664Triple
        default: return nil
        }
    }
}
