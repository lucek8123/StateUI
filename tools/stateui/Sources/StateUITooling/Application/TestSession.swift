// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What one test run stands on: the request, the checkout, and the variables its host reads.
public struct TestSession: Sendable {
    public let request: TestRequest
    public let context: ProjectContext

    public init(request: TestRequest, context: ProjectContext) {
        self.request = request
        self.context = context
    }

    /// The checkout the run's suites, records and verdicts stand in.
    public var checkout: URL? {
        try? HostSupport.checkout(context)
    }

    /// The application's own `STATEUI_*` variables, the conformance flags over them.
    public func environment(prefix: String? = nil) -> [String: String] {
        var values = context.environment.stateuiVariables
        for (key, value) in request.conformanceEnvironment { values[key] = value }
        if let prefix {
            values = values.reduce(into: [:]) { $0[prefix + $1.key] = $1.value }
        }
        return values
    }
}
