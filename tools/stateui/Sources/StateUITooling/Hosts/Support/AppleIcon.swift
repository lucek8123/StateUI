// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Draws a macOS `.icns` from an application's SVG artwork with the tools
/// macOS ships. Returns no steps where the artwork or the tools are absent;
/// the bundle then has no custom icon, which is not an error.
enum AppleIcon {
    static func steps(
        source: URL, iconset: URL, output: URL, workingDirectory: URL,
        environment: Environment = .current
    ) -> [ProcessInvocation] {
        guard FileSystem.exists(source),
              let mkdir = FileSystem.findExecutable("mkdir", environment: environment),
              let sips = FileSystem.findExecutable("sips", environment: environment),
              let iconutil = FileSystem.findExecutable("iconutil", environment: environment) else {
            return []
        }
        var steps = [
            HostSupport.run(mkdir, ["-p", iconset.path], cwd: workingDirectory, label: "Create the icon set")
        ]
        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
        ]
        for (size, name) in sizes {
            steps.append(HostSupport.run(
                sips, ["-s", "format", "png", "-z", "\(size)", "\(size)", source.path,
                       "--out", iconset.appendingPathComponent(name).path],
                cwd: workingDirectory, label: "Draw \(name)"
            ))
        }
        steps.append(HostSupport.run(
            iconutil, ["-c", "icns", iconset.path, "-o", output.path],
            cwd: workingDirectory, label: "Assemble StateUI.icns"
        ))
        return steps
    }
}
