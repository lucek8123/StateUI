// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One application's module a host ships, measured and held to the budget the
/// repository records beside the host's declarations. The Web host's module is what
/// a page downloads, so it is measured gzipped, the way a page fetches it.
public struct SizeBudget: Codable, Sendable, Hashable {
    public enum Verdict: String, Codable, Sendable {
        case within
        case over
        case muchUnder
    }

    public let application: String
    public let module: URL
    public let bytes: Int
    public let budget: Int
    public let verdict: Verdict

    public init(application: String, module: URL, bytes: Int, budget: Int) {
        self.application = application
        self.module = module
        self.bytes = bytes
        self.budget = budget
        self.verdict = Self.verdict(of: bytes, against: budget)
    }

    /// Over when the module passes its budget; far under when it falls a twentieth
    /// or more below it, since a budget sitting that far under is one to lower.
    static func verdict(of bytes: Int, against budget: Int) -> Verdict {
        if bytes > budget { return .over }
        if bytes * 20 <= budget * 19 { return .muchUnder }
        return .within
    }

    public var sentence: String {
        switch verdict {
        case .over:
            return "\(application): \(bytes) bytes gzipped, over its budget of \(budget)"
        case .muchUnder:
            return "\(application): \(bytes) bytes gzipped, a twentieth or more under its budget of \(budget) - lower it"
        case .within:
            return "\(application): \(bytes) bytes gzipped, within its budget of \(budget)"
        }
    }
}

/// Every budget the tool measured, in the order the repository lists them. A module
/// over its budget fails the run, as the repository's own check of them did.
public struct SizeReport: Codable, Sendable {
    public let host: HostID
    public let configuration: BuildConfiguration
    public let budgets: [SizeBudget]

    public init(host: HostID, configuration: BuildConfiguration, budgets: [SizeBudget]) {
        self.host = host
        self.configuration = configuration
        self.budgets = budgets
    }

    public var failed: Bool { budgets.contains(where: { $0.verdict == .over }) }
}
