// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The encoder and decoder every result and protocol frame uses.
public enum JSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        try encoder(pretty: pretty).encode(value).string()
    }
}

extension Data {
    public func string() -> String {
        String(data: self, encoding: .utf8) ?? ""
    }
}

/// Dotted-version parsing and comparison.
public enum Version {
    /// The first dotted version in `text`.
    public static func first(in text: String) -> String? {
        guard let range = text.range(of: #"\d+(?:\.\d+)+|\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(text[range])
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    public static func atLeast(_ version: String, _ minimum: String) -> Bool {
        compare(version, minimum) >= 0
    }

    /// Whether two releases stand on the same major.minor line: `6.4` and `6.4.1` are the same release.
    public static func sameRelease(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").compactMap { Int($0) }
        let right = rhs.split(separator: ".").compactMap { Int($0) }
        guard left.count >= 2, right.count >= 2 else { return lhs == rhs }
        return left[0] == right[0] && left[1] == right[1]
    }

    /// Swift's release as the SDK ids name it: `6.4` for `6.4.0`.
    public static func swiftRelease(in text: String) -> String? {
        let version = text.range(of: #"Swift version (\d+\.\d+(?:\.\d+)?)"#, options: .regularExpression)
            .map { String(text[$0]) }?
            .replacingOccurrences(of: "Swift version ", with: "")
            ?? first(in: text)
        return version?.replacingOccurrences(of: #"^(\d+\.\d+)\.0$"#, with: "$1", options: .regularExpression)
    }
}
