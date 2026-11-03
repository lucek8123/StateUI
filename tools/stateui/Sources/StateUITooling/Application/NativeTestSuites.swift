// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The suites that stand on the machine itself rather than on a host: the foundation's
/// own tests, the host layer's, the conformance contract's, and the applications'.
/// Swift written for one host alone is compiled for it by `STATEUI_HOST`, which each
/// application's manifest reads.
public enum NativeTestSuites {
    /// Every package `stateui test --suite native` runs. macOS adds the AppKit host's
    /// package and the Gallery built as an AppKit head, because the Swift under
    /// `#if APPKIT` compiles only there. Packages that are not there are skipped.
    public static func suites(
        builder: SwiftBuilder, checkout: URL, platform: Platform,
        filter: String? = nil, environment: [String: String] = [:]
    ) throws -> [TestSuitePlan] {
        var requested: [(directory: URL, name: String, detail: String, environment: [String: String], scratch: URL?)] = [
            (
                checkout, "the repository's own packages",
                "the foundation and the library, with no host attached", environment, nil
            ),
            (
                checkout.appendingPathComponent("lib/StateUI/StateUI.Host", isDirectory: true),
                "lib/StateUI/StateUI.Host", "the host layer's own tests", environment, nil
            ),
            (
                checkout.appendingPathComponent("lib/StateUI/StateUI.Conformance", isDirectory: true),
                "lib/StateUI/StateUI.Conformance", "the contract's families, run against the library",
                environment, nil
            ),
        ]
        if platform.operatingSystem == .macOS {
            requested.append((
                checkout.appendingPathComponent("lib/StateUI/StateUI.AppKit", isDirectory: true),
                "lib/StateUI/StateUI.AppKit", "the AppKit host's own tests",
                ["STATEUI_HOST": "appkit"], nil
            ))
        }
        requested.append((
            checkout.appendingPathComponent("apps/Gallery", isDirectory: true),
            "apps/Gallery", "the Gallery's own tests", environment, nil
        ))
        requested.append((
            checkout.appendingPathComponent("apps/HelloWorld", isDirectory: true),
            "apps/HelloWorld", "the HelloWorld's own tests", environment, nil
        ))
        if platform.operatingSystem == .macOS {
            // The Gallery runs once more as an AppKit build, so the Swift under
            // `#if APPKIT` is compiled and tested.
            requested.append((
                checkout.appendingPathComponent("apps/Gallery", isDirectory: true),
                "apps/Gallery as an AppKit head",
                "the same suite compiled with STATEUI_HOST=appkit, in its own scratch directory",
                ["STATEUI_HOST": "appkit"],
                checkout.appendingPathComponent("apps/Gallery/.build/appkit", isDirectory: true)
            ))
        }

        let swift = try builder.swift()
        return requested
            .filter { FileSystem.isDirectory($0.directory) }
            .map { entry in
                var arguments = ["test", "--package-path", entry.directory.path]
                if let scratch = entry.scratch { arguments.append(contentsOf: ["--scratch-path", scratch.path]) }
                if let filter { arguments.append(contentsOf: ["--filter", filter]) }
                return TestSuitePlan(
                    name: entry.name, detail: entry.detail,
                    steps: [HostSupport.run(
                        swift, arguments, cwd: entry.directory, label: "Test \(entry.name)",
                        environment: entry.environment
                    )]
                )
            }
    }

    /// The foundation's tests on this machine's C library and thread numbers - the
    /// branches no other machine runs - run whole. The root package names no host.
    public static func foundation(
        builder: SwiftBuilder, checkout: URL, platform: Platform,
        environment: [String: String] = [:]
    ) throws -> TestSuitePlan {
        let swift = try builder.swift()
        return TestSuitePlan(
            name: "StateUIFoundation on \(osName(platform))",
            detail: "the foundation's own tests, run whole on this machine's C library",
            steps: [HostSupport.run(
                swift, ["test", "--package-path", checkout.path, "--filter", "StateUIFoundationTests"],
                cwd: checkout, label: "Test StateUIFoundation on \(osName(platform))",
                environment: environment
            )]
        )
    }

    private static func osName(_ platform: Platform) -> String {
        switch platform.operatingSystem {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .windows: return "Windows"
        case .unknown: return "this machine"
        }
    }
}
