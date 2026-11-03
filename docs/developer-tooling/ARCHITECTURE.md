# StateUI Developer Tooling — Architecture

## 1. Decision summary

StateUI development operations live in one native Swift executable,
`stateui`, built by the separate SwiftPM package at `tools/stateui/`. The root
`Package.swift` remains the dependency-free StateUI library manifest. VS Code
and Neovim are thin clients of the executable over a versioned JSON-RPC 2.0
stdio protocol.

The executable owns:

* project and application discovery;
* host selection and availability;
* toolchain and SDK discovery;
* device and browser discovery;
* build, test, run, deploy and debug planning;
* execution of native toolchain commands;
* SourceKit-LSP project configuration;
* application scaffolding;
* persistent StateUI configuration.

Editors own only editor lifecycle and presentation: quick picks, status bars,
terminals, output channels, language-server processes and debugger sessions.

## 2. Why a separate package

SwiftPM reads a package manifest only from the checkout root. The root manifest
is published as the StateUI library and must stay dependency-free. The tooling
therefore lives in `tools/stateui/` with its own manifest and one product:

```
tools/stateui/
  Package.swift
  Sources/StateUITooling/     implementation library (linked in)
  Sources/stateui/            executable entry point
  Tests/StateUIToolingTests/
```

`StateUITooling` is an implementation detail. Only the `stateui` executable is
distributed. No CLI dependency enters the public library.

## 3. Module responsibilities

### Domain (`Sources/StateUITooling/Domain`)

Explicit value types, all `Codable` and `Sendable` where practical:

* `HostID`, `HostDescriptor`, `HostCapabilities`, `HostAvailability`;
* `Application`, `ApplicationHead`;
* `Device`, `Browser`;
* `BuildConfiguration`, `ProjectPlatform`;
* `ToolchainRequirement`, `ToolchainFinding`, `ToolchainReport`;
* `BuildRequest`, `TestRequest`, `RunRequest`, `DeployRequest`, `DebugRequest`;
* `ProcessInvocation`, `PlanStep`, `BuildPlan`, `TestPlan`, `RunPlan`,
  `DeployPlan`, `DebugPlan`;
* `ProjectInfo`, `ProjectContext`, `StateUIConfiguration`;
* `ToolingError`.

Raw host names are parsed once at the boundary into `HostID`. Services never
branch on strings.

### Application services (`Sources/StateUITooling/Application`)

| Service | Responsibility |
| --- | --- |
| `ProjectDiscovery` | Find a checkout, project group or application from an explicit path or upward from the working directory. |
| `ApplicationResolver` | Enumerate `apps/*` and a workspace-root application; detect host heads and the checkout named by `Package.swift`. |
| `Tooling` | The one object the CLI and the RPC both hold: executor, environment, platform, registry, discovery, configuration, toolchain, plan executor and working directory. `resolve` merges an explicit request with the checkout's selection; `HostRegistry` resolves a host to its driver. |
| `ConfigurationService` | Load/validate/save `.stateui/config.json` and `.stateui/local.json`. |
| `ProjectService` | Select and persist host, application, configuration, device and browser, and list a host's availability. |
| `ToolchainService` | Probe native tools and produce per-host findings. |
| `BuildService` | Ask the host driver for a `BuildPlan`, then execute or dry-run it. |
| `TestService` | Plan and execute host and application suites. |
| `RunService` | Plan and execute build plus launch; detached runs, and a fact file for a launch held for a debugger. |
| `DeployService` | Plan and execute release layout into `artifacts/<app>/<platform>`. |
| `DebugService` | Build and launch preparation, structured `DebugPlan` generation, and the facts file a debugger reads. |
| `SizeService` | Weigh each Web module against the budget the repository records. |
| `WebServerService` | Give up the page a Web run left serving: read the process the site's `server.json` names, stop it, and remove the facts. |
| `LSPService` | Resolve the host's SourceKit environment, build the host's index store, write the folder's editor settings, and remove an index. |
| `ScaffoldService` | Copy the canonical `apps/HelloWorld` model, rename it, and rewrite the checkout path. |
| `GroupService`, `GroupLayout` | List the releases a remote offers, apply a version floor, and lay out a group's clones, workspace, settings and debug configurations. `GroupLayout` is pure, so the rules are tested without a repository. |

