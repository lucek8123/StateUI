// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How a planned process is run.
public enum ExecutionMode: String, Codable, Sendable {
    /// Run it and wait for it to end.
    case run
    /// Start it, leave it running, and return once it has started.
    case background
    /// Run it and wait for it to end, following its output: a server, a
    /// logcat, a console session.
    case observe
}

/// One executable invocation. Arguments are always separate values; no shell
/// string is ever built from them.
public struct ProcessInvocation: Codable, Sendable, Hashable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL
    public let label: String
    public let captureOutput: Bool
    public let mode: ExecutionMode
    /// A step whose non-zero exit is expected - terminating an application
    /// that is not running, for instance - and does not fail the plan.
    public let allowFailure: Bool

    public init(
        executable: URL, arguments: [String], environment: [String: String] = [:],
        workingDirectory: URL, label: String, captureOutput: Bool = false,
        mode: ExecutionMode = .run, allowFailure: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.label = label
        self.captureOutput = captureOutput
        self.mode = mode
        self.allowFailure = allowFailure
    }

    public var displayCommand: String {
        ([executable.path] + arguments).map(ProcessInvocation.quote).joined(separator: " ")
    }

    public var displayEnvironment: String {
        environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(ProcessInvocation.quote($0.value))" }
            .joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\n'\"$`\\!&|;<>()*?[]{}")) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A file-system change a plan makes beside its processes. Planning stays
/// inspectable: a dry run prints these too.
public struct FileAction: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case createDirectory
        case remove
        case copy
        case copyTree
        case copyMatching
        case move
        case write
        case makeExecutable
        case symlink
    }

    public let kind: Kind
    public let source: URL?
    public let destination: URL?
    public let contents: String?
    public let matching: String?
    public let excluding: [String]

    public init(
        kind: Kind, source: URL? = nil, destination: URL? = nil, contents: String? = nil,
        matching: String? = nil, excluding: [String] = []
    ) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.contents = contents
        self.matching = matching
        self.excluding = excluding
    }

    public static func createDirectory(_ url: URL) -> FileAction {
        FileAction(kind: .createDirectory, destination: url)
    }

    public static func remove(_ url: URL) -> FileAction {
        FileAction(kind: .remove, destination: url)
    }

    public static func copy(_ source: URL, to destination: URL) -> FileAction {
        FileAction(kind: .copy, source: source, destination: destination)
    }

    public static func copyTree(_ source: URL, to destination: URL, excluding: [String] = []) -> FileAction {
        FileAction(kind: .copyTree, source: source, destination: destination, excluding: excluding)
    }

    /// Copies every regular file in `source` whose name ends in `matching`.
    public static func copyMatching(_ source: URL, matching: String, to destination: URL) -> FileAction {
        FileAction(kind: .copyMatching, source: source, destination: destination, matching: matching)
    }

    public static func move(_ source: URL, to destination: URL) -> FileAction {
        FileAction(kind: .move, source: source, destination: destination)
    }

    public static func write(_ contents: String, to destination: URL) -> FileAction {
        FileAction(kind: .write, destination: destination, contents: contents)
    }

    public static func makeExecutable(_ url: URL) -> FileAction {
        FileAction(kind: .makeExecutable, destination: url)
    }

    public static func symlink(_ destination: URL, to source: URL) -> FileAction {
        FileAction(kind: .symlink, source: source, destination: destination)
    }

    public var summary: String {
        switch kind {
        case .createDirectory: return "mkdir -p \(destination?.path ?? "")"
        case .remove: return "rm -rf \(destination?.path ?? "")"
        case .copy: return "cp \(source?.path ?? "") \(destination?.path ?? "")"
        case .copyTree: return "cp -R \(source?.path ?? "") \(destination?.path ?? "")"
        case .copyMatching: return "cp \(source?.path ?? "")/*\(matching ?? "") \(destination?.path ?? "")"
        case .move: return "mv \(source?.path ?? "") \(destination?.path ?? "")"
        case .write: return "write \(destination?.path ?? "")"
        case .makeExecutable: return "chmod +x \(destination?.path ?? "")"
        case .symlink: return "ln -s \(source?.path ?? "") \(destination?.path ?? "")"
        }
    }
}

