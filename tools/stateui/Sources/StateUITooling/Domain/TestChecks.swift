// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One module a host's build made, held to its record in `lib/StateUI/exports/api`.
public struct APIModule: Codable, Sendable, Hashable {
    public let name: String
    public let modules: URL
    public let triple: String?
    public let sdk: String?
    public let arguments: [String]

    public init(
        name: String, modules: URL, triple: String? = nil, sdk: String? = nil, arguments: [String] = []
    ) {
        self.name = name
        self.modules = modules
        self.triple = triple
        self.sdk = sdk
        self.arguments = arguments
    }
}

/// A proof a suite owes after its steps: the public API record, the conformance verdicts, a host's listing.
public enum TestCheck: Codable, Sendable, Hashable {
    /// Hold each module to `lib/StateUI/exports/api/<name>.txt`, or write it under `--update-exports`.
    case apiRecord([APIModule])
    /// Hold the host's conformance verdicts to `lib/StateUI/exports`, or write them under `--update-exports`.
    case conformanceExports(ConformanceExportsCheck)
    /// A suite whose tests or cases are listed nowhere would never run.
    case androidTestListing(AndroidListingCheck)
}

/// What a conformance export check needs to find the verdicts.
public struct ConformanceExportsCheck: Codable, Sendable, Hashable {
    public let host: HostID
    public let device: String?
    public let adb: URL?
    public let package: String?
    public let update: Bool
    public let staleOnly: Bool
    public let filtered: Bool

    public init(
        host: HostID, device: String? = nil, adb: URL? = nil, package: String? = nil,
        update: Bool, staleOnly: Bool, filtered: Bool
    ) {
        self.host = host
        self.device = device
        self.adb = adb
        self.package = package
        self.update = update
        self.staleOnly = staleOnly
        self.filtered = filtered
    }
}

/// The Android test package and runner a listing check reads.
public struct AndroidListingCheck: Codable, Sendable, Hashable {
    public let package: URL
    public let runner: URL

    public init(package: URL, runner: URL) {
        self.package = package
        self.runner = runner
    }
}

extension TestCheck {
    /// What the check does, for a plan read by a person.
    public var summary: String {
        switch self {
        case .apiRecord(let modules):
            return "API record \(modules.map(\.name).joined(separator: ", "))"
        case .conformanceExports(let spec):
            return "conformance exports on \(spec.host.label)"
        case .androidTestListing:
            return "Android test listing"
        }
    }
}

/// What a check proved.
public struct TestCheckOutcome: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case passed
        case failed
        case skipped
    }

    public let name: String
    public let status: Status
    public let detail: String?
    public let output: String?

    public init(name: String, status: Status, detail: String? = nil, output: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.output = output
    }
}
