// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Android toolchain the scripts discover, in the same order.
public struct AndroidToolchain: Sendable {
    public static let ndkMinimumMajor = 30
    public static let gradleVersion = "9.4.1"
    public static let apiLevel = 28
    public static let compileSDK = 36

    public let sdk: URL
    public let ndk: URL
    public let javaHome: URL
    public let swift: URL
    public let swiftSDKID: String
    public let swiftSDKBundle: URL
    public let adb: URL
    public let aapt2: URL
    public let emulator: URL?
    public let gradle: URL?
    public let ndkVersion: String?

    public init(
        sdk: URL, ndk: URL, javaHome: URL, swift: URL, swiftSDKID: String,
        swiftSDKBundle: URL, adb: URL, aapt2: URL, emulator: URL?, gradle: URL?, ndkVersion: String?
    ) {
        self.sdk = sdk
        self.ndk = ndk
        self.javaHome = javaHome
        self.swift = swift
        self.swiftSDKID = swiftSDKID
        self.swiftSDKBundle = swiftSDKBundle
        self.adb = adb
        self.aapt2 = aapt2
        self.emulator = emulator
        self.gradle = gradle
        self.ndkVersion = ndkVersion
    }

    public var adbPath: String { adb.path }
    public var gradlePath: String? { gradle?.path }

    /// The NDK's sysroot, which finds its C headers. The Swift SDK's own `ndk-sysroot` names it only after
    /// its setup script has run; the NDK names it itself.
    public var sysroot: URL? {
        FileSystem.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .map { $0.appendingPathComponent("sysroot") }
            .first(where: FileSystem.isDirectory)
    }

