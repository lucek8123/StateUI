// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small, testable file-system operations used throughout the tool.
public enum FileSystem {
    nonisolated(unsafe) public static let manager = FileManager.default

    public static func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public static func isExecutable(_ url: URL) -> Bool {
        manager.isExecutableFile(atPath: url.path)
    }

    public static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public static func write(_ text: String, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    public static func write(_ data: Data, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public static func remove(_ url: URL) throws {
        guard exists(url) else { return }
        try manager.removeItem(at: url)
    }

    public static func makeDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public static func copy(_ source: URL, to destination: URL) throws {
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists(destination) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
    }

    /// Copies a directory tree, skipping any entry whose name is or ends with
    /// one of `excluding` at any depth.
    public static func copyTree(_ source: URL, to destination: URL, excluding: Set<String> = []) throws {
        try makeDirectory(destination)
        let entries = try manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        for entry in entries {
            let name = entry.lastPathComponent
            if excluding.contains(name) || excluding.contains(where: { name.hasSuffix($0) }) { continue }
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            if isDirectory(entry) {
                try copyTree(entry, to: target, excluding: excluding)
            } else {
                // Replacing, not creating: a build that runs twice copies the same
                // pictures over the ones the last run laid down.
                try copy(entry, to: target)
            }
        }
    }

    public static func children(_ directory: URL) -> [URL] {
        (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        } ?? []
    }

    public static func relativePath(from base: URL, to target: URL) -> String {
        // Symlinks are resolved first: macOS's /var and /tmp are links into
        // /private, and a relative path counted over the link's spelling points
        // at a directory that does not exist. `realpath` is used because
        // Foundation's `resolvingSymlinksInPath` leaves /var as /var on macOS.
        let baseParts = canonical(base).pathComponents
        let targetParts = canonical(target).pathComponents
        var common = 0
        while common < min(baseParts.count, targetParts.count), baseParts[common] == targetParts[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: baseParts.count - common)
        let down = targetParts.dropFirst(common)
        return (up + down).joined(separator: "/")
    }

    /// The path with every symlink resolved, as the kernel sees it. Foundation's
    /// own resolver leaves macOS's root-level `/var` and `/tmp` links unresolved.
    private static func canonical(_ url: URL) -> URL {
        #if canImport(Darwin) || canImport(Glibc)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer))
        }
        #endif
        return url.standardizedFileURL
    }

    public static func expand(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    public static func findExecutable(_ name: String, environment: Environment = .current) -> URL? {
        if name.contains("/") || name.contains("\\") {
            let url = expand(name)
            return isExecutable(url) ? url : nil
        }
        let names = [name, name + Platform.current.executableSuffix]
        for directory in environment.pathDirectories {
            for candidate in names {
                let url = directory.appendingPathComponent(candidate)
                if isExecutable(url) { return url }
            }
        }
        return nil
    }

    public static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    public static func temporaryDirectory(prefix: String = "stateui") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)", isDirectory: true
        )
        try makeDirectory(url)
        return url
    }
}
