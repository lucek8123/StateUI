// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RPCID: Codable, Sendable, Hashable, CustomStringConvertible {
    case int(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .int(let value): return "\(value)"
        case .string(let value): return value
        }
    }
}

public struct RPCRequest: Decodable, Sendable {
    public let jsonrpc: String
    public let id: RPCID?
    public let method: String
    public let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc) ?? "2.0"
        self.id = try container.decodeIfPresent(RPCID.self, forKey: .id)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }

    public var isNotification: Bool { id == nil }
}

public struct RPCErrorObject: Codable, Sendable, Hashable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = RPCErrorObject(code: -32700, message: "Parse error")
    public static let invalidRequest = RPCErrorObject(code: -32600, message: "Invalid request")
    public static let methodNotFound = RPCErrorObject(code: -32601, message: "Method not found")
    public static let invalidParams = RPCErrorObject(code: -32602, message: "Invalid params")
    public static let internalError = RPCErrorObject(code: -32603, message: "Internal error")
    public static let cancelled = RPCErrorObject(code: -32800, message: "Request cancelled")

    public static func tooling(_ error: ToolingError) -> RPCErrorObject {
        RPCErrorObject(
            code: -32000, message: error.message,
            data: try? JSONValue(error)
        )
    }
}

public struct RPCResponse: Encodable, Sendable {
    public let jsonrpc: String
    public let id: RPCID?
    public let result: JSONValue?
    public let error: RPCErrorObject?

    public init(id: RPCID?, result: JSONValue? = nil, error: RPCErrorObject? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = error
    }

    public init(id: RPCID?, error: ToolingError) {
        self.init(id: id, error: RPCErrorObject.tooling(error))
    }
}

public struct RPCNotification: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

/// Content-Length framed JSON-RPC 2.0, as the Language Server Protocol uses it.
public enum RPCFraming {
    public static let headerSeparator = Data("\r\n\r\n".utf8)

    public static func frame(_ body: Data) -> Data {
        var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    public static func headerLength(in buffer: Data) -> Int? {
        buffer.range(of: headerSeparator)?.lowerBound
    }

    public static func contentLength(in header: Data) -> Int? {
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// Reads frames from a stream, buffering partial headers and bodies.
public struct RPCFrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func next(from handle: FileHandle) throws -> Data? {
        while true {
            if let headerEnd = RPCFraming.headerLength(in: buffer) {
                let header = buffer.prefix(headerEnd)
                guard let length = RPCFraming.contentLength(in: header) else {
                    throw ToolingError.protocolError("A frame's Content-Length is missing or malformed.")
                }
                let bodyStart = headerEnd + RPCFraming.headerSeparator.count
                let bodyEnd = bodyStart + length
                if buffer.count >= bodyEnd {
                    let body = buffer.subdata(in: bodyStart..<bodyEnd)
                    buffer.removeSubrange(0..<bodyEnd)
                    return body
                }
            }
            let chunk = try handle.read(upToCount: 1) ?? Data()
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                throw ToolingError.protocolError("The stream ended inside a frame.")
            }
            buffer.append(chunk)
        }
    }
}
