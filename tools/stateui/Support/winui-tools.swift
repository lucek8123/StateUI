// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0
//
// What every WinUI step shares, as the repository's WinUI tools did: the
// packages fetched where they are missing - each SHA-512 checked against
// nuget.org's catalog before a byte of it is unpacked - the C++/WinRT
// projection the relay includes, generated again when the versions change, and
// a directory made self-contained: the Windows App SDK beside the executables,
// what each backend linked there lays itself, the C++ runtime Visual Studio's
// redistributable holds, every class the components declare registered in a
// manifest beside each executable, and resources.pri. No MSBuild.
//
// The Swift runtime is laid nowhere by this tool: Windows keeps it in the
// installer's merge modules, which only msi.dll can read. A head runs with the
// runtime of the toolchain that built it, and a deployed folder needs that
// toolchain on the search path - see docs/design/platforms/winui/runtime.md.
//
// The versions live in the tooling and nowhere else: each subcommand is given
// them as --package <id>=<version>, in the order the runtime is laid in.
//
// USAGE:
//   winui-tools fetch          --nuget <root> --package <id>=<version> ...
//   winui-tools projection     --projection <dir> --nuget <root> --package ...
//   winui-tools manifest       --executable <exe> ... --nuget <root> --package ...
//   winui-tools self-contained --directory <bin> --executable <exe> ... \
//                              --architecture <x64|arm64> --repository <root> \
//                              --nuget <root> --package ...
//   winui-tools cpp-runtime    --directory <dir> --architecture <x64|arm64>
//
// Design: docs/design/platforms/winui/runtime.md#self-contained
//
// An executable is never rewritten after its build: the next build would link
// it again, however little changed. The manifest therefore stands beside it, as
// `<executable>.manifest`, which Windows reads for an executable carrying none
// of its own.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The packages, by the ids the tooling pins them under.
let cppwinrtID = "microsoft.windows.cppwinrt"
let winuiID = "microsoft.windowsappsdk.winui"
let foundationID = "microsoft.windowsappsdk.foundation"
let experiencesID = "microsoft.windowsappsdk.interactiveexperiences"
let webviewID = "microsoft.web.webview2"

// The components whose runtime is laid beside a head, in the order it is laid in.
let componentIDs: Set<String> = [winuiID, foundationID, experiencesID]

// The two proxy stubs a self-contained application has no singleton for.
let skippedProxyStubs: Set<String> = [
    "PushNotificationsLongRunningTask.ProxyStub.dll", "Microsoft.Windows.Widgets.dll",
]

// WinUI's header for drawing with DirectX into its elements, which the projection carries beside it.
let directXInteropHeader = "microsoft.ui.xaml.media.dxinterop.h"

// The application's own settings: per-monitor DPI, and Windows 10 and newer.
let settingsTail = """
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAwareness xmlns='http://schemas.microsoft.com/SMI/2016/WindowsSettings'>PerMonitorV2</dpiAwareness>
    </asmv3:windowsSettings>
  </asmv3:application>
  <compatibility xmlns='urn:schemas-microsoft-com:compatibility.v1'>
    <application>
      <supportedOS Id='{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}'/>
    </application>
  </compatibility>
"""

// The architecture this tool was compiled for, which is the machine's own: the
// toolchain builds for it, so it is the architecture a head is laid for unless
// another one was asked for.
#if arch(arm64)
let machineArchitecture = "arm64"
#else
let machineArchitecture = "x64"
#endif

let files = FileManager.default

// MARK: - Failing and arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("winui-tools: \(message)\n".utf8))
    exit(1)
}

func usage() -> Never {
    fail("""
    USAGE: winui-tools <fetch|projection|manifest|self-contained|cpp-runtime> \
    [--nuget <root>] [--package <id>=<version> ...] [--projection <dir>] [--directory <dir>] \
    [--executable <exe> ...] [--architecture <x64|arm64>] [--repository <root>]
    """)
}

/// The arguments as flags: each `--flag value`, and `--package` and
/// `--executable` repeated.
func flags(_ arguments: [String]) -> [String: [String]] {
    var read: [String: [String]] = [:]
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        guard argument.hasPrefix("--") else { index += 1; continue }
        guard index + 1 < arguments.count else { usage() }
        read[String(argument.dropFirst(2)), default: []].append(arguments[index + 1])
        index += 2
    }
    return read
}