/// Everything a build will do: its process steps, file actions and outputs.
public struct BuildPlan: Codable, Sendable {
    public let application: String
    public let host: HostID
    public let configuration: BuildConfiguration
    public let steps: [ProcessInvocation]
    public let actions: [FileAction]
    /// Steps that run after the file actions - codesigning a bundle that was
    /// just assembled, for instance.
    public let postSteps: [ProcessInvocation]
    public let outputs: [URL]
    public let notes: [String]

    public init(
        application: String, host: HostID, configuration: BuildConfiguration,
        steps: [ProcessInvocation], actions: [FileAction] = [], postSteps: [ProcessInvocation] = [],
        outputs: [URL] = [], notes: [String] = []
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.steps = steps
        self.actions = actions
        self.postSteps = postSteps
        self.outputs = outputs
        self.notes = notes
    }
}

/// One test suite's process steps, file actions and requirements.
public struct TestSuitePlan: Codable, Sendable {
    public let name: String
    public let detail: String
    public let steps: [ProcessInvocation]
    public let actions: [FileAction]
    public let postSteps: [ProcessInvocation]
    public let requiresDevice: Bool
    public let host: HostID?
    /// What the suite leaves behind - an APK built for another machine, say.
    public let outputs: [URL]

    public init(
        name: String, detail: String, steps: [ProcessInvocation],
        actions: [FileAction] = [], postSteps: [ProcessInvocation] = [],
        requiresDevice: Bool = false, host: HostID? = nil, outputs: [URL] = []
    ) {
        self.name = name
        self.detail = detail
        self.steps = steps
        self.actions = actions
        self.postSteps = postSteps
        self.requiresDevice = requiresDevice
        self.host = host
        self.outputs = outputs
    }
}

/// The test suites a host will run for an application.
public struct TestPlan: Codable, Sendable {
    public let application: String?
    public let host: HostID
    public let suites: [TestSuitePlan]

    public init(application: String?, host: HostID, suites: [TestSuitePlan]) {
        self.application = application
        self.host = host
        self.suites = suites
    }
}

/// Everything starting an application will do, including its build.
public struct RunPlan: Codable, Sendable {
    public let application: String
    public let host: HostID
    public let configuration: BuildConfiguration
    public let build: BuildPlan?
    public let steps: [ProcessInvocation]
    public let actions: [FileAction]
    public let detached: Bool
    public let factsFile: URL?
    public let url: String?
    public let logFile: URL?
    public let notes: [String]

    public init(
        application: String, host: HostID, configuration: BuildConfiguration,
        build: BuildPlan?, steps: [ProcessInvocation], actions: [FileAction] = [],
        detached: Bool = false, factsFile: URL? = nil, url: String? = nil,
        logFile: URL? = nil, notes: [String] = []
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.build = build
        self.steps = steps
        self.actions = actions
        self.detached = detached
        self.factsFile = factsFile
        self.url = url
        self.logFile = logFile
        self.notes = notes
    }
}

/// Everything deploying an application will do, including its build.
public struct DeployPlan: Codable, Sendable {
    public let application: String
    public let host: HostID
    public let configuration: BuildConfiguration
    public let build: BuildPlan?
    public let steps: [ProcessInvocation]
    public let actions: [FileAction]
    public let postSteps: [ProcessInvocation]
    public let destination: URL
    public let notes: [String]

    public init(
        application: String, host: HostID, configuration: BuildConfiguration,
        build: BuildPlan?, steps: [ProcessInvocation] = [], actions: [FileAction],
        postSteps: [ProcessInvocation] = [], destination: URL, notes: [String] = []
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.build = build
        self.steps = steps
        self.actions = actions
        self.postSteps = postSteps
        self.destination = destination
        self.notes = notes
    }
}

/// The debug adapter a plan launches.
public enum DebugAdapter: String, Codable, Sendable {
    case lldbDAP = "lldb-dap"
    case chrome
}

/// Whether a debug session launches a new process or attaches to one.
public enum DebugRequestKind: String, Codable, Sendable {
    case launch
    case attach
}

