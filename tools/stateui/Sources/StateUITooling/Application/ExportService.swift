// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Holds a host's conformance verdicts to `lib/StateUI/exports`, or writes them under `--update-exports`.
public struct ExportService: Sendable {
    public let checkout: URL
    public let conformance: ConformanceService

    public init(checkout: URL) {
        self.checkout = checkout
        self.conformance = ConformanceService(checkout: checkout)
    }

    /// The Android run's own exports, pulled from the device as the device reads no repository.
    public func check(
        _ check: ConformanceExportsCheck, tooling: Tooling
    ) async -> TestCheckOutcome {
        guard check.host == .android else {
            return TestCheckOutcome(name: "conformance exports", status: .skipped,
                                    detail: "\(check.host.label) holds its exports in its own runner")
        }
        guard !check.filtered || check.staleOnly else {
            return TestCheckOutcome(name: "conformance exports", status: .skipped,
                                    detail: "a filtered run holds nothing to the exports")
        }
        guard let adb = check.adb, let device = check.device, let package = check.package else {
            return TestCheckOutcome(name: "conformance exports", status: .failed,
                                    detail: "the Android exports need a device and its test package")
        }

        let runner = CommandRunner(executor: tooling.executor, environment: tooling.environment)
        func adbOutput(_ arguments: [String], label: String) async -> String? {
            await runner.output(
                adb, ["-s", device] + arguments, workingDirectory: checkout, label: label
            )
        }

        let declared = check.staleOnly ? nil : await adbOutput(
            ["exec-out", "run-as", package, "cat", "files/android.txt"], label: "android.txt"
        )
        if !check.staleOnly, declared == nil {
            return TestCheckOutcome(name: "conformance exports", status: .failed,
                                    detail: "the device holds no files/android.txt")
        }

        let listing = await adbOutput(
            ["exec-out", "run-as", package, "ls", "files/marks/android"], label: "marks/android"
        ) ?? ""
        // `ls` writes columns when its output is not a terminal; names are split on any whitespace.
        let names = listing.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.hasSuffix(".txt") }

        var marks: [String: String] = [:]
        for name in names {
            guard let body = await adbOutput(
                ["exec-out", "run-as", package, "cat", "files/marks/android/\(name)"],
                label: "marks/android/\(name)"
            ) else { continue }
            let family = String(name.dropLast(4))
            let revision = (try? conformance.revision(host: .android, family: family)) ?? "1.1"
            marks[name] = "# revision \(revision)\n" + body
        }

        let exports = checkout.appendingPathComponent("lib/StateUI/exports", isDirectory: true)
        let declarationFile = exports.appendingPathComponent("android.txt")
        let marksDirectory = conformance.marksDirectory(host: .android)

        if check.update {
            do {
                if !check.staleOnly, let declared {
                    try FileSystem.write(declared, to: declarationFile)
                }
                if !check.staleOnly {
                    try? FileSystem.remove(marksDirectory)
                }
                try FileSystem.makeDirectory(marksDirectory)
                for (name, text) in marks {
                    try FileSystem.write(text, to: marksDirectory.appendingPathComponent(name))
                }
            } catch {
                return TestCheckOutcome(name: "conformance exports", status: .failed,
                                        detail: error.toolingError.message)
            }
            return TestCheckOutcome(name: "conformance exports", status: .passed,
                                    detail: check.staleOnly
                                        ? "wrote \(marks.count) verdicts"
                                        : marks.isEmpty ? "wrote android.txt" : "wrote \(marks.count) verdicts")
        }

        if !check.staleOnly {
            guard let declared else {
                return TestCheckOutcome(name: "conformance exports", status: .failed,
                                        detail: "the device holds no files/android.txt")
            }
            if (try? FileSystem.read(declarationFile)) != declared {
                return TestCheckOutcome(name: "conformance exports", status: .failed,
                                        detail: "lib/StateUI/exports/android.txt is not what the host declares")
            }
        }

        let kept = FileSystem.children(marksDirectory).filter { $0.pathExtension == "txt" }
        // Two runs at other revisions compare by their verdicts, the line naming the revision aside.
        var keptVerdicts: [String: String] = [:]
        for file in kept {
            keptVerdicts[file.lastPathComponent] = Self.verdictsAlone(
                (try? FileSystem.read(file)) ?? ""
            )
        }
        var runVerdicts: [String: String] = [:]
        for (name, text) in marks { runVerdicts[name] = Self.verdictsAlone(text) }
        if check.staleOnly {
            // A run of the stale families holds only theirs to what was kept.
            keptVerdicts = keptVerdicts.filter { runVerdicts[$0.key] != nil }
        }
        let keptNames = Set(keptVerdicts.keys)
        let runNames = Set(runVerdicts.keys)
        if keptNames != runNames {
            return TestCheckOutcome(
                name: "conformance exports", status: .failed,
                detail: "the run's families \(runNames.sorted()) are not the kept families \(keptNames.sorted())"
            )
        }
        for (name, text) in runVerdicts where keptVerdicts[name] != text {
            return TestCheckOutcome(
                name: "conformance exports", status: .failed,
                detail: "lib/StateUI/exports/marks/android/\(name) is not what this run proved"
            )
        }
        return TestCheckOutcome(name: "conformance exports", status: .passed,
                                detail: "\(marks.count) verdicts hold")
    }

    /// A verdict file without the line naming the revision its family stands at.
    static func verdictsAlone(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("# revision ") }
            .joined(separator: "\n")
    }
}