func required(_ read: [String: [String]], _ name: String, isDirectory: Bool = true) -> URL {
    guard let value = read[name]?.first else {
        fail("--\(name) names no path.")
    }
    return URL(fileURLWithPath: value, isDirectory: isDirectory)
}

func many(_ read: [String: [String]], _ name: String, isDirectory: Bool = false) -> [URL] {
    guard let values = read[name], !values.isEmpty else {
        fail("--\(name) names nothing.")
    }
    return values.map { URL(fileURLWithPath: $0, isDirectory: isDirectory) }
}

func packages(_ read: [String: [String]]) -> [(id: String, version: String)] {
    guard let pairs = read["package"], !pairs.isEmpty else {
        fail("no --package <id>=<version> was given.")
    }
    return pairs.map { pair in
        guard let separator = pair.firstIndex(of: "=") else {
            fail("--package \(pair) is not <id>=<version>.")
        }
        return (String(pair[..<separator]), String(pair[pair.index(after: separator)...]))
    }
}

func value(_ read: [String: [String]], _ name: String, _ fallback: String) -> String {
    read[name]?.first ?? fallback
}

// MARK: - Files

func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }

func isDirectory(_ url: URL) -> Bool {
    var directory: ObjCBool = false
    return files.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
}

func write(_ text: String, to url: URL) throws {
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// Every file of a tree laid under a directory, each newer than the one that
/// stood there: what robocopy `/E /XO` did.
func copyTree(from source: URL, to destination: URL) throws {
    try files.createDirectory(at: destination, withIntermediateDirectories: true)
    for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        let target = destination.appendingPathComponent(child.lastPathComponent)
        if isDirectory(child) {
            try copyTree(from: child, to: target)
        } else {
            if exists(target) { try files.removeItem(at: target) }
            try files.copyItem(at: child, to: target)
        }
    }
}

// MARK: - The machine's tools

/// A native tool run to completion; it is judged by its exit code, as every
/// step of WinUI's tools was.
func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// A native tool run to completion, and what it printed.
func capture(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> String {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged
    }
    process.standardOutput = pipe
    try process.run()
    let printed = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(executable) exited \(process.terminationStatus).") }
    return String(data: printed, encoding: .utf8) ?? ""
}

/// A tool of the machine's, found on the search path - Windows separates it
/// with `;`, every other system with `:`.
func found(_ names: [String]) -> String? {
    #if os(Windows)
    let names = names.flatMap { [$0, "\($0).exe"] }
    #endif
    let environment = ProcessInfo.processInfo.environment
    #if os(Windows)
    let path = environment["Path"] ?? environment["PATH"] ?? ""
    #else
    let path = environment["PATH"] ?? ""
    #endif
    for directory in path.split(whereSeparator: { $0 == ":" || $0 == ";" }) {
        for name in names {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if files.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
    }
    return nil
}

func powerShell() -> String? { found(["pwsh", "powershell"]) }

// MARK: - The packages

func packageDirectory(_ id: String, version: String, root: URL) -> URL {
    root.appendingPathComponent("\(id)/\(version)", isDirectory: true)
}

/// One package's folder, fetched from nuget.org first where it is missing - its
/// SHA-512 checked against the catalog's before a byte of it is unpacked.
func ensurePackage(_ id: String, version: String, root: URL) throws -> URL {
    let folder = packageDirectory(id, version: version, root: root)
    if exists(folder.appendingPathComponent("\(id).nuspec")) { return folder }

    let nupkg = files.temporaryDirectory.appendingPathComponent("\(id).\(version).nupkg")
    defer { try? files.removeItem(at: nupkg) }
    print("fetching \(id) \(version)")
    let fetched = try fetch(
        URL(string: "https://api.nuget.org/v3-flatcontainer/\(id)/\(version)/\(id).\(version).nupkg")!
    )
    try fetched.write(to: nupkg)

    let registration = try json(try fetch(
        URL(string: "https://api.nuget.org/v3/registration5-semver1/\(id)/\(version).json")!
    ))
    guard let entry = registration["catalogEntry"] as? String, let catalogURL = URL(string: entry) else {
        fail("\(id) \(version): nuget.org's registration names no catalog entry.")
    }
    let catalog = try json(try fetch(catalogURL))
    guard let expected = catalog["packageHash"] as? String else {
        fail("\(id) \(version): nuget.org's catalog entry holds no packageHash.")
    }
    if try sha512Base64(of: nupkg) != expected { fail("\(id) \(version) does not match nuget.org's catalog.") }

    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    try unpack(zip: nupkg, into: folder)
    return folder
}

/// A box a completion handler fills once, so a plain main waits for a request.
final class Once: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private var stored: Result<Data, Error>?

    func fill(_ result: Result<Data, Error>) {
        stored = result
        gate.signal()
    }

    func wait() throws -> Data {
        gate.wait()
        return try stored!.get()
    }
}

