// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Starts a stopped device a host can run on - an Android AVD, say - and answers with it once it is ready.
public struct DeviceService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    public func boot(
        host: HostID, name: String, project: URL? = nil
    ) async throws -> Device {
        let workspace = try tooling.resolve(project: project, host: host)
        return try await tooling.driver(for: host).boot(device: name, context: workspace.context)
    }
}
