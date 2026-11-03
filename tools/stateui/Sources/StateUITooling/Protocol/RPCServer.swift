// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a request knows while it runs: the task an editor can cancel, where its
/// progress goes, and whether the client has given it up.
public struct RPCContext: Sendable {
    public let taskID: String?
    public let progress: @Sendable (String) -> Void
    private let cancellation: @Sendable () -> Bool

    public init(
        taskID: String? = nil,
        progress: @escaping @Sendable (String) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.taskID = taskID
        self.progress = progress
        self.cancellation = isCancelled
    }

    public var isCancelled: Bool { cancellation() }

    public static let silent = RPCContext()
}

public protocol RPCHandling: Sendable {
    /// Methods an editor waits on return a `{ taskId, status: "started" }`
    /// answer and report their work through `task.progress`,
    /// `task.completed` and `task.failed` notifications.
    func isLongRunning(method: String, params: JSONValue?) -> Bool
    func handle(method: String, params: JSONValue?, context: RPCContext) async throws -> JSONValue
}

public extension RPCHandling {
    func isLongRunning(method: String, params: JSONValue?) -> Bool { false }

    func handle(method: String, params: JSONValue?) async throws -> JSONValue {
        try await handle(method: method, params: params, context: .silent)
    }
}

/// Serializes frames onto one output handle; protocol and JSON only. A lock
/// rather than an actor keeps a progress notification in the order its task
/// wrote it, beside the task's completion.
public final class RPCWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    public init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    public func send(_ response: RPCResponse) {
        guard let data = try? JSON.encoder().encode(response) else { return }
        write(RPCFraming.frame(data))
    }

    public func send(_ notification: RPCNotification) {
        guard let data = try? JSON.encoder().encode(notification) else { return }
        write(RPCFraming.frame(data))
    }

    public func sendRaw(_ body: Data) {
        write(RPCFraming.frame(body))
    }

    private func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // A closed pipe is the client going away; the reader ends too.
        }
    }
}

private actor RPCTaskRegistry {
    private var tasks: [RPCID: Task<Void, Never>] = [:]
    private var nextTask = 1

    func makeTaskID() -> RPCID {
        let id = RPCID.string("task-\(nextTask)")
        nextTask += 1
        return id
    }

    func add(_ task: Task<Void, Never>, requestID: RPCID, taskID: RPCID) {
        tasks[requestID] = task
        tasks[taskID] = task
    }

    func cancel(_ id: RPCID) {
        tasks[id]?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
    }

    func drain() async {
        let pending = Array(tasks.values)
        tasks.removeAll()
        for task in pending { _ = await task.value }
    }
}

/// The stdio JSON-RPC server: one request at a time per task, cancellable, with
/// stdout reserved for frames. A long-running method answers at once with a task
/// id and reports its work by notification.
public struct RPCServer: Sendable {
    public let handler: any RPCHandling
    public let input: FileHandle
    public let writer: RPCWriter
    public let logger: Logger

    public init(
        handler: any RPCHandling, input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput, logger: Logger = Logger()
    ) {
        self.handler = handler
        self.input = input
        self.writer = RPCWriter(handle: output)
        self.logger = logger
    }

    public func run() async throws {
        let registry = RPCTaskRegistry()
        let frames = stream()
        for await frame in frames {
            let request: RPCRequest
            do {
                request = try JSON.decoder().decode(RPCRequest.self, from: frame)
            } catch {
                writer.send(RPCResponse(id: nil, error: .parseError))
                continue
            }

            if request.method == "$/cancelRequest" {
                if let id = cancelID(request.params) {
                    await registry.cancel(id)
                }
                continue
            }
            if request.method == "exit" {
                break
            }
            if request.isNotification {
                Task {
                    do {
                        _ = try await handler.handle(
                            method: request.method, params: request.params, context: .silent
                        )
                    } catch {
                        logger.debug("notification \(request.method) failed: \(error)")
                    }
                }
                continue
            }

            guard let id = request.id else { continue }
            if handler.isLongRunning(method: request.method, params: request.params) {
                let taskID = await registry.makeTaskID()
                let writer = self.writer
                let context = RPCContext(
                    taskID: taskID.description,
                    progress: { text in
                        writer.send(RPCNotification(
                            method: "task.progress",
                            params: .object([
                                "taskId": .string(taskID.description),
                                "message": .string(text),
                            ])
                        ))
                    },
                    isCancelled: { Task.isCancelled }
                )
                writer.send(RPCResponse(
                    id: id,
                    result: .object([
                        "taskId": .string(taskID.description),
                        "status": .string("started"),
                    ])
                ))
                let task = Task {
                    do {
                        let result = try await ToolingProgress.$handler.withValue(context.progress) {
                            try await handler.handle(
                                method: request.method, params: request.params, context: context
                            )
                        }
                        writer.send(RPCNotification(
                            method: "task.completed",
                            params: .object([
                                "taskId": .string(taskID.description),
                                "status": .string("succeeded"),
                                "result": result,
                            ])
                        ))
                    } catch is CancellationError {
                        writer.send(failure(taskID: taskID, error: .cancelled))
                    } catch {
                        let structured = error.toolingError
                        if structured.code == "operationCancelled" {
                            writer.send(failure(taskID: taskID, error: .cancelled))
                        } else {
                            writer.send(failure(
                                taskID: taskID, error: RPCErrorObject.tooling(structured)
                            ))
                        }
                    }
                }
                await registry.add(task, requestID: id, taskID: taskID)
                continue
            }

            let task = Task {
                do {
                    let result = try await handler.handle(
                        method: request.method, params: request.params, context: .silent
                    )
                    writer.send(RPCResponse(id: id, result: result))
                } catch is CancellationError {
                    writer.send(RPCResponse(id: id, error: .cancelled))
                } catch {
                    let structured = error.toolingError
                    if structured.code == "operationCancelled" {
                        writer.send(RPCResponse(id: id, error: .cancelled))
                    } else {
                        writer.send(RPCResponse(id: id, error: structured))
                    }
                }
            }
            await registry.add(task, requestID: id, taskID: id)
        }
        await registry.cancelAll()
        await registry.drain()
    }

    private func failure(taskID: RPCID, error: RPCErrorObject) -> RPCNotification {
        let encoded = (try? JSONValue(error)) ?? .object([
            "code": .int(error.code), "message": .string(error.message),
        ])
        return RPCNotification(
            method: "task.failed",
            params: .object([
                "taskId": .string(taskID.description),
                "error": encoded,
            ])
        )
    }

    private func cancelID(_ params: JSONValue?) -> RPCID? {
        guard let value = params?["id"] else { return nil }
        return try? value.decode(RPCID.self)
    }

    private func stream() -> AsyncStream<Data> {
        let input = self.input
        return AsyncStream { continuation in
            let task = Task.detached {
                var reader = RPCFrameReader()
                while !Task.isCancelled {
                    do {
                        guard let frame = try reader.next(from: input) else { break }
                        continuation.yield(frame)
                    } catch {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