/// A debugger launch or attach configuration, with the build that prepares its artifact.
public struct DebugPlan: Codable, Sendable {
    public let adapter: DebugAdapter
    public let request: DebugRequestKind
    public let host: HostID
    public let application: String
    public let configuration: BuildConfiguration
    public let name: String
    public let program: String?
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]
    public let pid: Int?
    public let initCommands: [String]
    public let attachCommands: [String]
    public let url: String?
    public let runtimeExecutable: String?
    public let webRoot: String?
    /// The build preparation, in full: its steps, file actions and post-steps.
    /// A debugger is launched from the same artifact a normal build makes.
    public let build: BuildPlan?
    /// What starts the application held for the debugger, after the build.
    public let preLaunch: [ProcessInvocation]
    public let factsFile: URL?
    public let notes: [String]

    public init(
        adapter: DebugAdapter, request: DebugRequestKind, host: HostID, application: String,
        configuration: BuildConfiguration, name: String, program: String? = nil,
        arguments: [String] = [], workingDirectory: URL? = nil,
        environment: [String: String] = [:], pid: Int? = nil,
        initCommands: [String] = [], attachCommands: [String] = [],
        url: String? = nil, runtimeExecutable: String? = nil, webRoot: String? = nil,
        build: BuildPlan? = nil, preLaunch: [ProcessInvocation] = [],
        factsFile: URL? = nil, notes: [String] = []
    ) {
        self.adapter = adapter
        self.request = request
        self.host = host
        self.application = application
        self.configuration = configuration
        self.name = name
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.pid = pid
        self.initCommands = initCommands
        self.attachCommands = attachCommands
        self.url = url
        self.runtimeExecutable = runtimeExecutable
        self.webRoot = webRoot
        self.build = build
        self.preLaunch = preLaunch
        self.factsFile = factsFile
        self.notes = notes
    }
}

/// What the language server is told while the editor works as one host.
public struct LSPEnvironment: Codable, Sendable {
    public let host: HostID?
    public let environment: [String: String]
    public let scratchPath: String
    public let swiftSDK: String?
    public let sdk: String?
    public let triple: String?
    public let notes: [String]

    public init(
        host: HostID?, environment: [String: String], scratchPath: String,
        swiftSDK: String? = nil, sdk: String? = nil, triple: String? = nil, notes: [String] = []
    ) {
        self.host = host
        self.environment = environment
        self.scratchPath = scratchPath
        self.swiftSDK = swiftSDK
        self.sdk = sdk
        self.triple = triple
        self.notes = notes
    }
}

/// What removing a host's SourceKit index, or every host's, took away.
public struct LSPCleanResult: Codable, Sendable {
    public let removed: [String]
    public let absent: [String]
    public let notes: [String]

    public init(removed: [String], absent: [String] = [], notes: [String] = []) {
        self.removed = removed
        self.absent = absent
        self.notes = notes
    }
}

/// A `swift build --show-bin-path` for one host's index, so the editor can ask SourceKit to
/// write into that directory. The command is the plan; running it is what fills it.
public struct LSPIndexPlan: Codable, Sendable {
    public let host: HostID?
    public let packagePath: String
    public let indexDirectory: String
    public let binPath: String?
    public let command: [String]
    public let environment: [String: String]
    public let notes: [String]

    public init(
        host: HostID?, packagePath: String, indexDirectory: String, binPath: String? = nil,
        command: [String], environment: [String: String], notes: [String] = []
    ) {
        self.host = host
        self.packagePath = packagePath
        self.indexDirectory = indexDirectory
        self.binPath = binPath
        self.command = command
        self.environment = environment
        self.notes = notes
    }
}

/// The selections a build command accepts.
public struct BuildRequest: Sendable {
    public var application: String?
    public var host: HostID?
    public var configuration: BuildConfiguration
    public var device: String?
    public var browser: String?
    public var architecture: String?
    public var dryRun: Bool
    public var extraArguments: [String]

    public init(
        application: String? = nil, host: HostID? = nil, configuration: BuildConfiguration = .debug,
        device: String? = nil, browser: String? = nil, architecture: String? = nil,
        dryRun: Bool = false, extraArguments: [String] = []
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.device = device
        self.browser = browser
        self.architecture = architecture
        self.dryRun = dryRun
        self.extraArguments = extraArguments
    }
}

