// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct ParsedCommand: Sendable {
    public var positionals: [String]
    public var values: [String: String]
    public var flags: Set<String>

    public init(positionals: [String] = [], values: [String: String] = [:], flags: Set<String> = []) {
        self.positionals = positionals
        self.values = values
        self.flags = flags
    }

    public func value(_ name: String) -> String? { values[name] }
    public func flag(_ name: String) -> Bool { flags.contains(name) }

    /// The application a command names: `--application`, or the first positional
    /// that is not a sub-command the command reads itself. The sub-commands are
    /// dropped, and whatever stands beside the application is what the command
    /// hands to the toolchain as extra arguments.
    public func application(besides subcommands: [String] = []) -> (name: String?, extras: [String]) {
        var left = positionals.filter { !subcommands.contains($0) }
        let name = value("application") ?? left.first
        if let name, let index = left.firstIndex(of: name) {
            left.remove(at: index)
        }
        return (name, left)
    }
}

public enum CommandLineParser {
    /// Every option that takes a value, and only those some command reads.
    public static let valueOptions: Set<String> = [
        "project", "host", "configuration", "device", "browser", "port", "filter",
        "suite", "architecture", "destination", "apps-dir", "checkout",
        "name", "application", "transport", "minimum", "device-host",
    ]

    /// Only options some command reads. An option nothing reads is refused rather
    /// than quietly ignored: a caller asking for it is told the tool takes no such
    /// thing, instead of getting an answer that did not use what they passed.
    public static let flagOptions: Set<String> = [
        "json", "quiet", "verbose", "dry-run", "help", "detach",
        "prepare", "no-build", "all", "stdio",
        "build-only", "in-browser", "update-exports", "stale",
    ]

    public static func parse(_ arguments: [String]) throws -> ParsedCommand {
        var parsed = ParsedCommand()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                parsed.positionals.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if argument.hasPrefix("--") {
                let body = String(argument.dropFirst(2))
                let pieces = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(pieces[0])
                if pieces.count == 2 {
                    guard valueOptions.contains(name) else {
                        throw ToolingError.invalidArguments("Option --\(name) does not take a value.")
                    }
                    parsed.values[name] = String(pieces[1])
                } else if valueOptions.contains(name) {
                    index += 1
                    guard index < arguments.count else {
                        throw ToolingError.invalidArguments("Option --\(name) needs a value.")
                    }
                    parsed.values[name] = arguments[index]
                } else if flagOptions.contains(name) {
                    parsed.flags.insert(name)
                } else {
                    throw ToolingError.invalidArguments("Unknown option --\(name).")
                }
            } else if argument.hasPrefix("-") && argument.count > 1 {
                switch argument {
                case "-h": parsed.flags.insert("help")
                case "-v": parsed.flags.insert("verbose")
                case "-q": parsed.flags.insert("quiet")
                case "-j": parsed.flags.insert("json")
                default:
                    throw ToolingError.invalidArguments("Unknown option \(argument).")
                }
            } else {
                parsed.positionals.append(argument)
            }
            index += 1
        }
        return parsed
    }
}
