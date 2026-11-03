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
        let swift = try await swiftToolchain(environment: environment, runner: runner)
        let sdkMatch = try await swiftSDK(for: swift, environment: environment, runner: runner)

        let buildTools = sdk.appendingPathComponent("build-tools", isDirectory: true)
        let aapt2 = FileSystem.children(buildTools)
            .sorted { Version.compare($0.lastPathComponent, $1.lastPathComponent) < 0 }
            .reversed()
            .map { $0.appendingPathComponent("aapt2") }
            .first(where: FileSystem.isExecutable)
        guard let aapt2 else {
            throw ToolingError.toolchainMissing(
                "The Android SDK has no build-tools aapt2.",
                context: ["sdk": sdk.path],
                suggestion: "Install Android SDK build tools with the SDK Manager."
            )
        }
        let adb = sdk.appendingPathComponent("platform-tools/adb")
        guard FileSystem.isExecutable(adb) else {
            throw ToolingError.toolchainMissing("adb was not found in \(sdk.path)/platform-tools.")
        }
        let emulator = sdk.appendingPathComponent("emulator/emulator")
        let gradle = gradleBinary(environment: environment, runner: runner)

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
        let candidates = [
            environment["ANDROID_HOME"],
            environment["ANDROID_SDK_ROOT"],
            FileSystem.home().appendingPathComponent("Library/Android/sdk").path,
            FileSystem.home().appendingPathComponent("Android/Sdk").path,
        ].compactMap { $0 }
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
        if platform.operatingSystem == .macOS {
            let javaHome = URL(fileURLWithPath: "/usr/libexec/java_home")
            if let output = await runner.output(javaHome, ["-v", "21"], label: "java_home"),
               !output.contains("Unable"), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let url = URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
                if FileSystem.isExecutable(url.appendingPathComponent("bin/java")) { return url }
            }
        }
        if let named = environment["JAVA_HOME"] {
            let url = FileSystem.expand(named)
            if let output = await runner.output(url.appendingPathComponent("bin/java"), ["-version"], label: "java"),
               output.contains("\"21.") || output.contains("version 21") {
                return url
            }
        }
        let roots = [URL(fileURLWithPath: "/usr/lib/jvm"), URL(fileURLWithPath: "/opt/java")]
        for root in roots {
            for candidate in FileSystem.children(root) where candidate.lastPathComponent.contains("21") {
                if FileSystem.isExecutable(candidate.appendingPathComponent("bin/java")) { return candidate }
            }
        }
        throw ToolingError.toolchainMissing(
            "JDK 21 was not found.",
            suggestion: "Install a JDK 21 and set JAVA_HOME."
        )
    }

    static func swiftToolchain(environment: Environment, runner: CommandRunner) async throws -> URL {
        var candidates: [URL] = []
        if let named = environment["SWIFT_BIN"] { candidates.append(FileSystem.expand(named)) }
        if let found = runner.which("swift") { candidates.append(found) }
        let toolchainRoots = [
            FileSystem.home().appendingPathComponent("Library/Developer/Toolchains"),
            URL(fileURLWithPath: "/Library/Developer/Toolchains"),
        ]
        for root in toolchainRoots {
            for entry in FileSystem.children(root) where entry.pathExtension == "xctoolchain" {
                candidates.append(entry.appendingPathComponent("usr/bin/swift"))
            }
        }
        candidates.append(FileSystem.home().appendingPathComponent(".swiftly/bin/swift"))

        var seen = Set<String>()
        for candidate in candidates where FileSystem.isExecutable(candidate) {
            let resolved = candidate.resolvingSymlinksInPath()
            guard seen.insert(resolved.path).inserted else { continue }
            guard let text = await runner.output(resolved, ["--version"], label: "swift") else { continue }
            if text.contains("(swift-") { return resolved }
        }
        throw ToolingError.toolchainMissing(
            "No swift.org Swift toolchain was found.",
            suggestion: "Install Swift 6.4 from swift.org (Xcode's Swift cannot read the Android SDK's binary modules)."
        )
    }

    static func swiftSDK(
        for swift: URL, environment: Environment, runner: CommandRunner
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
            return Version.swiftRelease(in: idVersion) == release
        }
        guard let id = matching.last else {
            throw ToolingError.toolchainMissing(
                "No Swift SDK for Android of Swift \(release) is installed.",
                context: ["swift": swift.path, "release": release],
                suggestion: "Install the matching Swift SDK for Android from swift.org."
            )
        }
        let roots = [
            FileSystem.home().appendingPathComponent("Library/org.swift.swiftpm/swift-sdks"),
            FileSystem.home().appendingPathComponent(".swiftpm/swift-sdks"),
        ]
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
        if let sdkBuild, let compilerBuild, sdkBuild != compilerBuild {
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

    static func gradleBinary(environment: Environment, runner: CommandRunner) -> URL? {
        let dists = FileSystem.home().appendingPathComponent(".gradle/wrapper/dists")
        for entry in FileSystem.children(dists) where entry.lastPathComponent.hasPrefix("gradle-\(gradleVersion)-bin") {
            for inner in FileSystem.children(entry) {
                let candidate = inner.appendingPathComponent("gradle-\(gradleVersion)/bin/gradle")
                if FileSystem.isExecutable(candidate) { return candidate }
            }
        }
        return runner.which("gradle")
    }

    public func ndkTool(_ name: String) -> URL? {
        guard let bin = FileSystem.children(ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .map({ $0.appendingPathComponent("bin") })
            .first(where: FileSystem.isDirectory) else { return nil }
        let candidate = bin.appendingPathComponent(name)
        return FileSystem.isExecutable(candidate) ? candidate : nil
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