The CLI and RPC server call these same services. Neither contains host logic.

### Host drivers (`Sources/StateUITooling/Hosts`)

`HostDriver` is a protocol with a `HostID`, capabilities, availability,
toolchain check, device/browser discovery, and planning methods for build,
test, run, deploy and debug. Each driver returns plans; it does not execute.

Drivers:

* `AppKitHostDriver`
* `UIKitHostDriver`
* `AndroidHostDriver`
* `WinUIHostDriver`
* `GTKHostDriver`
* `WebHostDriver`

`HostRegistry` resolves the driver. Host-specific behavior is not scattered
through services.

Unsupported operations return `ToolingError.unsupportedHost` rather than a
placeholder success. Capability (what the host can do) is separate from
availability (whether this machine can do it now).

### Infrastructure (`Sources/StateUITooling/Infrastructure`)

* `ProcessExecutor` / `RealProcessExecutor`: async `Process` execution with
  separate arguments, explicit cwd and environment overrides, streamed output,
  exit codes, cancellation and executable-not-found errors.
* `FileSystem`: path helpers and safe recursive copy/remove.
* `Platform`: one OS/architecture detection point.
* `Logging`: stderr diagnostics with redaction.
* `CommandLine`: a small deterministic parser (no shell interpolation).
* `HTTP`: a static Web server used by the Web host (`__serve-web`). Its facts file names
  the port, the URL and the process serving, so a later `stop` can give the page up.
* `JSON`: shared encoder/decoder settings.

### Protocol (`Sources/StateUITooling/Protocol`)

Versioned JSON-RPC 2.0 over stdio with `Content-Length` framing. Requests,
responses, errors, progress notifications and cancellation. stdout carries
only protocol frames; logs go to stderr.

## 4. Planning and execution

Every host driver produces inspectable plans:

```swift
struct ProcessInvocation {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
    let label: String
    let captureOutput: Bool
    let mode: ExecutionMode
    let allowFailure: Bool
}
```

An executable is an absolute path or a name resolved from the environment's
`PATH`; a name is never looked for beside the working directory. `allowFailure`
marks a step whose non-zero exit is expected - stopping a head that is not
running, say - so it does not fail the plan.

`stateui build Gallery --dry-run` prints the executable, arguments, working
directory and environment overrides without running anything. The same plan is
executed by `BuildService` or sent to an editor as a debug pre-launch step.

This separation gives unit tests without SDKs, consistent logging, cancellation
and actionable failures.

## 5. Configuration

`.stateui/config.json` is shared project configuration. `.stateui/local.json`
is developer-specific and gitignored. Both use `schemaVersion: 1`.

```json
{
  "schemaVersion": 1,
  "defaultHost": "gtk",
  "defaultApplication": "Gallery",
  "configuration": "debug",
  "devices": { "android": "emulator-5554", "uikit": "UDID" },
  "browsers": { "web": "google-chrome.desktop" },
  "toolchains": { "swift": "/opt/swift/usr/bin/swift" }
}
```

Precedence: explicit CLI/RPC argument, local configuration, shared
configuration, environment, discovery default. Validation rejects unknown
schema versions, invalid host names and invalid configurations. Selections are
written to `local.json` so shared configuration does not acquire developer
paths.

Nothing migrates an editor's old keys into the checkout: the extension reads the
selection from the tool through `config/get` and writes it through `config/set`,
which lands in `local.json`. The settings file the tool writes carries only keys
an editor actually reads - VS Code's own `search.exclude`, and
`stateui.minimumRelease` in a group folder whose releases name complete versions.

## 6. Error and logging model

`ToolingError` carries:

