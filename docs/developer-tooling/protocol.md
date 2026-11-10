# StateUI JSON-RPC Protocol

`stateui rpc --stdio` speaks JSON-RPC 2.0 over stdio with `Content-Length`
framing, the LSP convention: a header block, a blank line, then a body whose
length is counted in **bytes**. stdout carries frames only; every diagnostic the
tool writes goes to stderr. Protocol version `1`, reported by `initialize` under
`serverInfo.protocolVersion` and checked by a client before it asks anything
else.

A client that speaks a version the server does not is refused before any other
work: `protocolVersionMismatch`, with the client's and the server's versions in
`context`.

## Framing

```
Content-Length: 82\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"version","params":{}}
```

A frame cut short stays buffered until its tail arrives. A header block naming
no `Content-Length` is not a frame: the bytes are dropped rather than decoded.

## Lifecycle

| Message | Answer |
| --- | --- |
| `initialize` with `protocolVersion` | `serverInfo` (`name`, `version`, `protocolVersion`), `capabilities` (`build`, `test`, `run`, `deploy`, `debug`, `devices`, `browsers`, `lsp`, `cancellation`, `size`, `scaffold`, `groups`), `hosts` (`id`, `label`, `platforms`), `applications` |
| `shutdown` | `null` |
| `exit` notification | ends the loop; in-flight tasks are cancelled, so the tool's child never outlives the client |
| `$/cancelRequest` notification with `id` | cancels the request or task that id names; nothing answers it |
| any other notification | handled and unanswered |

A request with no `id` is a notification: it is handled and never answered.
Closing stdin ends the session; a task still working at that point is given up
on rather than left running.

## Refusals

Every tooling failure arrives as a JSON-RPC error under `-32000` whose `data` is
the structured error - `code`, `message`, `context`, `suggestion`. A method the
server does not know is refused the same way, with `data.code` `protocolError`,
rather than JSON-RPC's `-32601`: clients read one shape for every refusal,
and the suggestion tells the user what to do.

| Code | Meaning |
| --- | --- |
| `-32700` | a frame that is not JSON. The server answers the parse error and keeps serving |
| `-32000` | a tooling refusal: `protocolError`, `projectNotFound`, `applicationNotFound`, `hostUnavailable`, `toolchainMissing`, `invalidConfiguration`, `invalidArguments`, `commandFailed`, `executableNotFound`, `processFailed`, `deviceNotFound`, `browserNotFound`, `deploymentFailed`, `debuggerUnavailable`, `protocolVersionMismatch`, `operationCancelled`, `notServing`, `serverFailed`, … |
| `-32800` | a request or task the client cancelled |

## Immediate answers and tasks

`build`, `test`, `run`, `deploy`, `debug/prepare`, `size/budgets`,
`lsp/configure` and `group/create` are long-running: they answer at once with
`{"taskId": "task-1", "status": "started"}` and report their work by
notification. Any of them asked with `dryRun: true` answers with its plan
immediately, because planning runs nothing.

| Notification | Payload |
| --- | --- |
| `task.progress` | `taskId`, `message` - one line of the toolchain's own output |
| `task.completed` | `taskId`, `status: "succeeded"`, `result` |
| `task.failed` | `taskId`, `status: "failed"`, `error` - the same `-32000` / `-32800` shape a direct request gets |

A task is registered under both the id of the request that started it and its own
task id, so `$/cancelRequest` names either. A task cancelled mid-build terminates
the child with SIGTERM, then SIGKILL.

## Methods

Params carry the same names the CLI's options do, plus `project` (a checkout,
application or group path) wherever the CLI takes `--project`.

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `protocolVersion` | see Lifecycle |
| `shutdown`, `exit` | - | `null`, or nothing |
| `version` | - | `name`, `version`, `protocolVersion` |
| `doctor` | `host` or `hosts` | the toolchain report: each finding, and `ready` when no blocking finding is missing |
| `project` | `project` | kind, root, checkout, applications, configuration directory |
| `apps` | `project` | each application's name, directory, available hosts |
| `hosts` | `project` | each host with `id`, `label`, `detail`, `platforms`, `capabilities`, `indexDirectory`, `status`, `reason`, `toolchainReady`, `deviceAvailable` |
| `devices` | `host`, and `boot` with `avd` (or `device`) | a host's devices: `id`, `name`, `kind`, `state`; with `boot: true`, the AVD started and ready |
| `browsers` | - | the Web host's browsers |
| `config/get` | `project` | `.stateui/config.json` merged with the local file |
| `config/set` | `host`, `application`, `configuration`, `device` + `deviceHost`, `browser` | the merged configuration, after writing the local file. An application the checkout does not answer is refused as `applicationNotFound`, naming what stands here, so a client's typed name cannot select something nothing builds. |
| `build` | `application`, `host`, `configuration`, `device`, `browser`, `architecture`, `extraArguments`, `dryRun` | a `BuildPlan`, or an `ExecutionOutcome` |
| `test` | `application`, `host`, `configuration`, `device`, `boot`, `testAPK`, `filter`, `suite`, `conformance`, `allAvailableHosts`, `inBrowser`, `buildOnly`, `updateExports`, `staleOnly`, `dryRun` | a `TestPlan`, a list of `HostTestPlan`s, or an outcome/`TestReport`. The outcome carries the suite's `checks`: the API records, the conformance exports, the Android listing. |
| `run` | `application`, `host`, `configuration`, `device`, `boot`, `browser`, `port`, `detach`, `prepare`, `noBuild`, `dryRun` | `{build, run}` plans, or an outcome |
| `deploy` | `application`, `host`, `configuration`, `destination`, `architecture`, `dryRun` | a `DeployPlan`, or an outcome |
| `size/budgets` | `host`, `configuration` | each Web module weighed against the budget the repository records |
| `debug/plan` | `application`, `host`, `configuration`, `device`, `browser` | a `DebugPlan`: `adapter`, `request`, `program`, `arguments`, `workingDirectory`, `environment`, `pid`, `initCommands`, `attachCommands`, `url`, `webRoot`, `factsFile`, `build`, `preLaunch` |
| `debug/prepare` | the same | the outcome of preparing, which writes the host's `debugger.json` facts file |
| `web/stop` | `project`, `application` | gives up the page a Web run left serving: `{stopped, url, port, pid}`. The server is a detached process named in the site's `server.json`; nothing serving is refused as `notServing`. |
| `lsp/environment` | `host` | `host`, `environment` (`STATEUI_HOST`), `scratchPath`, `swiftSDK`, `sdk`, `triple`, `notes` |
| `lsp/configure` | `host`, `dryRun` | the outcome of indexing the host's store, plus the folder's `.vscode/settings.json` |
| `lsp/clean` | `host` or `all`, `dryRun` | which index directories were removed, which were already absent |
| `new` | `name`, `appsDirectory` | the application created and the directory it sits in |
| `group/releases` | `checkout`, `minimum` | the releases the remote offers, oldest first, at or above the floor |
| `group/create` | `name`, `releases`, `destination`, `checkout`, `minimum`, `dryRun` | the outcome of laying out the group |

## Client contract

A client keeps one `stateui rpc --stdio` child for a workspace and asks every
question through it. It forwards `task.progress` to whatever it shows the user,
sends `$/cancelRequest` with the request or task id once the server has named
one, and treats a closed child as a failure to report rather than something to
retry blindly. It checks `protocolVersion` during `initialize` and refuses a
server that speaks another version. A client does not compare release versions:
the floor is forwarded to the binary, which owns what a version means.
