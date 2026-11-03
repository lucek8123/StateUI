// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What GNOME shows for a GTK head: the icon the desktop draws for an
/// application's ID, and the entry that starts it. Both are installed for the
/// user, under the data directory freedesktop's spec names.
enum GTKDesktop {
    /// The application's ID, as its GTK head passes it to the host -
    /// `exit(StateUIGTK.run(applicationID: "com.stateui.gallery"))`.
    static func applicationID(in main: URL) -> String? {
        guard let text = try? String(contentsOf: main, encoding: .utf8) else { return nil }
        let marker = #"applicationID: ""#
        guard let start = text.range(of: marker) else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "\"") else { return nil }
        let identifier = String(rest[..<end.lowerBound])
        return identifier.isEmpty ? nil : identifier
    }

    /// Where freedesktop's spec puts a user's data: `XDG_DATA_HOME`, and
    /// `~/.local/share` where that variable is unset or empty.
    static func dataDirectory(_ environment: Environment) -> URL {
        if let named = environment["XDG_DATA_HOME"], !named.isEmpty {
            return FileSystem.expand(named)
        }
        return FileSystem.home().appendingPathComponent(".local/share", isDirectory: true)
    }

    /// The entry a launcher writes for the head this build produced. Its
    /// `Icon` is the ID the window is shown under, and `StartupWMClass` is the
    /// product the head's window names itself with.
    static func entry(name: String, executable: URL, applicationID: String, wmClass: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=\(name)
        Exec=\(executable.path)
        Icon=\(applicationID)
        StartupWMClass=\(wmClass)
        Terminal=false
        Categories=Development;

        """
    }

    /// The changes that install the icon and the entry for the user, where the
    /// head declares an ID and the application has GNOME's artwork. Nothing
    /// where either is missing: the head still runs, it just shows no icon.
    static func install(
        application: Application, executable: URL, environment: Environment
    ) -> [FileAction] {
        let main = application.directory.appendingPathComponent("Platforms/GTK/main.swift")
        guard let identifier = applicationID(in: main) else { return [] }
        let artwork = HostSupport.appIcon(application).appendingPathComponent("appicon_gnome.svg")
        guard FileSystem.exists(artwork), !FileSystem.isDirectory(artwork) else { return [] }

        let data = dataDirectory(environment)
        let icon = data.appendingPathComponent("icons/hicolor/scalable/apps/\(identifier).svg")
        let entryFile = data.appendingPathComponent("applications/\(identifier).desktop")
        let product = application.product(for: .gtk)
        let text = entry(name: application.name, executable: executable, applicationID: identifier, wmClass: product)
        return [
            .createDirectory(icon.deletingLastPathComponent()),
            .copy(artwork, to: icon),
            .createDirectory(entryFile.deletingLastPathComponent()),
            .write(text, to: entryFile),
        ]
    }
}
