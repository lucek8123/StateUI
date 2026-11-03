// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The tool's own identity, reported by `stateui version` and `initialize`.
public enum ToolingVersion {
    /// The StateUI release the tooling ships with.
    public static let version = "0.8.1"

    /// The JSON-RPC protocol revision. Bumped when a request or notification
    /// changes shape incompatibly.
    public static let protocolVersion = 1

    /// The one-line identity `stateui --version` and `stateui version` print.
    public static var summary: String {
        "stateui \(version) (protocol \(protocolVersion))"
    }
}
