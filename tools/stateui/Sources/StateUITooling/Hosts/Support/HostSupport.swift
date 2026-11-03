// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum HostSupport {
    static func application(_ context: ProjectContext) throws -> Application {
        try context.requiringApplication()
    }

    static func checkout(_ context: ProjectContext) throws -> URL {
        guard let checkout = context.checkout else {
            throw ToolingError.projectNotFound(
                "The application does not name a StateUI checkout.",
                context: ["application": context.application?.name ?? ""],
                suggestion: "Add the StateUI checkout to the application's Package.swift, or open the checkout itself."
            )
        }
        return checkout
    }

    static func exists(_ url: URL) -> Bool { FileSystem.exists(url) }

    static func images(_ application: Application) -> URL {
        application.directory.appendingPathComponent("Resources/Images", isDirectory: true)
    }

    static func appIcon(_ application: Application) -> URL {
        application.directory.appendingPathComponent("Resources/AppIcon", isDirectory: true)
    }

    static func infoPlist(
        executable: String, identifier: String, name: String, version: String = ToolingVersion.version,
        minimumSystemVersion: String? = nil, extra: [String: Any] = [:]
    ) -> String {
        var values: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": name,
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
            "NSHighResolutionCapable": true,
        ]
        if let minimumSystemVersion {
            values["LSMinimumSystemVersion"] = minimumSystemVersion
        }
        values.merge(extra) { _, new in new }
        return plist(values)
    }

    static func plist(_ values: [String: Any]) -> String {
        var text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        """
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            text += "\t<key>\(xml(key))</key>\n"
            text += element(value)
        }
        text += "</dict>\n</plist>\n"
        return text
    }

    private static func element(_ value: Any) -> String {
        switch value {
        case let value as String:
            return "\t<string>\(xml(value))</string>\n"
        case let value as Bool:
            return "\t<\(value ? "true" : "false")/>\n"
        case let value as Int:
            return "\t<integer>\(value)</integer>\n"
        case let value as [String]:
            var text = "\t<array>\n"
            for item in value { text += "\t\t<string>\(xml(item))</string>\n" }
            text += "\t</array>\n"
            return text
        case let value as [Any]:
            var text = "\t<array>\n"
            for item in value { text += element(item) }
            text += "\t</array>\n"
            return text
        case let value as [String: Any]:
            var text = "\t<dict>\n"
            for key in value.keys.sorted() {
                guard let nested = value[key] else { continue }
                text += "\t\t<key>\(xml(key))</key>\n"
                text += element(nested)
            }
            text += "\t</dict>\n"
            return text
        default:
            return "\t<string>\(xml(String(describing: value)))</string>\n"
        }
    }

    static func xml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func lowercaseIdentifier(_ name: String) -> String {
        "com.stateui." + name.lowercased()
    }

    /// This `stateui` executable, for the hidden subcommands a plan runs.
    static func currentExecutable(environment: Environment = .current) -> URL {
        let argument = ProcessInfo.processInfo.arguments.first ?? "stateui"
        if argument.contains("/") || argument.contains("\\") {
            return URL(fileURLWithPath: argument).standardizedFileURL
        }
        return FileSystem.findExecutable(argument, environment: environment)
            ?? URL(fileURLWithPath: argument)
    }

    static func run(
        _ executable: URL, _ arguments: [String], cwd: URL, label: String,
        environment: [String: String] = [:], mode: ExecutionMode = .run, allowFailure: Bool = false
    ) -> ProcessInvocation {
        ProcessInvocation(
            executable: executable, arguments: arguments, environment: environment,
            workingDirectory: cwd, label: label, mode: mode, allowFailure: allowFailure
        )
    }

    static func availability(
        _ host: HostID, platform: Platform, toolchainReady: Bool, deviceAvailable: Bool = false,
        reason: String? = nil
    ) -> HostAvailability {
        let supported = host.developmentPlatforms.contains(platform.projectPlatform)
        guard supported else {
            return HostAvailability(
                host: host, status: .unsupportedOperatingSystem,
                reason: "\(host.label) is built on \(host.developmentPlatforms.map(\.rawValue).joined(separator: " and ")); this machine is \(platform.operatingSystem.rawValue).",
                toolchainReady: false, deviceAvailable: false
            )
        }
        guard toolchainReady else {
            return HostAvailability(
                host: host, status: .toolchainMissing,
                reason: reason ?? "The \(host.label) toolchain is incomplete. Run `stateui doctor --host \(host.rawValue)`.",
                toolchainReady: false, deviceAvailable: deviceAvailable
            )
        }
        return HostAvailability(
            host: host, status: .ready, reason: reason,
            toolchainReady: true, deviceAvailable: deviceAvailable
        )
    }
}

extension Platform {
    var projectPlatform: ProjectPlatform {
        switch operatingSystem {
        case .macOS: return .macOS
        case .linux: return .linux
        case .windows: return .windows
        case .unknown: return .linux
        }
    }
}

extension URL {
    var isDirectoryURL: Bool { FileSystem.isDirectory(self) }
}