    /// The NDK's clang resource headers - `stddef.h`, `semaphore.h` - which the Swift SDK's `clang` link
    /// names only after its setup script has run.
    public var clangInclude: URL? {
        guard let prebuilt = FileSystem.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .first(where: FileSystem.isDirectory) else { return nil }
        return FileSystem.children(prebuilt.appendingPathComponent("lib/clang"))
            .sorted { Version.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
            .last
            .map { $0.appendingPathComponent("include") }
    }

    public static func discover(
        environment: Environment, platform: Platform, runner: CommandRunner
    ) async throws -> AndroidToolchain {
        let sdk = androidSDK(environment: environment)
        guard let sdk, FileSystem.isDirectory(sdk.appendingPathComponent("platform-tools")) else {
            throw ToolingError.toolchainMissing(
                "The Android SDK was not found.",
                context: ["ANDROID_HOME": environment["ANDROID_HOME"] ?? "", "ANDROID_SDK_ROOT": environment["ANDROID_SDK_ROOT"] ?? ""],
                suggestion: "Install the Android SDK (platform 36, build tools, platform tools) and set ANDROID_HOME."
            )
        }

        guard let ndk = ndkRoot(environment: environment, sdk: sdk) else {
            throw ToolingError.toolchainMissing(
                "The Android NDK was not found.",
                context: ["ANDROID_NDK_ROOT": environment["ANDROID_NDK_ROOT"] ?? ""],
                suggestion: "Install NDK r30 or newer, or set ANDROID_NDK_ROOT."
            )
        }
        let ndkVersion = ndkVersion(ndk)
        if let major = ndkVersion?.split(separator: ".").first.flatMap({ Int($0) }), major < ndkMinimumMajor {
            throw ToolingError.toolchainMissing(
                "The Android NDK at \(ndk.path) is \(ndkVersion ?? "of no known version"); the build requires 30 or newer.",
                context: ["ndk": ndk.path],
                suggestion: "Install NDK r30 or newer, or name one with ANDROID_NDK_ROOT."
            )
        }

        let java = try await javaHome(environment: environment, platform: platform, runner: runner)
        let swift = try await swiftToolchain(environment: environment, platform: platform, runner: runner)
        let sdkMatch = try await swiftSDK(
            for: swift, environment: environment, platform: platform, runner: runner
        )

        let buildTools = sdk.appendingPathComponent("build-tools", isDirectory: true)
        let aapt2Name = "aapt2" + platform.executableSuffix
        let aapt2 = FileSystem.children(buildTools)
            .sorted { Version.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
            .reversed()
            .map { $0.appendingPathComponent(aapt2Name) }
            .first(where: FileSystem.isExecutable)
        guard let aapt2 else {
            throw ToolingError.toolchainMissing(
                "The Android SDK has no build-tools aapt2.",
                context: ["sdk": sdk.path],
                suggestion: "Install Android SDK build tools with the SDK Manager."
            )
        }
        let adb = sdk.appendingPathComponent("platform-tools/adb" + platform.executableSuffix)
        guard FileSystem.isExecutable(adb) else {
            throw ToolingError.toolchainMissing("adb was not found in \(sdk.path)/platform-tools.")
        }
        let emulator = sdk.appendingPathComponent("emulator/emulator" + platform.executableSuffix)
        let gradle = gradleBinary(environment: environment, platform: platform, runner: runner)

        return AndroidToolchain(
            sdk: sdk,
            ndk: ndk,
            javaHome: java,
            swift: swift,
            swiftSDKID: sdkMatch.id,
            swiftSDKBundle: sdkMatch.bundle,
            adb: adb,
            aapt2: aapt2,
            emulator: FileSystem.isExecutable(emulator) ? emulator : nil,
            gradle: gradle,
            ndkVersion: ndkVersion
        )
    }

    public static func androidSDK(environment: Environment) -> URL? {
        let home = FileSystem.home()
        var candidates: [String] = []
        for name in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[name], !value.isEmpty { candidates.append(value) }
        }
        // Where each host's installer and IDE put it.
        candidates.append(home.appendingPathComponent("Library/Android/sdk").path)
        candidates.append(home.appendingPathComponent("Android/Sdk").path)
        candidates.append(home.appendingPathComponent("AppData/Local/Android/Sdk").path)
        for name in ["LOCALAPPDATA", "USERPROFILE", "ProgramFiles"] {
            if let value = environment[name], !value.isEmpty {
                candidates.append(URL(fileURLWithPath: value).appendingPathComponent("Android/Sdk").path)
            }
        }
        return candidates.map { FileSystem.expand($0) }.first {
            FileSystem.isDirectory($0.appendingPathComponent("platform-tools"))
        }
    }

    public static func ndkRoot(environment: Environment, sdk: URL) -> URL? {
        for name in ["ANDROID_NDK_ROOT", "ANDROID_NDK_HOME"] {
            if let value = environment[name], !value.isEmpty {
                let url = FileSystem.expand(value)
                if FileSystem.isDirectory(url.appendingPathComponent("toolchains/llvm/prebuilt")) { return url }
            }
        }
        let ndkDirectory = sdk.appendingPathComponent("ndk", isDirectory: true)
        return FileSystem.children(ndkDirectory)
            .filter { FileSystem.isDirectory($0.appendingPathComponent("toolchains/llvm/prebuilt")) }
            .sorted { Version.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
            .last
    }

    public static func ndkVersion(_ ndk: URL) -> String? {
        let properties = ndk.appendingPathComponent("source.properties")
        guard let text = try? FileSystem.read(properties) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("Pkg.Revision") {
            return line.split(separator: "=", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func javaHome(environment: Environment, platform: Platform, runner: CommandRunner) async throws -> URL {
        let javaName = "java" + platform.executableSuffix
        func isTwentyOne(_ output: String) -> Bool {
            output.contains("\"21.") || output.contains("version 21") || output.contains(" 21.0")
        }

        if platform.operatingSystem == .macOS {
            let javaHome = URL(fileURLWithPath: "/usr/libexec/java_home")
            if let output = await runner.output(javaHome, ["-v", "21"], label: "java_home"),
               !output.contains("Unable"), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let url = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
                if FileSystem.isExecutable(url.appendingPathComponent("bin/\(javaName)")) { return url }
            }
        }
        if let named = environment["JAVA_HOME"], !named.isEmpty {
            let url = FileSystem.expand(named)
            if let output = await runner.output(
                url.appendingPathComponent("bin/\(javaName)"), ["-version"], label: "java"
            ), isTwentyOne(output) { return url }
        }
        // A java on PATH: its home is the directory holding `bin`.
        if let java = runner.which("java") {
            if let output = await runner.output(java, ["-version"], label: "java"), isTwentyOne(output) {
                return java.deletingLastPathComponent().deletingLastPathComponent()
            }
        }
        var roots = [URL(fileURLWithPath: "/usr/lib/jvm"), URL(fileURLWithPath: "/opt/java")]
        for name in ["ProgramFiles", "LOCALAPPDATA"] {
            if let value = environment[name], !value.isEmpty {
                let root = URL(fileURLWithPath: value)
                roots.append(root.appendingPathComponent("Eclipse Adoptium"))
                roots.append(root.appendingPathComponent("Java"))
                roots.append(root.appendingPathComponent("Programs/Eclipse Adoptium"))
            }
        }
        for root in roots {
            for candidate in FileSystem.children(root) where candidate.lastPathComponent.contains("21") {
                if FileSystem.isExecutable(candidate.appendingPathComponent("bin/\(javaName)")) { return candidate }
            }
        }
        throw ToolingError.toolchainMissing(
            "JDK 21 was not found.",
            suggestion: "Install a JDK 21 and set JAVA_HOME."
        )
    }

    static func swiftToolchain(
        environment: Environment, platform: Platform, runner: CommandRunner
    ) async throws -> URL {
        // The same compiler every other host's build uses: `SWIFT_BIN`, else the one on PATH.
        try SwiftBuilder(runner: runner, environment: environment, platform: platform).swift()
    }

    static func swiftSDK(
        for swift: URL, environment: Environment, platform: Platform, runner: CommandRunner
    ) async throws -> (id: String, bundle: URL) {
        guard let versionText = await runner.output(swift, ["--version"], label: "swift"),
              let release = Version.swiftRelease(in: versionText) else {
            throw ToolingError.toolchainMissing("The Swift toolchain at \(swift.path) did not report its version.")
        }
        guard let list = await runner.output(swift, ["sdk", "list"], label: "swift sdk list") else {
            throw ToolingError.toolchainMissing("`swift sdk list` failed for \(swift.path).")
        }
        let ids = list.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { $0.lowercased().contains("android") }
        let matching = ids.filter { id in
            guard let idVersion = Version.first(in: id) else { return false }
            return Version.sameRelease(Version.swiftRelease(in: idVersion) ?? "", release)
        }
        guard let id = matching.last else {
            throw ToolingError.toolchainMissing(
                "No Swift SDK for Android of Swift \(release) is installed.",
                context: ["swift": swift.path, "release": release],
                suggestion: "Install the matching Swift SDK for Android from swift.org."
            )
        }
        let home = FileSystem.home()
        var roots = [
            home.appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"),
            home.appendingPathComponent(".swiftpm/swift-sdks"),
            home.appendingPathComponent("AppData/Local/org.swift.swiftpm/swift-sdks"),
            home.appendingPathComponent("AppData/Roaming/org.swift.swiftpm/swift-sdks"),
            home.appendingPathComponent("AppData/Local/swiftpm/swift-sdks"),
        ]
        for name in ["LOCALAPPDATA", "APPDATA"] {
            if let value = environment[name], !value.isEmpty {
                roots.append(URL(fileURLWithPath: value).appendingPathComponent("org.swift.swiftpm/swift-sdks"))
                roots.append(URL(fileURLWithPath: value).appendingPathComponent("swiftpm/swift-sdks"))
            }
        }
        var bundle: URL?
        for root in roots {
            for entry in FileSystem.children(root) where entry.pathExtension == "artifactbundle" {
                let info = entry.appendingPathComponent("info.json")
                if let text = try? FileSystem.read(info), text.contains("\"\(id)\"") {
                    bundle = entry
                }
            }
        }
        guard let bundle else {
            throw ToolingError.toolchainMissing(
                "\(id) is listed but its artifact bundle was not found.",
                context: ["sdk": id],
                suggestion: "Reinstall the Swift SDK for Android."
            )
        }

        // The SDK's Swift interface names the compiler build that wrote it.
        let interface = findInterface(in: bundle)
        var sdkBuild: String?
        if let interface, let text = try? FileSystem.read(interface) {
            sdkBuild = Self.compilerBuild(in: text)
        }
        let compilerBuild = Self.compilerBuild(in: versionText)
        if let sdkBuild, let compilerBuild,
           !Version.sameRelease(
               Version.swiftRelease(in: sdkBuild) ?? sdkBuild,
               Version.swiftRelease(in: compilerBuild) ?? compilerBuild
           ) {
            throw ToolingError.toolchainMissing(
                "\(swift.path) (\(compilerBuild)) cannot read \(id), written by \(sdkBuild).",
                context: ["swift": swift.path, "sdk": id, "sdkBuild": sdkBuild],
                suggestion: "Install the swift.org toolchain of the SDK's release, or set SWIFT_BIN."
            )
        }
        return (id, bundle)
    }

    static func compilerBuild(in text: String) -> String? {
        guard let range = text.range(of: #"\(swift[a-z]*-[^) ]+"#, options: .regularExpression) else { return nil }
        return String(text[range]).replacingOccurrences(of: "(", with: "")
    }

    static func findInterface(in bundle: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: bundle, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "Swift.swiftinterface" {
            return url
        }
        return nil
    }

    static func gradleBinary(
        environment: Environment, platform: Platform, runner: CommandRunner
    ) -> URL? {
        let names = platform.operatingSystem == .windows ? ["gradle.bat", "gradle"] : ["gradle"]
        let dists = FileSystem.home().appendingPathComponent(".gradle/wrapper/dists")
        for entry in FileSystem.children(dists) where entry.lastPathComponent == "gradle-\(gradleVersion)-bin" {
            for inner in FileSystem.children(entry) {
                for name in names {
                    let candidate = inner.appendingPathComponent("gradle-\(gradleVersion)/bin/\(name)")
                    if isGradleLauncher(candidate) { return candidate }
                }
            }
        }
        if let found = runner.which("gradle") { return found }
        if platform.operatingSystem == .windows {
            for name in ["gradle.bat", "gradle.cmd"] {
                if let found = FileSystem.findExecutable(name, environment: environment) { return found }
            }
        }
        return nil
    }

    private static func isGradleLauncher(_ url: URL) -> Bool {
        if FileSystem.isExecutable(url) { return true }
        let suffix = url.pathExtension.lowercased()
        return (suffix == "bat" || suffix == "cmd") && FileSystem.exists(url)
    }

    /// Where `installGradle` puts Gradle, whether or not it is there yet: a plan
    /// names it without downloading anything.
    static func expectedGradleBinary(platform: Platform) -> URL {
        let name = platform.operatingSystem == .windows ? "gradle.bat" : "gradle"
        return FileSystem.home()
            .appendingPathComponent(
                ".gradle/wrapper/dists/gradle-\(gradleVersion)-bin/stateui/gradle-\(gradleVersion)/bin/\(name)"
            )
    }

    /// Gradle, downloading the release the heads build with when no cache or
    /// `PATH` has it - the same download `.scripts/Android/tools.sh` makes.
    static func installGradle(
        environment: Environment, platform: Platform, runner: CommandRunner
    ) async throws -> URL {
        if let found = gradleBinary(environment: environment, platform: platform, runner: runner) { return found }
        guard let curl = runner.which("curl") else {
            throw ToolingError.toolchainMissing(
                "curl was not found, and Gradle \(gradleVersion) is not cached.",
                suggestion: "Install curl, or Gradle \(gradleVersion)."
            )
        }
        let unpacker: URL
        let unpackArguments: [String]
        let usesUnzip: Bool
        if let unzip = runner.which("unzip") {
            unpacker = unzip
            unpackArguments = ["-q", "-o"]
            usesUnzip = true
        } else if let tar = runner.which("tar") {
            unpacker = tar
            unpackArguments = ["-xf"]
            usesUnzip = false
        } else {
            throw ToolingError.toolchainMissing(
                "unzip was not found, and Gradle \(gradleVersion) is not cached.",
                suggestion: "Install unzip or tar, or Gradle \(gradleVersion)."
            )
        }
        let directory = FileSystem.home()
            .appendingPathComponent(".gradle/wrapper/dists/gradle-\(gradleVersion)-bin/stateui", isDirectory: true)
        try FileSystem.makeDirectory(directory)
        let archive = directory.appendingPathComponent("gradle.zip")
        let url = "https://services.gradle.org/distributions/gradle-\(gradleVersion)-bin.zip"
        guard let download = await runner.result(
            curl, ["-fsSL", url, "-o", archive.path], label: "download Gradle \(gradleVersion)"
        ), download.exitCode == 0 else {
            try? FileSystem.remove(archive)
            throw ToolingError.commandFailed(
                "Gradle \(gradleVersion) could not be downloaded from \(url).",
                suggestion: "Check the network, or install Gradle \(gradleVersion) yourself."
            )
        }
        let arguments = usesUnzip
            ? unpackArguments + [archive.path, "-d", directory.path]
            : unpackArguments + [archive.path, "-C", directory.path]
        guard let unpacked = await runner.result(
            unpacker, arguments, label: "unpack Gradle \(gradleVersion)"
        ), unpacked.exitCode == 0 else {
            try? FileSystem.remove(archive)
            throw ToolingError.commandFailed(
                "Gradle \(gradleVersion) could not be unpacked.",
                suggestion: "Check that the archive at \(archive.path) can be read."
            )
        }
        try? FileSystem.remove(archive)
        guard let found = gradleBinary(environment: environment, platform: platform, runner: runner) else {
            throw ToolingError.toolchainMissing(
                "Gradle \(gradleVersion) was unpacked but its binary was not found.",
                context: ["directory": directory.path]
            )
        }
        return found
    }

    public func ndkTool(_ name: String) -> URL? {
        guard let bin = FileSystem.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .map({ $0.appendingPathComponent("bin") })
            .first(where: FileSystem.isDirectory) else { return nil }
        let suffixed = bin.appendingPathComponent(name + Platform.current.executableSuffix)
        if FileSystem.isExecutable(suffixed) { return suffixed }
        let bare = bin.appendingPathComponent(name)
        return FileSystem.isExecutable(bare) ? bare : nil
    }

    public func lldbServer(for abi: String) -> URL? {
        let architecture: String
        switch abi {
        case "arm64-v8a": architecture = "aarch64"
        case "armeabi-v7a": architecture = "arm"
        case "x86": architecture = "i386"
        default: architecture = abi
        }
        let prebuilt = FileSystem.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .first(where: FileSystem.isDirectory)
        guard let prebuilt else { return nil }
        let clang = prebuilt.appendingPathComponent("lib/clang")
        return FileSystem.children(clang)
            .flatMap { FileSystem.children($0.appendingPathComponent("lib/linux/\(architecture)")) }
            .first { $0.lastPathComponent == "lldb-server" }
    }
}