/// The selections a test command accepts.
public struct TestRequest: Sendable {
    public var application: String?
    public var host: HostID?
    public var configuration: BuildConfiguration
    public var device: String?
    public var filter: String?
    public var suite: String?
    /// The Web host's suites that need a browser's own page, run in one.
    public var browser: Bool
    /// Build the suite's artifact and stop, without running it - for a machine
    /// that builds where another runs.
    public var buildOnly: Bool
    /// The architecture the artifact is built for, where a device decides it.
    public var architecture: String?
    /// Write each conformance verdict under the revision its family stands at.
    public var updateExports: Bool
    /// Run only the conformance families whose verdicts stand at another revision.
    public var staleOnly: Bool
    public var dryRun: Bool

    public init(
        application: String? = nil, host: HostID? = nil, configuration: BuildConfiguration = .debug,
        device: String? = nil, filter: String? = nil, suite: String? = nil, browser: Bool = false,
        buildOnly: Bool = false, architecture: String? = nil, updateExports: Bool = false,
        staleOnly: Bool = false, dryRun: Bool = false
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.device = device
        self.filter = filter
        self.suite = suite
        self.browser = browser
        self.buildOnly = buildOnly
        self.architecture = architecture
        self.updateExports = updateExports
        self.staleOnly = staleOnly
        self.dryRun = dryRun
    }

    /// The variables a conformance run reads to write or narrow its verdicts.
    public var conformanceEnvironment: [String: String] {
        var variables: [String: String] = [:]
        if updateExports { variables["STATEUI_UPDATE_EXPORTS"] = "1" }
        if staleOnly { variables["STATEUI_STALE_ONLY"] = "1" }
        return variables
    }
}

/// The selections a run command accepts.
public struct RunRequest: Sendable {
    public var application: String?
    public var host: HostID?
    public var configuration: BuildConfiguration
    public var device: String?
    public var browser: String?
    public var port: Int?
    public var dryRun: Bool
    public var detach: Bool
    public var prepareDebugger: Bool
    public var noBuild: Bool

    public init(
        application: String? = nil, host: HostID? = nil, configuration: BuildConfiguration = .debug,
        device: String? = nil, browser: String? = nil, port: Int? = nil,
        dryRun: Bool = false, detach: Bool = false, prepareDebugger: Bool = false, noBuild: Bool = false
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.device = device
        self.browser = browser
        self.port = port
        self.dryRun = dryRun
        self.detach = detach
        self.prepareDebugger = prepareDebugger
        self.noBuild = noBuild
    }
}

/// The selections a deploy command accepts.
public struct DeployRequest: Sendable {
    public var application: String?
    public var host: HostID?
    public var configuration: BuildConfiguration
    public var device: String?
    public var browser: String?
    public var architecture: String?
    public var destination: URL?
    public var dryRun: Bool

    public init(
        application: String? = nil, host: HostID? = nil, configuration: BuildConfiguration = .release,
        device: String? = nil, browser: String? = nil, architecture: String? = nil,
        destination: URL? = nil, dryRun: Bool = false
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.device = device
        self.browser = browser
        self.architecture = architecture
        self.destination = destination
        self.dryRun = dryRun
    }
}

/// The selections a debug command accepts.
public struct DebugRequest: Sendable {
    public var application: String?
    public var host: HostID?
    public var configuration: BuildConfiguration
    public var device: String?
    public var browser: String?
    public var prepare: Bool
    public var dryRun: Bool

    public init(
        application: String? = nil, host: HostID? = nil, configuration: BuildConfiguration = .debug,
        device: String? = nil, browser: String? = nil, prepare: Bool = false, dryRun: Bool = false
    ) {
        self.application = application
        self.host = host
        self.configuration = configuration
        self.device = device
        self.browser = browser
        self.prepare = prepare
        self.dryRun = dryRun
    }
}

/// What an executed plan did.
public struct ExecutionOutcome: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case planned
        case succeeded
        case failed
        case started
        case cancelled
    }

    public let status: Status
    public let duration: Double
    public let outputs: [URL]
    public let factsFile: URL?
    public let url: String?
    public let notes: [String]

    public init(
        status: Status, duration: Double = 0, outputs: [URL] = [],
        factsFile: URL? = nil, url: String? = nil, notes: [String] = []
    ) {
        self.status = status
        self.duration = duration
        self.outputs = outputs
        self.factsFile = factsFile
        self.url = url
        self.notes = notes
    }
}
