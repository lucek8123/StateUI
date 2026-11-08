// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import StateUITooling

/// Temporary projects built on disk: discovery, configuration and scaffolding
/// read real files, so the tests give them real files.
enum TestFixture {
    static func temporaryDirectory(_ name: String = "stateui") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// A file that looks like a tool a PATH search would find, without anything
    /// being run: the tests use it to prove an executable is resolved from the
    /// environment rather than from beside the checkout.
    @discardableResult
    static func fakeTool(named name: String, in directory: URL, contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        #if os(Windows)
        // A PATH search on Windows looks for the executable suffix, and a file with that suffix must be an
        // executable; the tests that plan never run this stand-in.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".exe")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: shell), to: url)
        return url
        #else
        let url = directory.appendingPathComponent(name)
        try write(contents, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
        #endif
    }

    /// A command interpreter that stands on every machine: the POSIX shell, or Windows' own.
    static var shell: String {
        #if os(Windows)
        return ProcessInfo.processInfo.environment["COMSPEC"] ?? "C:\\Windows\\System32\\cmd.exe"
        #else
        return "/bin/sh"
        #endif
    }

    @discardableResult
    static func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A checkout as discovery recognises it: the library, a package and apps.
    @discardableResult
    static func makeCheckout(
        at root: URL, applications: [String] = ["Gallery"], hosts: [HostID] = [.gtk, .web]
    ) throws -> URL {
        try write("// checkout\n", to: root.appendingPathComponent("Package.swift"))
        try write(
            "// library\n",
            to: root.appendingPathComponent("lib/StateUI/Core/Sources/StateUI.swift")
        )
        try write("// head\n", to: root.appendingPathComponent("lib/StateUI.Head/Package.swift"))
        for application in applications {
            try makeApplication(
                at: root.appendingPathComponent("apps/\(application)"), name: application, hosts: hosts
            )
        }
        return root
    }

    @discardableResult
    static func makeApplication(
        at directory: URL, name: String, hosts: [HostID] = [.gtk, .web]
    ) throws -> URL {
        try write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "\(name)",
                dependencies: [.package(path: "../..")],
                targets: [.executableTarget(name: "\(name)GTK")]
            )
            """,
            to: directory.appendingPathComponent("Package.swift")
        )
        for host in hosts {
            // A GTK head names the ID the desktop shows its window under.
            if host == .gtk {
                try write(
                    "exit(StateUIGTK.run(applicationID: \"com.stateui.\(name.lowercased())\"))\n",
                    to: directory.appendingPathComponent(host.headMarker)
                )
            } else {
                try write("// \(host.label) head\n", to: directory.appendingPathComponent(host.headMarker))
            }
        }
        if hosts.contains(.gtk) {
            try write(
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>\n",
                to: directory.appendingPathComponent("Resources/AppIcon/appicon_gnome.svg")
            )
        }
        return directory
    }
}

extension Tooling {
    /// A tooling instance rooted at a fixture, with deterministic processes.
    static func fixture(
        at root: URL, executor: any ProcessExecuting = ScriptedProcessExecutor(),
        environment: Environment = .current, platform: Platform = .current
    ) -> Tooling {
        Tooling(
            executor: executor, environment: environment, platform: platform,
            logger: Logger(level: .quiet), cwd: root
        )
    }
}

/// Records what a plan would run and makes any probing invocation succeed.
actor RecordingExecutor: ProcessExecuting {
    private(set) var invocations: [ProcessInvocation] = []

    func execute(
        _ invocation: ProcessInvocation,
        onOutput: (@Sendable (ProcessOutput) -> Void)?
    ) async throws -> ProcessResult {
        invocations.append(invocation)
        return ProcessResult(exitCode: 0)
    }

    func recorded() -> [ProcessInvocation] { invocations }
}
