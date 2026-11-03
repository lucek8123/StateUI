// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A structured failure with a stable code, context and an actionable suggestion.
public struct ToolingError: Error, Codable, Sendable, Hashable, LocalizedError, CustomStringConvertible {
    public let code: String
    public let message: String
    public let context: [String: String]
    public let suggestion: String?

    public init(code: String, message: String, context: [String: String] = [:], suggestion: String? = nil) {
        self.code = code
        self.message = message
        self.context = context
        self.suggestion = suggestion
    }

    public var errorDescription: String? { message }
    public var description: String {
        var text = "\(code): \(message)"
        if !context.isEmpty {
            text += " [" + context.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + "]"
        }
        if let suggestion { text += "\n  \(suggestion)" }
        return text
    }

    public static func projectNotFound(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "projectNotFound", message: message, context: context, suggestion: suggestion)
    }

    public static func applicationNotFound(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "applicationNotFound", message: message, context: context, suggestion: suggestion)
    }

    public static func unsupportedHost(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "unsupportedHost", message: message, context: context, suggestion: suggestion)
    }

    public static func hostUnavailable(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "hostUnavailable", message: message, context: context, suggestion: suggestion)
    }

    public static func toolchainMissing(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "toolchainMissing", message: message, context: context, suggestion: suggestion)
    }

    public static func invalidConfiguration(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "invalidConfiguration", message: message, context: context, suggestion: suggestion)
    }

    public static func buildFailed(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "buildFailed", message: message, context: context, suggestion: suggestion)
    }

    public static func testFailed(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "testFailed", message: message, context: context, suggestion: suggestion)
    }

    public static func deviceNotFound(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "deviceNotFound", message: message, context: context, suggestion: suggestion)
    }

    public static func browserNotFound(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "browserNotFound", message: message, context: context, suggestion: suggestion)
    }

    public static func deploymentFailed(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "deploymentFailed", message: message, context: context, suggestion: suggestion)
    }

    public static func debuggerUnavailable(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "debuggerUnavailable", message: message, context: context, suggestion: suggestion)
    }

    public static func operationCancelled(_ message: String = "The operation was cancelled.") -> ToolingError {
        ToolingError(code: "operationCancelled", message: message)
    }

    public static func invalidArguments(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "invalidArguments", message: message, context: context, suggestion: suggestion)
    }

    /// A native tool the tooling depends on answered with a failure of its own.
    public static func commandFailed(_ message: String, context: [String: String] = [:], suggestion: String? = nil) -> ToolingError {
        ToolingError(code: "commandFailed", message: message, context: context, suggestion: suggestion)
    }

    public static func executableNotFound(_ executable: String) -> ToolingError {
        ToolingError(
            code: "executableNotFound",
            message: "The executable \(executable) was not found.",
            context: ["executable": executable],
            suggestion: "Install it, or put its directory on PATH."
        )
    }

    public static func processFailed(_ invocation: ProcessInvocation, exitCode: Int32) -> ToolingError {
        ToolingError(
            code: "processFailed",
            message: "\(invocation.label) failed with exit code \(exitCode).",
            context: ["executable": invocation.executable.path, "exitCode": "\(exitCode)"]
        )
    }

    public static func protocolError(_ message: String, context: [String: String] = [:]) -> ToolingError {
        ToolingError(code: "protocolError", message: message, context: context)
    }
}

extension Error {
    /// Every error leaving the tooling layer is structured.
    public var toolingError: ToolingError {
        if let error = self as? ToolingError { return error }
        if let error = self as? DecodingError {
            return ToolingError(code: "invalidData", message: "The data could not be decoded: \(error)")
        }
        return ToolingError(code: "internalError", message: localizedDescription)
    }
}
