// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Checks the native toolchains, SDKs and devices a host needs.
public struct ToolchainService: Sendable {
    public let runner: CommandRunner
    public let platform: Platform
    public let environment: Environment

    public init(
        executor: any ProcessExecuting, environment: Environment = .current, platform: Platform = .current
    ) {
        self.runner = CommandRunner(executor: executor, environment: environment)
        self.platform = platform
        self.environment = environment
    }

    public func report(hosts requested: [HostID]? = nil) async -> ToolchainReport {
        let hosts = requested ?? HostID.allCases
        var findings: [ToolchainFinding] = []

        findings.append(await swiftFinding(hosts: hosts))
        findings.append(await lldbDapFinding(hosts: hosts))
        findings.append(await gitFinding(hosts: hosts))
        findings.append(await nodeFinding(hosts: hosts))

        switch platform.operatingSystem {
        case .macOS:
            findings.append(contentsOf: await macFindings(hosts: hosts))
        case .linux:
            findings.append(contentsOf: await linuxFindings(hosts: hosts))
        case .windows:
            findings.append(contentsOf: await windowsFindings(hosts: hosts))
        case .unknown:
            break
        }

        if hosts.contains(.web) {
            findings.append(contentsOf: await webFindings(hosts: hosts))
        }
        if hosts.contains(.android) {
            findings.append(await androidFinding(hosts: hosts))
        }

        return ToolchainReport(
            platform: platform,
            findings: findings.filter { finding in
                requested == nil || finding.neededBy.contains(where: { hosts.contains($0) })
            }
        )
    }

    private func swiftFinding(hosts: [HostID]) async -> ToolchainFinding {
        guard let swift = runner.which("swift") ?? (environment["SWIFT_BIN"].map { FileSystem.expand($0) }) else {
            return ToolchainFinding(
                component: "Swift 6.4 or newer", neededBy: hosts, status: .missing,
                requiredVersion: "6.4", requiredPlatform: platform.description,
                advice: "Install Swift 6.4 from https://www.swift.org/install (Xcode 27 brings it; swift.org's installer has it for older Xcode)."
            )
        }
        let output = await runner.output(swift, ["--version"], label: "swift --version") ?? ""
        let version = Version.swiftRelease(in: output)
        let org = output.contains("(swift-")
        let status: ToolchainFinding.Status = version.map { Version.atLeast($0, "6.4") } == true ? .found : .tooOld
        return ToolchainFinding(
            component: org ? "Swift 6.4 or newer (swift.org)" : "Swift 6.4 or newer",
            neededBy: hosts, status: status, version: version, executable: swift.path,
            requiredVersion: "6.4", requiredPlatform: platform.description,
            advice: status == .found ? "" : "Install Swift 6.4 from https://www.swift.org/install."
        )
    }