* stable `code` (`projectNotFound`, `applicationNotFound`, `hostUnavailable`,
  `toolchainMissing`, `invalidConfiguration`, `buildFailed`, `testFailed`,
  `deviceNotFound`, `browserNotFound`, `deploymentFailed`,
  `debuggerUnavailable`, `operationCancelled`, `protocolError`, …);
* human-readable `message`;
* `context` dictionary;
* optional `suggestion`.

A CLI failure goes to stderr as `stateui: <code>: <message> [context]` with the
suggestion beneath it, and the exit code says what kind of failure it was: `2` for
a bad argument or a configuration the checkout cannot parse, `1` for everything
else. `--json` prints the result on stdout, never the error. RPC returns a
JSON-RPC error object whose `data` is the structured error, and refuses a method
it does not know under the same shape rather than JSON-RPC's `-32601`, so a client
reads one shape for every refusal.

All diagnostics go to stderr. Credentials and sensitive environment values are
never dumped; environment logging is limited to keys explicitly set by a plan.

## 7. RPC protocol

`stateui rpc --stdio` speaks JSON-RPC 2.0 with `Content-Length` framing, the LSP
convention: lengths are counted in bytes, stdout carries only frames, and logs go
to stderr. Protocol version `1`, reported under `serverInfo.protocolVersion`; a
client speaking another version is refused before any other work. Every method is
documented in `PROTOCOL.md`.

A request that runs something long - `build`, `test`, `run`, `deploy`,
`debug/prepare`, `size/budgets`, `lsp/configure`, `group/create` - answers at once
with `{ taskId, status: "started" }` and reports its work by notification:
`task.progress` with a line of the toolchain's output, then `task.completed` with
the result or `task.failed` with the structured error. Asked with `dryRun: true`
the same methods answer with their plan immediately, because planning runs
nothing. A task is registered under both the id of the request that started it and
its own task id, so `$/cancelRequest` names either; a cancelled build terminates
its child with SIGTERM, then SIGKILL. Tasks run concurrently, an `exit`
notification or a closed stdin cancels whatever is still working, and a frame that
is not JSON is answered as a parse error without ending the session.

## 8. Editor architecture

### VS Code (`editors/vscode`)

* `Sources/resolve.ts`: finds the binary - `stateui.executablePath`,
  `STATEUI_BIN`, the workspace checkout's `tools/stateui/.build/{release,debug}/stateui`,
  then `PATH`, with the Windows suffix handled.
* `Sources/rpc.ts` and `Sources/backend.ts`: one `stateui rpc --stdio` child for
  the workspace, `Content-Length` framing, request correlation, task
  notifications, cancellation by request id or task id, and a child that dies
  being reported rather than retried blindly.
* `Sources/extension.ts`: the five selection pickers, the three status bar items,
  build, run, tests, deploy, both conformance families, index clean, toolchain
  doctor, scaffolding and project groups - each through the session, the long ones
  as tasks. The manifest and the registered commands are checked against each other
  in both directions by the tests.
* `Sources/debug.ts`: `debug/plan` translated into an `lldb-dap` or `chrome`
  configuration, then `debug/prepare` as a task, and the host's facts file read
  back to fill the pid, serial or URL the plan could not name.
* `Sources/reinstall.ts`: packs the checkout's extension and installs the VSIX over
  the running one.
* A task provider of type `stateui`, whose `kill()` cancels the task the server named
  and, for a run on the Web host, gives up the served page with `web/stop` - the run
  answers `started` while a detached process keeps the port listening.
* Packaging is a normal VSIX built with npm and vsce. The binary is installed
  separately and is not bundled six times.

### Neovim (`editors/neovim`)

* Lua modules: `config`, `client`, `commands`, `dap`, `frames`, `init`, `lsp`,
  `select`, `status`, `ui`; `plugin/stateui.vim` registers `:StateUI` and starts
  nothing.
