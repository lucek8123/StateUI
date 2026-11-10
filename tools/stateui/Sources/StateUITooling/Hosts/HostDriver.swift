// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What every host driver can ask of the host.
public protocol HostDriver: Sendable {
    var id: HostID { get }
    var capabilities: HostCapabilities { get }

    /// Whether this machine can build, run and test the host now.
    func availability(_ context: ProjectContext) async -> HostAvailability

    /// The devices a head can run on. Empty where the host has none.
    func devices(_ context: ProjectContext) async throws -> [Device]

    /// Starts a stopped device - an Android AVD, say - and returns it once it is ready.
    func boot(device name: String, context: ProjectContext) async throws -> Device

    /// The browsers a page can run in. Empty where the host has none.
    func browsers(_ context: ProjectContext) async throws -> [Browser]

    func buildPlan(_ request: BuildRequest, context: ProjectContext) async throws -> BuildPlan
    func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan
    func runPlan(_ request: RunRequest, context: ProjectContext, build: BuildPlan?) async throws -> RunPlan
    func deployPlan(_ request: DeployRequest, context: ProjectContext, build: BuildPlan?) async throws -> DeployPlan
    func debugPlan(_ request: DebugRequest, context: ProjectContext, build: BuildPlan?) async throws -> DebugPlan
    func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment
}

public extension HostDriver {
    func devices(_ context: ProjectContext) async throws -> [Device] { [] }
    func boot(device name: String, context: ProjectContext) async throws -> Device {
        throw ToolingError.unsupportedHost("\(id.label) has no device this tool can start.")
    }
    func browsers(_ context: ProjectContext) async throws -> [Browser] { [] }

    func testPlan(_ request: TestRequest, context: ProjectContext) async throws -> TestPlan {
        TestPlan(application: context.application?.name, host: id, suites: [])
    }

    func runPlan(_ request: RunRequest, context: ProjectContext, build: BuildPlan?) async throws -> RunPlan {
        throw ToolingError.unsupportedHost("\(id.label) heads cannot be run by this tool yet.")
    }

    func deployPlan(_ request: DeployRequest, context: ProjectContext, build: BuildPlan?) async throws -> DeployPlan {
        throw ToolingError.unsupportedHost("\(id.label) heads cannot be deployed by this tool yet.")
    }

    func debugPlan(_ request: DebugRequest, context: ProjectContext, build: BuildPlan?) async throws -> DebugPlan {
        throw ToolingError.unsupportedHost("\(id.label) heads cannot be debugged by this tool yet.")
    }

    func lspEnvironment(_ context: ProjectContext) async throws -> LSPEnvironment {
        LSPEnvironment(
            host: id,
            environment: ["STATEUI_HOST": id.rawValue],
            scratchPath: id.indexDirectory
        )
    }
}

/// Resolves a host to its driver. The one place host-specific behavior is
/// chosen.
public struct HostRegistry: Sendable {
    public let drivers: [HostID: any HostDriver]

    public init(drivers: [any HostDriver]) {
        self.drivers = Dictionary(uniqueKeysWithValues: drivers.map { ($0.id, $0) })
    }

    public static func standard(
        executor: any ProcessExecuting, environment: Environment = .current, platform: Platform = .current
    ) -> HostRegistry {
        HostRegistry(drivers: [
            AppKitHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                             environment: environment, platform: platform),
            UIKitHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                            environment: environment, platform: platform),
            AndroidHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                              environment: environment, platform: platform),
            WinUIHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                            environment: environment, platform: platform),
            GTKHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                          environment: environment, platform: platform),
            WebHostDriver(runner: CommandRunner(executor: executor, environment: environment),
                          environment: environment, platform: platform),
        ])
    }

    public func driver(for host: HostID) throws -> any HostDriver {
        guard let driver = drivers[host] else {
            throw ToolingError.unsupportedHost("\(host.label) has no driver in this build.")
        }
        return driver
    }

    public func descriptors() -> [HostDescriptor] {
        HostID.allCases.map(HostDescriptor.init(id:))
    }

    public func availability(_ context: ProjectContext) async -> [HostAvailability] {
        var found: [HostAvailability] = []
        for host in HostID.allCases {
            guard let driver = drivers[host] else {
                found.append(HostAvailability(host: host, status: .unavailable, reason: "No driver."))
                continue
            }
            found.append(await driver.availability(context))
        }
        return found
    }
}
