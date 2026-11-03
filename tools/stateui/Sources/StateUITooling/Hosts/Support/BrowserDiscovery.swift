// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The browsers installed on this machine, and a page opened in one.
public struct BrowserDiscovery: Sendable {
    public let runner: CommandRunner
    public let environment: Environment
    public let platform: Platform

    public init(runner: CommandRunner, environment: Environment = .current, platform: Platform = .current) {
        self.runner = runner
        self.environment = environment
        self.platform = platform
    }

    public func browsers() async -> [Browser] {
        switch platform.operatingSystem {
        case .macOS: return macBrowsers()
        case .linux: return await linuxBrowsers()
        default: return []
        }
    }

    public func browser(id: String) async -> Browser? {
        await browsers().first { $0.id == id || $0.name == id }
    }

    private func macBrowsers() -> [Browser] {
        let known: [(id: String, name: String, application: String)] = [
            ("com.apple.Safari", "Safari", "Safari.app"),
            ("com.google.Chrome", "Google Chrome", "Google Chrome.app"),
            ("org.chromium.Chromium", "Chromium", "Chromium.app"),
            ("com.microsoft.edgemac", "Microsoft Edge", "Microsoft Edge.app"),
            ("com.brave.Browser", "Brave", "Brave Browser.app"),
            ("com.vivaldi.Vivaldi", "Vivaldi", "Vivaldi.app"),
            ("org.mozilla.firefox", "Firefox", "Firefox.app"),
        ]
        let roots = [URL(fileURLWithPath: "/Applications"), FileSystem.home().appendingPathComponent("Applications")]
        var found: [Browser] = []
        for entry in known {
            for root in roots {
                let application = root.appendingPathComponent(entry.application, isDirectory: true)
                guard FileSystem.isDirectory(application) else { continue }
                let executable = application.appendingPathComponent("Contents/MacOS")
                    .appendingPathComponent(entry.application.replacingOccurrences(of: ".app", with: ""))
                found.append(Browser(
                    id: entry.id, name: entry.name,
                    executable: FileSystem.isExecutable(executable) ? executable.path : "",
                    isDefault: entry.id == "com.apple.Safari",
                    isChromium: Browser.isChromiumID(entry.id)
                ))
                break
            }
        }
        return found
    }

    private func linuxBrowsers() async -> [Browser] {
        var preferred = ""
        if let xdg = runner.which("xdg-settings"),
           let output = await runner.output(xdg, ["get", "default-web-browser"], label: "xdg-settings") {
            preferred = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let dataHome = environment["XDG_DATA_HOME"] ?? FileSystem.home().appendingPathComponent(".local/share").path
        let directories = [
            dataHome + "/applications",
            "/usr/local/share/applications",
            "/usr/share/applications",
            "/var/lib/flatpak/exports/share/applications",
            "/var/lib/snapd/desktop/applications",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        var seen = Set<String>()
        var found: [Browser] = []
        for directory in directories where FileSystem.isDirectory(directory) {
            for entry in FileSystem.children(directory) where entry.pathExtension == "desktop" {
                let id = entry.lastPathComponent
                guard seen.insert(id).inserted else { continue }
                guard let text = try? FileSystem.read(entry) else { continue }
                guard text.contains("x-scheme-handler/https"), text.contains("text/html") else { continue }
                if text.split(separator: "\n").contains(where: { $0.hasPrefix("NoDisplay=true") }) { continue }
                let name = Self.value("Name", in: text) ?? id
                let exec = Self.value("Exec", in: text) ?? ""
                let executable = exec.split(separator: " ").first.map(String.init) ?? ""
                let resolved = runner.which(executable)?.path ?? executable
                found.append(Browser(
                    id: id, name: name, executable: resolved,
                    isDefault: id == preferred, isChromium: Browser.isChromiumID(id)
                ))
            }
        }
        return found.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("\(key)=") {
            return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

extension Browser {
    static func isChromiumID(_ id: String) -> Bool {
        id.range(of: "chrome|chromium|edge|brave|vivaldi|opera|thebrowser",
                 options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Opens `url` in this browser. `default` is the system's own; `none`
    /// opens nothing.
    public func open(url: String, environment: Environment = .current, platform: Platform = .current) throws {
        if id == "none" { return }
        let process = Process()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        switch platform.operatingSystem {
        case .macOS:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            if id == "default" || id.isEmpty {
                process.arguments = [url]
            } else {
                process.arguments = ["-b", id, url]
            }
        case .linux:
            if id == "default" || id.isEmpty {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
                process.arguments = [url]
            } else if id.hasSuffix(".desktop") {
                process.executableURL = FileSystem.findExecutable("gtk-launch", environment: environment)
                process.arguments = [String(id.dropLast(".desktop".count)), url]
            } else {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = [url]
            }
        default:
            return
        }
        guard let executable = process.executableURL, FileSystem.isExecutable(executable) else { return }
        try? process.run()
    }
}