* `client.lua` keeps the child with `jobstart` and `chansend`, and `frames.lua`
  reads `Content-Length` framing byte-exactly: a frame cut short waits for its
  tail, and a header block naming no length is dropped and counted rather than
  decoded.
* One command tree, `:StateUI <subcommand>`; a list the tool answers - hosts,
  applications, devices, browsers - is offered as a choice rather than printed, each entry
  carrying the tool's own words beside the name the choice is made under. A choice opens
  Telescope's picker when Telescope is installed and Neovim's prompt when it is not, and
  giving a choice up picks nothing rather than acting on a guess. `:StateUI menu` lists the
  commands with their descriptions through that picker and runs the one chosen.
  `vim.ui.input` still asks for a new application's name. There is no Telescope dependency:
  the picker is built from Telescope's own modules when it is present, and the plugin's
  fallback is Neovim's prompt.
* Telescope 0.1.x consumes `attach_mappings`, not a `mappings` field, so `<CR>` is bound
  inside `attach_mappings` and scoped to this picker; nothing a person mapped elsewhere is
  rewritten by it.
* Answers that are not a choice are laid out as words by `ui.describe`: keys beside the
  values they name, lists one line each, nested parts indented under the key that holds
  them. No brace, quote or comma reaches the window.
* Tasks stream progress into an output window - a float over the editor by default,
  `q` or `<Esc>` giving it up, `:StateUI output` showing it again - and put the captured
  stream in the quickfix list; a streamed window opens without the focus, a window the
  user asked to read takes it. `:StateUI cancel` gives up the operation by task id, and a
  cancelled task is reported as given up on; with nothing in flight on the Web host it
  gives up the served page through `web/stop`.
* `status.lua` keeps the selection the tool answers in globals and renders it as one
  short string, so any statusline can show the host and application without the
  plugin deciding either.
* SourceKit-LSP is started with the environment the binary resolves for the host
  in use; the server the plugin started is looked up by id with uninitialized
  servers included, so an unchanged configuration costs no second server.
* nvim-dap is optional: a `DebugPlan` becomes a nvim-dap configuration, and
  `dap.install()` hands the plans to nvim-dap's own pickers when it is installed.
* Tested on Neovim 0.12.6. No older version is claimed: the plugin asks
  `vim.lsp.get_clients` by id with uninitialized servers included.

## 9. LSP responsibilities

The binary does not implement a language server. `lsp/environment` answers what a
server needs for the host in use:

* `STATEUI_HOST`, the variable a head reads to know which host it was built for;
* the host's index store - `.build/<host>/index-build`, `.build/index-build` when
  no host is chosen;
* the Swift SDK id and triple where a host compiles through one (Android, Web),
  and the simulator SDK where UIKit names one;
* `notes`, saying what was not found rather than guessing it.

`lsp/configure` fills that store: the host's head is built with an index SourceKit
reads while the editor works. It also writes the folder's `.vscode/settings.json`
- only `search.exclude`, keeping every key that was already there. Which host and
application are being indexed is the checkout's own selection in
`.stateui/config.json`, so nothing naming them is written into a settings file no
code reads. `lsp/clean` removes a store, one host's or every host's, so the host
indexes again.

Neovim starts SourceKit-LSP itself: the host's variables are set on the editor
before the server starts, the store is passed as `--scratch-path`, and a server
standing on an unchanged answer is left alone. VS Code's Swift extension owns its
own server and index, so the extension only asks the binary to index a host or
clean every store. Neither editor reconstructs SDK settings.

## 10. Debugger responsibilities

The binary produces a `DebugPlan`. This checkout's GTK plan for `Gallery`, as
`stateui debug plan Gallery --host gtk --json` answers, with the paths shortened
to fit and one step's arguments left out:

