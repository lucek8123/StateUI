// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum LogLevel: Int, Sendable, Comparable {
    case quiet = 0
    case error = 1
    case warning = 2
    case info = 3
    case debug = 4

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Diagnostics go to stderr; stdout is reserved for results and protocol frames.
public struct Logger: Sendable {
    public let level: LogLevel

    public init(level: LogLevel = .info) {
        self.level = level
    }

    public func error(_ message: String) { write("error", message) }
    public func warning(_ message: String) { write("warning", message) }
    public func info(_ message: String) { write("info", message) }
    public func debug(_ message: String) { write("debug", message) }

    private func write(_ kind: String, _ message: String) {
        let threshold: LogLevel
        switch kind {
        case "error": threshold = .error
        case "warning": threshold = .warning
        case "debug": threshold = .debug
        default: threshold = .info
        }
        guard level >= threshold else { return }
        let text = kind == "info" ? message : "stateui: \(kind): \(message)"
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    public func redacted(_ values: [String: String]) -> [String: String] {
        let sensitive = ["TOKEN", "SECRET", "PASSWORD", "KEY", "CREDENTIAL"]
        var result: [String: String] = [:]
        for (key, value) in values {
            let newKey = sensitive.contains { key.uppercased().contains($0) } ? key + "(redacted)" : key
            let newValue = value.count > 400 ? String(value.prefix(400)) + "…" : value
            result[newKey] = newValue
        }
        return result
    }
}

private extension Dictionary {
    func mapKeys(_ transform: (Key) -> Key) -> [Key: Value] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