    private func lldbDapFinding(hosts: [HostID]) async -> ToolchainFinding {
        var candidates: [URL] = []
        if platform.operatingSystem == .macOS, let xcrun = runner.which("xcrun") {
            if let path = await runner.output(xcrun, ["--find", "lldb-dap"], label: "xcrun lldb-dap")?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                candidates.append(URL(fileURLWithPath: path))
            }
        }
        if let swift = runner.which("swift") {
            candidates.append(swift.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("lldb-dap" + platform.executableSuffix))
        }
        if let found = runner.which("lldb-dap") { candidates.append(found) }
        let executable = candidates.first(where: FileSystem.isExecutable)
        let debugHosts = hosts.filter { $0 != .web }
        return ToolchainFinding(
            component: "lldb-dap", neededBy: debugHosts, status: executable == nil ? .missing : .found,
            executable: executable?.path, requiredPlatform: platform.description,
            advice: executable == nil
                ? "Install the Swift toolchain's lldb-dap and put its bin directory on PATH."
                : ""
        )
    }

    private func gitFinding(hosts: [HostID]) async -> ToolchainFinding {
        let git = runner.which("git")
        var output = ""
        if let git {
            output = await runner.output(git, ["--version"], label: "git --version") ?? ""
        }
        let version = git.flatMap { _ in Version.first(in: output) }
        return ToolchainFinding(
            component: "Git", neededBy: hosts, status: git == nil ? .missing : .found,
            version: version, executable: git?.path, advice: "Install Git from https://git-scm.com (needed to list or clone StateUI releases).", blocking: false
        )
    }

    private func nodeFinding(hosts: [HostID]) async -> ToolchainFinding {
        let node = runner.which("node")
        var version: String?
        if let node, let text = await runner.output(node, ["--version"], label: "node --version") {
            version = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
        }
        let status: ToolchainFinding.Status = version.map { Version.atLeast($0, "20") } == true ? .found : (node == nil ? .missing : .tooOld)
        return ToolchainFinding(
            component: "Node.js 20 or newer", neededBy: hosts, status: status, version: version,
            executable: node?.path, requiredVersion: "20", advice: "Install Node.js 20 or newer from https://nodejs.org (editor and Web test builds).", blocking: false
        )
    }

    private func macFindings(hosts: [HostID]) async -> [ToolchainFinding] {
        var findings: [ToolchainFinding] = []
        if let swVers = runner.which("sw_vers") {
            let version = await runner.output(swVers, ["-productVersion"], label: "sw_vers")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            findings.append(ToolchainFinding(
                component: "macOS 26 or newer", neededBy: hosts.filter { $0 == .appKit || $0 == .uiKit },
                status: version.map { Version.atLeast($0, "26") } == true ? .found : .tooOld,
                version: version, requiredVersion: "26", advice: "Update macOS to 26 or newer."
            ))
        }
        if let xcodebuild = runner.which("xcodebuild") {
            let output = await runner.output(xcodebuild, ["-version"], label: "xcodebuild") ?? ""
            let version = output.range(of: #"Xcode (\d+(?:\.\d+)*)"#, options: .regularExpression)
                .map { String(output[$0]).replacingOccurrences(of: "Xcode ", with: "") }
            findings.append(ToolchainFinding(
                component: "Xcode 26 or newer", neededBy: hosts.filter { $0 == .appKit || $0 == .uiKit },
                status: version.map { Version.atLeast($0, "26") } == true ? .found : .tooOld,
                version: version, requiredVersion: "26",
                advice: "Install Xcode 26 or newer, run it once, or select it with xcode-select."
            ))
        } else {
            findings.append(ToolchainFinding(
                component: "Xcode 26 or newer", neededBy: hosts.filter { $0 == .appKit || $0 == .uiKit },
                status: .missing, requiredVersion: "26", advice: "Install Xcode 26 or newer from the App Store."
            ))
        }
        if let xcrun = runner.which("xcrun") {
            let output = await runner.output(xcrun, ["simctl", "list", "runtimes", "available", "-j"], label: "simctl runtimes")
            let version = output.flatMap(Self.newestIOSRuntime)
            findings.append(ToolchainFinding(
                component: "an iOS 26 or newer simulator runtime", neededBy: hosts.filter { $0 == .uiKit },
                status: version.map { Version.atLeast($0, "26") } == true ? .found : .tooOld,
                version: version, requiredVersion: "26",
                advice: "Install an iOS platform in Xcode's Settings, Components."
            ))
        }
        if let security = runner.which("security") {
            let output = await runner.output(security, ["find-identity", "-v", "-p", "codesigning"], label: "security identities") ?? ""
            let identity = output.range(of: #""Apple Development: [^"]+""#, options: .regularExpression).map(String.init)
            findings.append(ToolchainFinding(
                component: "an Apple Development certificate", neededBy: hosts.filter { $0 == .uiKit },
                status: identity == nil ? .missing : .found, version: identity, advice: "Sign in with your Apple Account in Xcode, Accounts, and create a development certificate.", blocking: false
            ))
        }
        return findings
    }

    private func linuxFindings(hosts: [HostID]) async -> [ToolchainFinding] {
        guard hosts.contains(.gtk) else { return [] }
        var findings: [ToolchainFinding] = []
        let pkgConfig = runner.which("pkg-config")
        findings.append(ToolchainFinding(
            component: "pkg-config", neededBy: [.gtk], status: pkgConfig == nil ? .missing : .found,
            executable: pkgConfig?.path, advice: "Install pkg-config."
        ))
        guard let pkgConfig else { return findings }

        func module(_ name: String, component: String, minimum: String, advice: String, blocking: Bool = true) async -> ToolchainFinding {
            let version = await runner.output(pkgConfig, ["--modversion", name], label: "pkg-config \(name)")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let status: ToolchainFinding.Status = version.map { Version.atLeast($0, minimum) } == true ? .found : (version == nil ? .missing : .tooOld)
            return ToolchainFinding(
                component: component, neededBy: [.gtk], status: status, version: version,
                executable: pkgConfig.path, requiredVersion: minimum, advice: advice, blocking: blocking
            )
        }

        findings.append(await module("gtk4", component: "GTK 4.14 or newer, with headers", minimum: "4.14",
                                     advice: "Install libgtk-4-dev (Ubuntu) or gtk4 (Arch)."))
        findings.append(await module("libadwaita-1", component: "libadwaita 1.5 or newer, with headers", minimum: "1.5",
                                     advice: "Install libadwaita-1-dev (Ubuntu) or libadwaita (Arch)."))
        findings.append(await module("webkitgtk-6.0", component: "WebKitGTK 6.0, with headers", minimum: "2.40",
                                     advice: "Install libwebkitgtk-6.0-dev (Ubuntu) or webkitgtk-6.0 (Arch)."))
        findings.append(await svgLoaderFinding(pkgConfig: pkgConfig))
        let session = environment["WAYLAND_DISPLAY"].map { "Wayland (\($0))" }
            ?? environment["DISPLAY"].map { "X11 (\($0))" }
        findings.append(ToolchainFinding(
            component: "a desktop session", neededBy: [.gtk], status: session == nil ? .missing : .found,
            version: session, advice: "Run from a Wayland or X11 session: nothing shows a window without one."
        ))
        return findings
    }

    private func svgLoaderFinding(pkgConfig: URL) async -> ToolchainFinding {
        var cache = environment["GDK_PIXBUF_MODULE_FILE"]
        if cache == nil {
            cache = await runner.output(pkgConfig, ["--variable=gdk_pixbuf_cache_file", "gdk-pixbuf-2.0"], label: "gdk-pixbuf cache")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var loader: String?
        if let cache, FileSystem.exists(URL(fileURLWithPath: cache)),
           let text = try? FileSystem.read(URL(fileURLWithPath: cache)), text.contains("image/svg+xml") {
            loader = "gdk-pixbuf SVG loader"
        }
        if loader == nil {
            let folders = (environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share")
                .split(separator: ":").map(String.init)
            for folder in folders {
                let loaders = URL(fileURLWithPath: folder).appendingPathComponent("glycin-loaders")
                for version in FileSystem.children(loaders) {
                    let configs = version.appendingPathComponent("conf.d")
                    for config in FileSystem.children(configs) where config.pathExtension == "conf" {
                        if let text = try? FileSystem.read(config), text.contains("[loader:image/svg+xml]") {
                            loader = "glycin SVG loader"
                        }
                    }
                }
            }
        }
        return ToolchainFinding(
            component: "gdk-pixbuf's SVG loader", neededBy: [.gtk], status: loader == nil ? .missing : .found,
            version: loader, advice: "Install librsvg2-common, or glycin's loaders where gdk-pixbuf reads through glycin.", blocking: false
        )
    }

    private func windowsFindings(hosts: [HostID]) async -> [ToolchainFinding] {
        guard hosts.contains(.winUI) else { return [] }
        var findings: [ToolchainFinding] = []
        let programs = environment["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)"
        let vswhere = URL(fileURLWithPath: programs).appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
        if FileSystem.isExecutable(vswhere) {
            let component = platform.architecture == .arm64
                ? "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
                : "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
            let version = await runner.output(vswhere, ["-latest", "-products", "*", "-requires", component, "-property", "installationVersion"], label: "vswhere")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            findings.append(ToolchainFinding(
                component: "Visual Studio 2026 with the C++ tools", neededBy: [.winUI],
                status: version.map { Version.atLeast(Version.first(in: $0) ?? "0", "18") } == true ? .found : .tooOld,
                version: version, requiredVersion: "18",
                advice: "Install Visual Studio 2026 with Desktop development with C++."
            ))
        }
        let webview = URL(fileURLWithPath: programs).appendingPathComponent("Microsoft/EdgeWebView/Application")
        let version = FileSystem.children(webview)
            .filter { $0.lastPathComponent.range(of: #"^\d+\."#, options: .regularExpression) != nil }
            .sorted { Version.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }.last
        findings.append(ToolchainFinding(
            component: "the WebView2 runtime", neededBy: [.winUI],
            status: version == nil ? .missing : .found, version: version?.lastPathComponent,
            advice: "Install the Evergreen WebView2 Runtime."
        ))
        let windowsSDK = URL(fileURLWithPath: programs).appendingPathComponent("Windows Kits/10/Include")
        let sdk = FileSystem.children(windowsSDK).first { $0.lastPathComponent.hasPrefix("10.0.26100") }
        findings.append(ToolchainFinding(
            component: "the Windows SDK 10.0.26100", neededBy: [.winUI],
            status: sdk == nil ? .missing : .found, version: sdk?.lastPathComponent,
            advice: "Install the Windows 11 SDK (10.0.26100) with the Visual Studio Installer."
        ))
        return findings
    }

    private func webFindings(hosts: [HostID]) async -> [ToolchainFinding] {
        var findings: [ToolchainFinding] = []
        if let swift = runner.which("swift"),
           let version = await runner.output(swift, ["--version"], label: "swift --version"),
           let release = Version.swiftRelease(in: version),
           let list = await runner.output(swift, ["sdk", "list"], label: "swift sdk list") {
            let sdk = list.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                .filter { $0.lowercased().hasSuffix("_wasm") }
                .filter { id in
                    guard let idVersion = Version.first(in: id) else { return false }
                    return Version.sameRelease(Version.swiftRelease(in: idVersion) ?? "", release)
                }.last
            findings.append(ToolchainFinding(
                component: "the Swift SDK for WebAssembly of Swift's release", neededBy: [.web],
                status: sdk == nil ? .missing : .found, version: sdk, executable: swift.path,
                advice: "Install it with `swift sdk install`."
            ))
        } else {
            findings.append(ToolchainFinding(
                component: "the Swift SDK for WebAssembly of Swift's release", neededBy: [.web],
                status: .missing, advice: "Install Swift 6.4 and the matching WebAssembly SDK."
            ))
        }
        let python = runner.which("python3")
        findings.append(ToolchainFinding(
            component: "Python 3", neededBy: [.web], status: python == nil ? .missing : .found,
            executable: python?.path, advice: "Install Python 3 (used by the host's test harness).", blocking: false
        ))
        return findings
    }

    private func androidFinding(hosts: [HostID]) async -> ToolchainFinding {
        do {
            let toolchain = try await AndroidToolchain.discover(environment: environment, platform: platform, runner: runner)
            return ToolchainFinding(
                component: "Android SDK, NDK, JDK 21 and matching Swift SDK", neededBy: [.android],
                status: .found,
                version: "\(toolchain.swiftSDKID), NDK \(toolchain.ndkVersion ?? "?")",
                executable: toolchain.swift.path,
                requiredVersion: "NDK 30+, platform 36, JDK 21",
                environmentVariables: ["ANDROID_HOME": toolchain.sdk.path], advice: ""
            )
        } catch {
            let structured = error.toolingError
            return ToolchainFinding(
                component: "Android SDK, NDK, JDK 21 and matching Swift SDK", neededBy: [.android],
                status: .missing, requiredVersion: "NDK 30+, platform 36, JDK 21",
                advice: structured.suggestion ?? structured.message
            )
        }
    }

    public static func newestIOSRuntime(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = object["runtimes"] as? [[String: Any]] else { return nil }
        return runtimes.compactMap { runtime -> String? in
            let platform = runtime["platform"] as? String
            let name = runtime["name"] as? String
            guard platform == "iOS" || name?.hasPrefix("iOS") == true else { return nil }
            if runtime["isAvailable"] as? Bool == false { return nil }
            return runtime["version"] as? String
        }.sorted { Version.compare($0, $1) < 0 }.last
    }
}
