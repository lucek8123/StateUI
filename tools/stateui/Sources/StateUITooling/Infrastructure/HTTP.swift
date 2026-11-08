// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A small static file server for a Web head's page. It is native Swift so a
/// Web run needs no Python or shell orchestration.
public struct StaticWebServer: Sendable {
    public let root: URL
    public let port: Int
    public let factsFile: URL?
    public let browser: Browser?
    public let query: String
    public let environment: Environment
    public let platform: Platform

    public init(
        root: URL, port: Int, factsFile: URL? = nil, browser: Browser? = nil,
        query: String = "", environment: Environment = .current, platform: Platform = .current
    ) {
        self.root = root
        self.port = port
        self.factsFile = factsFile
        self.browser = browser
        self.query = query
        self.environment = environment
        self.platform = platform
    }

    public func run() throws {
        #if os(Windows)
        throw ToolingError.unsupportedHost("The Web host's server runs on macOS and Linux.")
        #else
        signal(SIGPIPE, SIG_IGN)
        #if canImport(Glibc)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, socketType, 0)
        guard descriptor >= 0 else {
            throw ToolingError(code: "serverFailed", message: "A socket could not be opened.")
        }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw ToolingError(
                code: "serverFailed",
                message: "The page's server could not bind port \(port).",
                suggestion: "Pick another port with --port."
            )
        }
        guard listen(descriptor, 64) == 0 else {
            close(descriptor)
            throw ToolingError(code: "serverFailed", message: "The page's server could not listen on port \(port).")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        let actualPort = Int(UInt16(bigEndian: actual.sin_port))
        let url = "http://localhost:\(actualPort)/"
        try writeFacts(port: actualPort, url: url)

        if let browser, browser.id != "none" {
            try? browser.open(url: url + (query.isEmpty ? "" : "?\(query)"), environment: environment, platform: platform)
        }

        let rootPath = root.standardizedFileURL.path
        while true {
            var clientAddress = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(descriptor, $0, &clientLength)
                }
            }
            guard client >= 0 else { continue }
            DispatchQueue.global().async {
                serve(client: client, rootPath: rootPath)
            }
        }
        #endif
    }

    private func writeFacts(port: Int, url: String) throws {
        guard let factsFile else { return }
        // The process is named so a later `stateui stop` can give the page up: the run
        // that served it has already answered, so the port would otherwise be stranded.
        let facts: [String: Any] = [
            "url": url,
            "port": port,
            "root": root.path,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "addresses": [url],
        ]
        let data = try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
        try FileSystem.write(data, to: factsFile)
    }

    #if !os(Windows)
    private func serve(client: Int32, rootPath: String) {
        defer { close(client) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while request.count < 128 * 1024 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            request.append(contentsOf: buffer[0..<count])
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: request, encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first else {
            respond(client, status: "400 Bad Request", body: Data("Bad request\n".utf8), type: "text/plain")
            return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            respond(client, status: "400 Bad Request", body: Data("Bad request\n".utf8), type: "text/plain")
            return
        }
        var path = String(parts[1])
        if let mark = path.firstIndex(of: "?") { path = String(path[..<mark]) }
        if let mark = path.firstIndex(of: "#") { path = String(path[..<mark]) }
        path = path.removingPercentEncoding ?? path
        if path == "/" { path = "/index.html" }

        let candidate = rootPath + path
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard standardized.hasPrefix(rootPath + "/"), FileSystem.exists(URL(fileURLWithPath: standardized)),
              !FileSystem.isDirectory(URL(fileURLWithPath: standardized)) else {
            respond(client, status: "404 Not Found", body: Data("Not found\n".utf8), type: "text/plain")
            return
        }
        guard let body = try? Data(contentsOf: URL(fileURLWithPath: standardized)) else {
            respond(client, status: "500 Internal Server Error", body: Data("Unreadable\n".utf8), type: "text/plain")
            return
        }
        respond(client, status: "200 OK", body: body, type: Self.mimeType(standardized))
    }

    private func respond(_ client: Int32, status: String, body: Data, type: String) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: \(type)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        writeAll(client, Data(header.utf8))
        writeAll(client, body)
    }

    private func writeAll(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(client, pointer, remaining)
                if written <= 0 { return }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }
    #endif

    static func mimeType(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
