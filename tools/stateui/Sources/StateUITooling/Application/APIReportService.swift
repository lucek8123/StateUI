// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Holds a host's built modules to their public API records, through the core's `APISurfaceTests`.
public struct APIReportService: Sendable {
    public let tooling: Tooling

    public init(tooling: Tooling) {
        self.tooling = tooling
    }

    /// The steps that record, or hold, each module under `lib/StateUI/exports/api/<name>.txt`.
    public func invocations(
        modules: [APIModule], repository: URL, environment: [String: String]
    ) throws -> [ProcessInvocation] {
        let builder = SwiftBuilder(
            runner: CommandRunner(executor: tooling.executor, environment: tooling.environment),
            environment: tooling.environment, platform: tooling.platform
        )
        let swift = try builder.swift()
        return modules.map { module in
            var values = environment
            values["STATEUI_API_MODULE"] = module.name
            values["STATEUI_API_MODULES"] = module.modules.path
            values["STATEUI_API_TRIPLE"] = module.triple ?? ""
            values["STATEUI_API_SDK"] = module.sdk ?? ""
            values["STATEUI_API_ARGUMENTS"] = module.arguments.joined(separator: " ")
            return ProcessInvocation(
                executable: swift,
                arguments: [
                    "test", "--package-path", repository.path,
                    "--filter", "APISurfaceTests/testTheModuleAHostsScriptNamesIsItsRecord",
                ],
                environment: values,
                unsetEnvironment: ["STATEUI_HOST"],
                workingDirectory: repository,
                label: "Record the public API of \(module.name)"
            )
        }
    }
}