```json
{
  "adapter": "lldb-dap",
  "request": "launch",
  "host": "gtk",
  "application": "Gallery",
  "configuration": "debug",
  "name": "StateUI: Gallery (GTK)",
  "program": "apps/Gallery/.build/gtk/out/Products/Debug-linux-x86_64/GalleryGTK",
  "arguments": [],
  "workingDirectory": "apps/Gallery/",
  "environment": { "STATEUI_HOST": "gtk" },
  "build": {
    "steps": [
      { "label": "Stop a running GalleryGTK", "executable": "…/GalleryGTK", "arguments": [] },
      { "label": "Build GalleryGTK (debug)", "executable": "…/swift", "arguments": ["…"] }
    ],
    "actions": [],
    "postSteps": []
  },
  "preLaunch": [],
  "notes": ["The debugger is the application's parent, which Ubuntu's ptrace scope permits."]
}
```

`build` is the whole preparation, so a debugger launches the artifact a normal
build makes rather than something built differently. `pid`, `url`, `webRoot`,
`runtimeExecutable` and `factsFile` appear when the host names them; a plan that
cannot name a pid or a URL yet carries `factsFile`, the directory
`debug/prepare` writes `debugger.json` into, where the editor reads back the pid,
the device or simulator serial, the served URL and port, and the symbols to load.

Host distinctions are explicit:

* AppKit, GTK, WinUI: `lldb-dap` launch.
* UIKit: `lldb-dap` attach by pid, or device attach commands.
* Android: `lldb-dap` attach through `remote-android`, NDK `lldb-server`.
* Web: browser JavaScript debugger (`chrome` adapter), not LLDB.

Editors own debugger lifecycle. The binary owns preparation and configuration.

## 11. Distribution

The tool is built from source, per machine:

```sh
swift build --package-path tools/stateui    # .build/debug/stateui, or --configuration release
```

Nothing in this repository produces platform tarballs or checksums, so no
downloadable binary is claimed here. The VS Code extension packs itself with npm
and vsce into `artifacts/stateui-<version>.vsix`; the binary is installed
separately and is not bundled six times.

Both editors resolve the binary themselves - an explicit setting, `STATEUI_BIN`,
the checkout's own build, then `PATH` - and check the version and protocol the
handshake names before asking anything else. A binary too old to speak protocol
`1` is reported with what to do about it; neither editor downloads or replaces a
binary without the user asking.

## 12. Testing strategy

* Swift tests (`swift test --package-path tools/stateui`): host name parsing,
  configuration round-trip and validation, discovery against real fixture
  checkouts, toolchain version parsing, plan generation for every host, LSP
  environment and index cleanup, the group rules - release ordering by number, a
  version floor, the branch a remote ref names, the settings and debug
  configurations a group writes, git resolved from `PATH` - the options the
  commands read being options the parser accepts, error encoding, process
  execution against temporary fake executables (success, non-zero exit, missing
  executable, streamed output, cancellation, environment, working directory), and
  the RPC server's framing, correlation, task notifications, cancellation,
  refusals and the release floor it applies. Host plans are read as plans on Linux -
  GTK's desktop entry, WinUI's stubbed `taskkill` path, AppKit's bundle naming the
  icon it drew when the icon tools stand, and naming nothing when they do not - but
  a plan being readable is not a bundle being built.
* VS Code: `npm run compile && npm test` runs 126 assertions without an extension
  host - manifest and registration checked in both directions, binary resolution,
  debug-plan translation, facts read back, the session framing and following
  tasks, reinstall paths, and the release floor forwarded to the binary.
  `Tests/run.integration.ts` targets a suite no file builds; it stays as the
  documented environment-dependent runner.
* Neovim: four headless checks from the repository root - `smoke.lua` (command
  registration and byte-exact framing), `tasks.lua` (the task lifecycle against a
  fake peer), `rpc.lua` (the plugin against the real binary, both refusals, and a
  command warming the process), `lsp.lua` (SourceKit-LSP standing, answering its
  handshake, carrying the host's environment, costing no second server).
* Platform behavior is claimed only where the host runs. Linux claims GTK
  availability and the CLI flows exercised here; macOS, Windows and Android
  behavior is not claimed at all, because nothing on this machine runs them. A
  check that cannot run is recorded as not run, never as passed.
