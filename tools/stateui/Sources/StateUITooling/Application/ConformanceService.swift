// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The conformance revisions and verdicts a host's run holds to.
public struct ConformanceService: Sendable {
    public let checkout: URL

    public init(checkout: URL) {
        self.checkout = checkout
    }

    /// The revision a family's verdicts on a host stand at, as `revisions.txt` says: every host's, then the host's.
    public func revision(host: HostID, family: String) throws -> String {
        var every = 1
        var own = 1
        let text = try FileSystem.read(revisionsFile)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, !first.hasPrefix("#") else { continue }
            if fields.count == 2, first == family {
                every = Int(fields[1]) ?? 1
            } else if fields.count == 3, first == host.rawValue, fields[1] == family {
                own = Int(fields[2]) ?? 1
            }
        }
        return "\(every).\(own)"
    }

    /// The families the host's conformance class runs, in the order its file lists them: a method whose body
    /// begins `conform`, `try conform` on Android's throwing tests - not the host's own tests beside them.
    public func families(host: HostID) throws -> [String] {
        let text = try FileSystem.read(testFile(host: host))
        let regex = try NSRegularExpression(
            pattern: #"func test([A-Za-z0-9_]+)\(\)(?: throws)? \{\s*(?:try )?conform"#
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var families: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let found = Range(match.range(at: 1), in: text) else { continue }
            let family = String(text[found])
            if !families.contains(family) { families.append(family) }
        }
        return families
    }

    /// The families whose verdicts stand at another revision, or at none.
    public func staleFamilies(host: HostID) throws -> [String] {
        var stale: [String] = []
        for family in try families(host: host) {
            let expected = "# revision \(try revision(host: host, family: family))"
            let first = (try? FileSystem.read(markFile(host: host, family: family)))?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            if first != expected { stale.append(family) }
        }
        return stale
    }

    public func marksDirectory(host: HostID) -> URL {
        checkout.appendingPathComponent("lib/StateUI/exports/marks/\(host.rawValue)", isDirectory: true)
    }

    public func markFile(host: HostID, family: String) -> URL {
        marksDirectory(host: host).appendingPathComponent("\(family).txt")
    }

    private var revisionsFile: URL {
        checkout.appendingPathComponent("lib/StateUI/StateUI.Conformance/revisions.txt")
    }

    private func testFile(host: HostID) -> URL {
        switch host {
        case .appKit:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.AppKit/Tests/Conformance/AppKitConformanceTests.swift")
        case .uiKit:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.UIKit/Tests/Sources/Conformance/UIKitConformanceTests.swift")
        case .android:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.Android/Tests/Sources/Conformance/AndroidConformanceTests.swift")
        case .winUI:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.WinUI/Testing/Tests/Conformance/WinUIConformanceTests.swift")
        case .gtk:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.GTK/Testing/Tests/Conformance/GTKConformanceTests.swift")
        case .web:
            return checkout.appendingPathComponent(
                "lib/StateUI/StateUI.Web/Testing/Tests/Conformance/WebConformanceTests.swift")
        }
    }
}