func fetch(_ url: URL) throws -> Data {
    let once = Once()
    let task = URLSession.shared.dataTask(with: url) { data, _, error in
        if let data { once.fill(.success(data)) } else { once.fill(.failure(error ?? URLError(.unknown))) }
    }
    task.resume()
    return try once.wait()
}

func json(_ data: Data) throws -> [String: Any] {
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    guard let object else { fail("nuget.org answered with something that is not a JSON object.") }
    return object
}

/// A file's SHA-512 as nuget's catalog gives it: base64 of the digest, whose
/// hex is read from the machine's own hashing tool - PowerShell's on Windows,
/// `sha512sum` or `shasum` where they stand.
func sha512Base64(of file: URL) throws -> String {
    let printed: String
    if let shell = powerShell() {
        #if os(Windows)
        // Windows PowerShell may otherwise pick up PowerShell 7's incompatible
        // utility module, where `Get-FileHash` is not loaded.
        let environment = shell.lowercased().contains("windowspowershell")
            ? ["PSModulePath": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules"]
            : nil
        #else
        let environment: [String: String]? = nil
        #endif
        printed = try capture(
            shell, ["-NonInteractive", "-NoProfile", "-Command",
                    "Write-Output ((Get-FileHash -Algorithm SHA512 -LiteralPath '\(singleQuoted(file.path))').Hash)"],
            environment: environment
        )
    } else if let digest = found(["sha512sum", "sha512"]) {
        printed = try capture(digest, [file.path])
    } else if let digest = found(["shasum"]) {
        printed = try capture(digest, ["-a", "512", file.path])
    } else {
        fail("no SHA-512 tool was found, so a package could not be checked against the catalog.")
    }

    // Only the hex of the digest is kept: whatever a tool prints around it is not part of it.
    let digits = printed.uppercased().filter { "0123456789ABCDEF".contains($0) }
    guard digits.count == 128 else {
        fail("the SHA-512 of \(file.path) was read as \(digits.count) hex digits, not 128.")
    }

    var bytes: [UInt8] = []
    var read = digits.startIndex
    while read < digits.endIndex {
        let next = digits.index(read, offsetBy: 2)
        guard let byte = UInt8(digits[read..<next], radix: 16) else {
            fail("the SHA-512 of \(file.path) was read as hex that is not hex.")
        }
        bytes.append(byte)
        read = next
    }
    return Data(bytes).base64EncodedString()
}

/// A path as PowerShell holds it inside single quotes.
func singleQuoted(_ path: String) -> String { path.replacingOccurrences(of: "'", with: "''") }

/// Unpack a `.nupkg`, which is a zip: Windows' own `tar` reads zips, and
/// `unzip` stands where macOS and Linux have it.
func unpack(zip: URL, into directory: URL) throws {
    if let tar = found(["tar"]), try run(tar, ["-xf", zip.path, "-C", directory.path]) == 0 { return }
    if let unzip = found(["unzip"]), try run(unzip, ["-q", "-o", zip.path, "-d", directory.path]) == 0 { return }
    fail("\(zip.lastPathComponent) could not be unpacked: neither tar nor unzip did it.")
}

/// The folder of one of the pinned packages, looked up by its id.
func folder(of id: String, pinned: [(id: String, version: String)], folders: [URL]) -> URL {
    guard let index = pinned.firstIndex(where: { $0.id == id }) else {
        fail("--package names no \(id).")
    }
    return folders[index]
}

// MARK: - The projection

/// The C++/WinRT projection of the Windows SDK, WinUI and the Windows App SDK,
/// into the host's `.projection/`, generated again when the versions change -
/// beside it, WinUI's header for drawing with DirectX into its elements.
func generateProjection(projection: URL, nuget: URL, pinned: [(id: String, version: String)]) throws {
    let stamp = projection.appendingPathComponent("versions.txt")
    let versions = pinned.map { "\($0.id) \($0.version)" }.joined(separator: "\n")
    if exists(stamp),
       (try String(contentsOf: stamp, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines) == versions,
       exists(projection.appendingPathComponent(directXInteropHeader)) {
        return
    }

    let folders = try pinned.map { try ensurePackage($0.id, version: $0.version, root: nuget) }
    let cppwinrt = folder(of: cppwinrtID, pinned: pinned, folders: folders)
        .appendingPathComponent("bin/cppwinrt.exe")
    guard exists(cppwinrt) else { fail("cppwinrt.exe was not found at \(cppwinrt.path).") }

    print("generating the C++/WinRT projection")
    if isDirectory(projection) { try files.removeItem(at: projection) }

    var options = ["-input", "sdk"]
    // The metadata each package holds, in the order the projection is read in.
    for each in pinned where each.id != cppwinrtID {
        let directory = folder(of: each.id, pinned: pinned, folders: folders)
        switch each.id {
        case experiencesID:
            options.append(contentsOf: ["-input", directory.appendingPathComponent("metadata/10.0.18362.0").path])
        case webviewID:
            options.append(contentsOf: ["-input", directory.appendingPathComponent("lib/Microsoft.Web.WebView2.Core.winmd").path])
        default:
            options.append(contentsOf: ["-input", directory.appendingPathComponent("metadata").path])
        }
    }
    options.append(contentsOf: ["-output", projection.path])
    guard try run(cppwinrt.path, options) == 0 else { fail("cppwinrt could not generate the projection.") }

    try files.copyItem(
        at: folder(of: winuiID, pinned: pinned, folders: folders)
            .appendingPathComponent("include/\(directXInteropHeader)"),
        to: projection.appendingPathComponent(directXInteropHeader)
    )
    try write(versions, to: stamp)
}

// MARK: - The manifest

/// One component's `package.appxfragment`: every class it declares, in the
/// file that holds it.
struct Fragment {
    struct Server { var path: String; var classes: [String] }
    struct Stub { var path: String; var clsid: String; var interfaces: [(name: String, iid: String)] }

    var servers: [Server] = []
    var stubs: [Stub] = []
}

/// Reads a fragment's extensions: every in-process server and every proxy
/// stub, with the classes and interfaces each names.
final class FragmentReader: NSObject, XMLParserDelegate {
    private var server: Fragment.Server?
    private var stub: Fragment.Stub?
    private var path = ""
    private var collectingPath = false
    private(set) var read = Fragment()

    /// The name without its prefix: a fragment names everything under `m:`.
    private func local(_ elementName: String, _ qualifiedName: String?) -> String {
        let name = qualifiedName ?? elementName
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch local(elementName, qName) {
        case "InProcessServer":
            server = Fragment.Server(path: attributeDict["Path"] ?? "", classes: [])
        case "ProxyStub":
            stub = Fragment.Stub(
                path: attributeDict["Path"] ?? "", clsid: attributeDict["ClassId"] ?? "", interfaces: []
            )
        case "Path":
            // The fragments name the file in a child element, not an attribute.
            collectingPath = true
            path = ""
        case "ActivatableClass":
            if var held = server {
                held.classes.append(attributeDict["ActivatableClassId"] ?? "")
                server = held
            }
        case "Interface":
            if var held = stub {
                held.interfaces.append((attributeDict["Name"] ?? "", attributeDict["InterfaceId"] ?? ""))
                stub = held
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingPath { path += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch local(elementName, qName) {
        case "Path":
            let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if var held = server { held.path = value; server = held }
            if var held = stub { held.path = value; stub = held }
            collectingPath = false
            path = ""
        case "InProcessServer":
            if let held = server, !held.path.isEmpty { read.servers.append(held) }
            server = nil
        case "ProxyStub":
            if let held = stub, !skippedProxyStubs.contains(held.path) { read.stubs.append(held) }
            stub = nil
        default: break
        }
    }
}

func escaped(_ value: String) -> String {
    var out = value
    for (each, with) in [("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;")] {
        out = out.replacingOccurrences(of: each, with: with)
    }
    return out
}

/// A class id, as a manifest names it: between braces, where a fragment names
/// it without them.
func guided(_ identifier: String) -> String {
    identifier.hasPrefix("{") ? identifier : "{\(identifier)}"
}

/// The manifest a self-contained application carries: every class each
/// component's fragment declares, in the file that holds it, and the
/// application's own settings.
func manifestText(_ fragments: [Fragment]) -> String {
    var lines = [
        "<?xml version='1.0' encoding='utf-8' standalone='yes'?>",
        "<assembly manifestVersion='1.0' xmlns='urn:schemas-microsoft-com:asm.v1' "
            + "xmlns:asmv3='urn:schemas-microsoft-com:asm.v3' xmlns:winrtv1='urn:schemas-microsoft-com:winrt.v1'>",
    ]
    for fragment in fragments {
        for server in fragment.servers {
            lines.append("  <asmv3:file name='\(escaped(server.path))'>")
            for each in server.classes {
                lines.append("    <winrtv1:activatableClass name='\(escaped(each))' threadingModel='both'/>")
            }
            lines.append("  </asmv3:file>")
        }
        for stub in fragment.stubs {
            lines.append("  <asmv3:file name='\(escaped(stub.path))'>")
            lines.append("    <asmv3:comClass clsid='\(escaped(guided(stub.clsid)))'/>")
            for interface in stub.interfaces {
                lines.append(
                    "    <asmv3:comInterfaceProxyStub name='\(escaped(interface.name))' "
                        + "iid='\(escaped(guided(interface.iid)))'/>"
                )
            }
            lines.append("  </asmv3:file>")
        }
    }
    lines.append(contentsOf: settingsTail.split(separator: "\n").map(String.init))
    lines.append("</assembly>")
    // Windows reads an assembly manifest as CRLF lines, as PowerShell's AppendLine wrote them.
    return lines.joined(separator: "\r\n") + "\r\n"
}

func readFragment(_ component: URL) throws -> Fragment {
    let fragment = component.appendingPathComponent("runtimes-framework/package.appxfragment")
    guard exists(fragment) else { fail("\(component.path) holds no package.appxfragment.") }
    let reader = FragmentReader()
    let parser = XMLParser(data: try Data(contentsOf: fragment))
    parser.delegate = reader
    guard parser.parse() else { fail("\(fragment.path) is not readable XML.") }
    return reader.read
}

/// Every fragment of the components whose runtime is laid beside a head, in the
/// order their runtimes are laid in.
func readFragments(pinned: [(id: String, version: String)], folders: [URL]) throws -> [Fragment] {
    var fragments: [Fragment] = []
    for (each, folder) in zip(pinned, folders) where componentIDs.contains(each.id) {
        fragments.append(try readFragment(folder))
    }
    return fragments
}

func writeManifest(beside executable: URL, nuget: URL, pinned: [(id: String, version: String)]) throws {
    let folders = pinned.filter { componentIDs.contains($0.id) }
        .map { packageDirectory($0.id, version: $0.version, root: nuget) }
    let fragments = try folders.map { try readFragment($0) }
    try write(manifestText(fragments), to: URL(fileURLWithPath: "\(executable.path).manifest"))
}

// MARK: - The runtime laid beside an executable

/// The C++ runtime for an architecture, laid in a directory - Visual Studio's
/// app-local redistributable - which the Swift runtime links.
func layCppRuntime(directory: URL, architecture: String) throws {
    let installer = ProcessInfo.processInfo.environment["ProgramFiles(x86)"] ?? "C:/Program Files (x86)"
    let vswhere = URL(fileURLWithPath: installer)
        .appendingPathComponent("Microsoft Visual Studio/Installer/vswhere.exe")
    guard exists(vswhere) else {
        fail("vswhere.exe was not found at \(vswhere.path), so the C++ runtime could not be laid.")
    }

    let studio = try capture(vswhere.path, ["-latest", "-products", "*", "-property", "installationPath"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !studio.isEmpty else { fail("vswhere named no Visual Studio installation.") }

    let pattern = try NSRegularExpression(pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    func names(_ directory: URL, matching: (String) -> Bool) throws -> [URL] {
        try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { isDirectory($0) && matching($0.lastPathComponent) }
    }

    let releases = try names(
        URL(fileURLWithPath: studio).appendingPathComponent("VC/Redist/MSVC", isDirectory: true)
    ) { pattern.matches(in: $0, range: NSRange(location: 0, length: $0.count)).first != nil }
    guard let release = releases.max(by: {
        $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
    }) else {
        fail("no C++ redistributable stands under \(URL(fileURLWithPath: studio).appendingPathComponent("VC/Redist/MSVC").path).")
    }

    let runtime = release.appendingPathComponent(architecture, isDirectory: true)
    let runtimes = try names(runtime) { $0.hasPrefix("Microsoft.VC") && $0.hasSuffix(".CRT") }
    guard let crt = runtimes.first else {
        fail("no C++ runtime for \(architecture) in \(release.path)")
    }

    for dll in try files.contentsOfDirectory(at: crt, includingPropertiesForKeys: nil)
    where dll.lastPathComponent.hasSuffix(".dll") {
        let target = directory.appendingPathComponent(dll.lastPathComponent)
        if exists(target) { try files.removeItem(at: target) }
        try files.copyItem(at: dll, to: target)
    }
}

/// A PowerShell script of the repository's, run with the tool's own arguments.
func runPowerShell(script: String, arguments: [String]) throws {
    guard let shell = powerShell() else {
        fail("\(script) lays what WinUI needs, but no PowerShell was found to run it.")
    }
    guard try run(shell, ["-NonInteractive", "-NoProfile", "-File", script] + arguments) == 0 else {
        fail("\(script) exited nonzero.")
    }
}

/// Makes a directory self-contained for each executable built for an
/// architecture: the Windows App SDK's runtime beside them, what each backend
/// linked there needs - each backend lays itself -, the manifest registering
/// every class the components declare beside each executable, and resources.pri.
/// The Swift runtime is laid nowhere here: Windows keeps it in the installer's
/// merge modules, which only msi.dll reads.
func laySelfContained(
    directory: URL, executables: [URL], architecture: String, repository: URL, nuget: URL,
    pinned: [(id: String, version: String)]
) throws {
    let folders = try pinned.map { try ensurePackage($0.id, version: $0.version, root: nuget) }
    // The folders this tool fetched, each named by its id: a backend takes the
    // one its engine lives in, so no version is repeated outside the tooling.
    let fetched = zip(pinned, folders).map { "\($0.0.id)=\($0.1.path)" }.joined(separator: ";")

    // Only the components whose runtime a head runs with are laid beside it; a
    // package fetched for a backend's engine stays in the cache.
    for (pinned, folder) in zip(pinned, folders) where componentIDs.contains(pinned.id) {
        try copyTree(
            from: folder.appendingPathComponent("runtimes-framework/win-\(architecture)/native", isDirectory: true),
            to: directory
        )
    }

    // What a backend's engine needs beside an application linking it, each backend lays itself.
    let backends = repository.appendingPathComponent("lib/Backends", isDirectory: true)
    if isDirectory(backends) {
        for backend in try files.contentsOfDirectory(at: backends, includingPropertiesForKeys: nil)
        where isDirectory(backend) && backend.lastPathComponent.hasSuffix(".WinUI") {
            let lays = backend.appendingPathComponent("SelfContained.ps1")
            guard exists(lays) else { continue }
            try runPowerShell(
                script: lays.path,
                arguments: ["-Directory", directory.path, "-Architecture", architecture, "-Packages", fetched]
            )
        }
    }

    let fragments = try readFragments(pinned: pinned, folders: folders)
    let manifest = manifestText(fragments)
    for executable in executables {
        // An executable is never rewritten after its build, so the manifest stands beside it.
        try write(manifest, to: URL(fileURLWithPath: "\(executable.path).manifest"))
    }

    // WinUI's controls find their resources in the application's index.
    let pri = directory.appendingPathComponent("Microsoft.UI.Xaml.Controls.pri")
    if exists(pri) {
        let index = directory.appendingPathComponent("resources.pri")
        if exists(index) { try files.removeItem(at: index) }
        try files.copyItem(at: pri, to: index)
    }
}

// MARK: - The subcommands

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else { usage() }
let read = flags(Array(arguments.dropFirst()))

switch subcommand {
case "fetch":
    for pinned in packages(read) {
        _ = try ensurePackage(pinned.id, version: pinned.version, root: required(read, "nuget"))
    }

case "projection":
    try generateProjection(
        projection: required(read, "projection"), nuget: required(read, "nuget"), pinned: packages(read)
    )

case "manifest":
    for executable in many(read, "executable") {
        try writeManifest(beside: executable, nuget: required(read, "nuget"), pinned: packages(read))
    }

case "self-contained":
    try laySelfContained(
        directory: required(read, "directory"), executables: many(read, "executable"),
        architecture: value(read, "architecture", machineArchitecture),
        repository: required(read, "repository"), nuget: required(read, "nuget"),
        pinned: packages(read)
    )

case "cpp-runtime":
    try layCppRuntime(
        directory: required(read, "directory"), architecture: value(read, "architecture", machineArchitecture)
    )

default:
    usage()
}
