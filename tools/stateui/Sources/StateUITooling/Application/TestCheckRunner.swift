// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Runs the proofs a suite owes after its steps.
struct TestCheckRunner: Sendable {
    let tooling: Tooling
    let request: TestRequest
    let workspace: ResolvedWorkspace

    func run(_ checks: [TestCheck]) async -> [TestCheckOutcome] {
        let checkout = (try? HostSupport.checkout(workspace.context)) ?? workspace.project.root
        let session = TestSession(request: request, context: workspace.context)
        var outcomes: [TestCheckOutcome] = []
        for check in checks {
            switch check {
            case .apiRecord(let modules):
                outcomes.append(contentsOf: await apiRecord(modules, checkout: checkout, session: session))
            case .conformanceExports(let spec):
                outcomes.append(await ExportService(checkout: checkout).check(spec, tooling: tooling))
            case .androidTestListing(let spec):
                outcomes.append(AndroidTestListing.check(spec))
            }
        }
        return outcomes
    }

    private func apiRecord(
        _ modules: [APIModule], checkout: URL, session: TestSession
    ) async -> [TestCheckOutcome] {
        let service = APIReportService(tooling: tooling)
        let invocations: [ProcessInvocation]
        do {
            invocations = try service.invocations(
                modules: modules, repository: checkout, environment: session.environment()
            )
        } catch {
            return [TestCheckOutcome(name: "API record", status: .failed, detail: error.toolingError.message)]
        }
        var outcomes: [TestCheckOutcome] = []
        for (module, invocation) in zip(modules, invocations) {
            do {
                let outcome = try await tooling.execute(steps: [invocation], dryRun: request.dryRun)
                outcomes.append(TestCheckOutcome(
                    name: "API record \(module.name)",
                    status: outcome.status == .failed ? .failed : .passed
                ))
            } catch {
                outcomes.append(TestCheckOutcome(
                    name: "API record \(module.name)", status: .failed,
                    detail: error.toolingError.message
                ))
            }
        }
        return outcomes
    }
}

/// Whether every test and case the Android suite holds is listed where its runner can see it.
enum AndroidTestListing {
    static func check(_ spec: AndroidListingCheck) -> TestCheckOutcome {
        let sources = spec.package.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return TestCheckOutcome(name: "Android test listing", status: .failed,
                                    detail: "the test sources are missing at \(sources.path)")
        }
        let runner = (try? FileSystem.read(spec.runner)) ?? ""
        var unlisted: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            guard let text = try? FileSystem.read(file) else { continue }
            for test in matches(#"func (test[A-Za-z0-9_]+)\(\)"#, in: text) {
                if !text.contains("(\"\(test)\", \(test))") { unlisted.append(test) }
            }
            for name in matches(#"class ([A-Za-z0-9_]+): XCTestCase"#, in: text) {
                if !runner.contains("testCase(\(name).allTests)") { unlisted.append(name) }
            }
        }
        if unlisted.isEmpty {
            return TestCheckOutcome(name: "Android test listing", status: .passed)
        }
        return TestCheckOutcome(
            name: "Android test listing", status: .failed,
            detail: "listed nowhere, so never run: \(unlisted.sorted().joined(separator: ", "))"
        )
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let part = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[part])
        }
    }
}
