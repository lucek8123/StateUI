// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What one host of an all-available run did.
public struct HostTestOutcome: Codable, Sendable {
    public let host: HostID
    public let device: String?
    public let status: ExecutionOutcome.Status
    public let duration: Double
    public let executed: Int?
    public let failures: Int
    public let failedTests: [String]
    public let note: String?

    public init(
        host: HostID, device: String? = nil, status: ExecutionOutcome.Status, duration: Double = 0,
        executed: Int? = nil, failures: Int = 0, failedTests: [String] = [], note: String? = nil
    ) {
        self.host = host
        self.device = device
        self.status = status
        self.duration = duration
        self.executed = executed
        self.failures = failures
        self.failedTests = failedTests
        self.note = note
    }
}

/// What every host of an all-available run did.
public struct TestReport: Codable, Sendable {
    public let runs: [HostTestOutcome]

    public init(runs: [HostTestOutcome]) {
        self.runs = runs
    }

    public var succeeded: Bool { !runs.isEmpty && runs.allSatisfy { $0.status == .succeeded } }
    public var passed: Int { runs.filter { $0.status == .succeeded }.count }
    public var failed: Int { runs.filter { $0.status != .succeeded }.count }
}

/// One host's plan in an all-available run.
public struct HostTestPlan: Codable, Sendable {
    public let host: HostID
    public let device: String?
    public let plan: TestPlan

    public init(host: HostID, device: String? = nil, plan: TestPlan) {
        self.host = host
        self.device = device
        self.plan = plan
    }
}

extension TestService {
    /// The plans for every host this machine offers, one default device or browser each.
    public func planAll(_ request: TestRequest, project: URL? = nil) async throws -> [HostTestPlan] {
        var plans: [HostTestPlan] = []
        for target in try await targets(request, project: project) {
            let perHost = request.forHost(target.host, device: target.deviceID, browser: target.browser)
            let (_, testPlan) = try await plan(perHost, project: project)
            plans.append(HostTestPlan(host: target.host, device: target.label, plan: testPlan))
        }
        return plans
    }

    /// Runs every host this machine offers, one default device or browser each, and reports every result.
    public func runAll(_ request: TestRequest, project: URL? = nil) async throws -> TestReport {
        var runs: [HostTestOutcome] = []
        let progress = tooling.outputHandler()
        for target in try await targets(request, project: project) {
            let perHost = request.forHost(target.host, device: target.deviceID, browser: target.browser)
            let collector = OutputCollector()
            do {
                let outcome = try await run(perHost, project: project) { output in
                    collector.append(output.text)
                    progress(output)
                }
                let parsed = TestOutput.parse(collector.value)
                runs.append(HostTestOutcome(
                    host: target.host, device: target.label, status: outcome.status,
                    duration: outcome.duration, executed: parsed.executed,
                    failures: parsed.failures, failedTests: parsed.failed
                ))
            } catch {
                let failure = error.toolingError
                let parsed = TestOutput.parse(collector.value)
                runs.append(HostTestOutcome(
                    host: target.host, device: target.label, status: .failed,
                    executed: parsed.executed, failures: max(parsed.failures, 1),
                    failedTests: parsed.failed, note: failure.message
                ))
            }
        }
        return TestReport(runs: runs)
    }

    /// One host, its default device or browser, and whether the Web page is asked for.
    private struct Target {
        let host: HostID
        let deviceID: String?
        let label: String?
        let browser: Bool
    }

    /// Every ready host, one default simulator, device or browser each.
    private func targets(_ request: TestRequest, project explicit: URL?) async throws -> [Target] {
        let service = ProjectService(tooling: tooling)
        let hosts = try await service.hosts(project: explicit)
        var targets: [Target] = []
        for availability in hosts where availability.isReady {
            switch availability.host {
            case .uiKit:
                let devices = try await service.devices(host: .uiKit, project: explicit)
                guard let simulator = devices.first(where: { $0.kind == .simulator }) else { continue }
                targets.append(Target(
                    host: .uiKit, deviceID: simulator.id, label: simulator.name, browser: false
                ))
            case .android:
                let devices = try await service.devices(host: .android, project: explicit)
                guard let device = devices.first(where: { $0.kind == .emulator || $0.kind == .physical })
                        ?? devices.first(where: { $0.kind != .avd }) else { continue }
                targets.append(Target(
                    host: .android, deviceID: device.id, label: device.name, browser: false
                ))
            case .web:
                let inBrowser = request.browser || request.conformance
                if inBrowser {
                    let browsers = try await service.browsers(project: explicit)
                    guard let browser = browsers.first(where: { $0.isDefault && $0.isChromium })
                            ?? browsers.first(where: { $0.isChromium }) else { continue }
                    targets.append(Target(host: .web, deviceID: nil, label: browser.name, browser: true))
                } else {
                    targets.append(Target(host: .web, deviceID: nil, label: nil, browser: false))
                }
            case .appKit, .winUI, .gtk:
                targets.append(Target(host: availability.host, deviceID: nil, label: nil, browser: false))
            }
        }
        guard !targets.isEmpty else {
            throw ToolingError.toolchainMissing(
                "No StateUI host is ready on this machine.",
                suggestion: "Run `stateui doctor` to see what each host needs."
            )
        }
        return targets
    }
}

/// Collects a process's output so a finished run can name its failures.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

/// The tests a suite printed as run and failed.
private struct TestOutput {
    let executed: Int?
    let failures: Int
    let failed: [String]

    static func parse(_ text: String) -> TestOutput {
        let failed = matches(#"Test Case '([^']+)' failed"#, in: text).map { $0[1] }
        let summaries = matches(#"Executed (\d+) tests?, with (\d+) failures?"#, in: text)
        let executed = summaries.last.flatMap { Int($0[1]) }
        let failures = summaries.last.flatMap { Int($0[2]) } ?? failed.count
        return TestOutput(executed: executed, failures: max(failures, failed.count), failed: failed)
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let part = Range(match.range(at: index), in: text) else { return "" }
                return String(text[part])
            }
        }
    }
}
