// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The native libraries an Android head's Swift product needs, worked out from
/// the ELF `DT_NEEDED` closure the way the Android scripts do it.
public struct AndroidPackaging: Sendable {
    public struct Library: Sendable, Hashable {
        public let name: String
        public let source: URL

        public init(name: String, source: URL) {
            self.name = name
            self.source = source
        }
    }

    public let runner: CommandRunner
    public let toolchain: AndroidToolchain
    public let abi: String
    public let api: Int

    public init(runner: CommandRunner, toolchain: AndroidToolchain, abi: String, api: Int = AndroidToolchain.apiLevel) {
        self.runner = runner
        self.toolchain = toolchain
        self.abi = abi
        self.api = api
    }

    public var architecture: String {
        switch abi {
        case "arm64-v8a": return "aarch64"
        case "x86_64": return "x86_64"
        case "armeabi-v7a": return "arm"
        case "x86": return "i386"
        default: return abi
        }
    }

    public var ndkArchitecture: String { "\(architecture)-linux-android" }

    /// The product and every library it needs, excluding libraries the Android
    /// platform provides at this API level.
    public func closure(product: String, bin: URL) async -> [Library] {
        let first = "lib\(product).so"
        var queue = [first]
        var seen = Set<String>()
        var packaged: [Library] = []
        let platform = platformLibraryDirectory()
        let runtime = runtimeDirectory()

        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard seen.insert(name).inserted else { continue }
            if let platform, FileSystem.exists(platform.appendingPathComponent(name)) { continue }
            guard let source = source(for: name, bin: bin, runtime: runtime) else { continue }
            packaged.append(Library(name: name, source: source))
            for needed in await neededLibraries(of: source) where needed != name {
                queue.append(needed)
            }
        }

        // A build whose ELF tools are absent still packages what it can see.
        if packaged.isEmpty {
            let candidates = FileSystem.children(bin)
                .filter { $0.lastPathComponent.hasSuffix(".so") }
            let runtimeLibraries = runtime.map { directory in
                FileSystem.children(directory).filter { $0.lastPathComponent.hasPrefix("libswift") }
            } ?? []
            for source in candidates + runtimeLibraries {
                if let platform, FileSystem.exists(platform.appendingPathComponent(source.lastPathComponent)) { continue }
                packaged.append(Library(name: source.lastPathComponent, source: source))
            }
            if let libcxx = libcxxShared(), !packaged.contains(where: { $0.name == libcxx.lastPathComponent }) {
                packaged.append(Library(name: libcxx.lastPathComponent, source: libcxx))
            }
        }
        return packaged
    }

    private func neededLibraries(of source: URL) async -> [String] {
        guard let readelf = toolchain.ndkTool("llvm-readelf"),
              let output = await runner.output(readelf, ["--needed-libs", source.path], label: "llvm-readelf") else {
            return []
        }
        return output.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.hasPrefix("lib") && $0.hasSuffix(".so") }
    }

    private func source(for name: String, bin: URL, runtime: URL?) -> URL? {
        let candidates = [bin, runtime].compactMap { $0 }.map { $0.appendingPathComponent(name) }
        if let found = candidates.first(where: FileSystem.exists) { return found }
        if name == "libc++_shared.so" { return libcxxShared() }
        return nil
    }

    private func runtimeDirectory() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: toolchain.swiftSDKBundle, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "libswiftCore.so" {
            if url.path.contains("/\(architecture)") { return url.deletingLastPathComponent() }
        }
        return nil
    }

    private func platformLibraryDirectory() -> URL? {
        let prebuilt = FileSystem.children(toolchain.ndk.appendingPathComponent("toolchains/llvm/prebuilt"))
            .first(where: FileSystem.isDirectory)
        guard let prebuilt else { return nil }
        let candidate = prebuilt.appendingPathComponent(
            "sysroot/usr/lib/\(ndkArchitecture)/\(api)", isDirectory: true
        )
        return FileSystem.isDirectory(candidate) ? candidate : nil
    }

    private func libcxxShared() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: toolchain.ndk, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "libc++_shared.so" {
            if url.path.contains(ndkArchitecture) { return url }
        }
        return nil
    }
}
