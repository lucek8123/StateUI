# StateUI CLI Reference

`stateui` is built with SwiftPM from `tools/stateui/`:

```sh
swift build --package-path tools/stateui      # tools/stateui/.build/debug/stateui
swift test  --package-path tools/stateui
```

`stateui` with no argument prints the usage; `stateui help` prints the same and
`stateui --version` prints the tool and protocol versions. Every command takes
`--json` for machine-readable output, and `--quiet` / `--verbose` for how much
the tool says about itself. Diagnostics always go to stderr.

## Options

Value options: `--project PATH`, `--host H|all-available`,
`--configuration debug|release`, `--application NAME`, `--device ID`,
`--device-host H`, `--browser ID`, `--port N`, `--filter NAMES`,
`--suite native|foundation|host`, `--architecture ARCH`, `--destination PATH`,
`--apps-dir PATH`, `--checkout PATH`, `--minimum V`, `--name NAME`,
`--transport stdio`.

Flags: `--json`, `--quiet`, `--verbose`, `--help`, `--dry-run`, `--detach`,
`--prepare`, `--no-build`, `--build-only`, `--in-browser`, `--conformance`,
`--update-exports`, `--stale`, `--all`, `--stdio`.

An option that no command reads is refused rather than accepted and ignored, and
`--help` beside any command prints the usage instead of running the command.
Anything after `--` is passed to the toolchain beside the application's own name.

## Commands

| Command | What it does |
| --- | --- |
| `version` | tool name, version, protocol version |
| `doctor [--host H]` | probe every host's toolchain; a report that is not ready exits `1` |
| `project` \| `info` | describe the checkout, application or group the command was asked in |
| `apps [list \| info NAME]` | list applications, or name one: its directory, manifest and host heads |
| `hosts [list \| info H]` | list hosts with availability, or name one |
| `host [list \| get \| set H]` | read or select the default host |
| `config [get \| list \| set]` | read or write the checkout's selection: host, application, configuration, device and its host, browser. An application no discovery answers is refused with the names that stand here. |
| `devices --host H` | list a host's devices |
| `browsers` | list the Web host's browsers |
| `build [--application N] [--host H] [--configuration C] [--device ID] [--browser ID] [--architecture ARCH] [--dry-run] [extra...]` | build a host's head |
| `test [--application N] [--host H\|all-available] [--configuration C] [--device ID] [--filter T] [--suite S] [--conformance] [--in-browser] [--build-only] [--update-exports] [--stale] [--dry-run]` | run a host's suites, or its conformance families |
| `run [--application N] [--host H] [--configuration C] [--device ID] [--browser ID] [--port N] [--detach] [--prepare] [--no-build] [--dry-run]` | build, then run; `--prepare` holds the launch for a debugger and writes the host's facts file. A Web run detaches its server and writes `server.json` beside the site, naming the port and the process that serves it. |
| `deploy [--application N] [--host H] [--configuration C] [--destination PATH] [--architecture ARCH] [--dry-run]` | lay a release build out |
| `stop [NAME] [--host web] [--project PATH] [--application N]` | give up the page a Web run left serving: the detached server named in the site's `server.json` is stopped and its facts removed. Naming another host is refused, and a checkout serving no page is refused as `notServing`. |
| `size budgets --host web` | build each Web module for release, gzip it the way a page fetches it, and weigh it against the recorded budget |
| `new NAME [--apps-dir PATH]` | scaffold an application from `apps/HelloWorld` |
| `group releases [--minimum V] [--checkout PATH]` | the releases the checkout's remote offers, oldest first; `V` is a version floor |
| `group create NAME [release...] [--minimum V] [--destination PATH] [--checkout PATH] [--dry-run]` | clone one release per folder and write the workspace, ignore list, settings and debug configurations |
| `lsp environment [--host H]` | the variables, index store and Swift SDK/triple SourceKit-LSP needs for a host |
| `lsp configure [--host H] [--dry-run]` | fill the host's index store and write the folder's `.vscode/settings.json` |
| `lsp clean [--host H \| --all] [--dry-run]` | remove an index, so the host indexes again |
| `debug plan [--application N] [--host H] [--configuration C] [--device ID] [--browser ID]` | print the adapter, program, arguments, environment, attach commands and the build that prepares them |
| `debug prepare [--application N] [--host H] [--configuration C] [--device ID] [--browser ID] [--dry-run]` | build and launch what the plan names, and write `debugger.json` where the debugger reads it |
| `rpc --stdio` | JSON-RPC 2.0 server over stdio; see `protocol.md` |

## Conformance

`stateui test --conformance --host H` runs one host's conformance families
instead of its own suite. `--filter Family` narrows it to one family (`Button`,
`TextField`, ...); `--stale` runs only families whose verdicts stand at another
revision; `--update-exports` writes them.

`stateui test --conformance --host all-available` runs every host this machine
offers, one default simulator, device or browser each, one after another. It
never stops at the first failure: it ends with each host's passed/failed counts
and the failed tests, and exits `1` if any failed. On Web the conformance
families run in a browser; on the other hosts they run in the host's own suite.

Without `--conformance`, `--host all-available` runs each host's default suite,
one default device or browser each - the suites the `.scripts/<Host>/test-*`
scripts run.

## Host notes

### Android

`stateui doctor --host android` checks the Android SDK (platform 36, build-tools
and platform-tools), NDK r30 or newer, JDK 21, and the Swift SDK for Android of
the toolchain's release line; a patch release of the same minor is accepted (for
example the 6.4.1 SDK with the 6.4.0 compiler). On Windows - and any host without
AppKit - `resvg` must be on `PATH`; the CLI draws the application's SVGs and
adaptive icon with it.

`devices --host android` lists attached devices and emulators, a running
emulator by its AVD name, and AVDs that are stopped. `build`, `run`, `test` and
`deploy` take `--device`; with one device attached it is implied, and
`--architecture x86_64|arm64-v8a` builds for a device that is not attached. The
CLI fetches Gradle 9.4.1 on first use and copies the Swift runtime libraries
the head needs into the APK. The older `.scripts/Android` shell path is not
needed.

## Output and exit codes

`--json` writes the encoded answer to stdout. A refusal is written to stderr as

```
stateui: projectNotFound: /path has no release 0.4.0 at or above 0.5.0. [releases=0.5.0, 1.2.0]
  Pick one of the releases the remote has.
```

and the exit code says which kind of failure it was: `2` for a bad argument or a
configuration the checkout cannot parse, `1` for anything else - an unavailable
host, a missing tool, a toolchain that exited non-zero, a cancelled operation.

## Hidden helpers

`__serve-web`, `__web-test`, `__web-browser-test`, `__android-logcat`,
`__android-debug` and `__uikit-debug` are invoked by generated plans. They are
not part of the public surface, and clients do not call them.
