# StateUI Host Driver Reference

Each host implements `HostDriver`: identity, capabilities, availability, toolchain
check, device or browser discovery, and planning for build, test, run, deploy,
debug and the SourceKit-LSP environment. A driver returns plans; it does not
execute them. `HostRegistry` picks the driver, so host-specific behavior lives in
one place rather than scattered through the services.

Capability (what the host can do at all) and availability (whether this machine
can do it now) are separate answers. A host that cannot run on this operating
system is `unsupported-os`; a host whose tools are absent is `toolchain-missing`.
An operation a host does not support refuses with `unsupportedHost` instead of
returning a placeholder success.

`devices` lists what a head can run on; `boot` starts a stopped one - an Android
AVD - and answers with it once it is ready. A test suite's plan may carry
`checks`, the proofs it owes after its steps: the public API records, the
conformance exports, the Android test listing. A plan may also carry `cleanup`,
steps that run whether the suite passed or failed, and `onFailure`, the
diagnostics a failed suite prints.

| Host | Development platforms | Beyond build, run, test, deploy, debug and LSP | Availability probe |
| --- | --- | --- | --- |
| AppKit | macOS | - | needs the Swift toolchain and `lldb-dap`; cannot run on Linux |
| UIKit | macOS | devices: simulators and physical devices | same, plus a simulator runtime or device; Linux never runs it |
| Android | macOS, Linux | devices: emulators and physical devices; boot: AVDs | Android SDK (platform 36, build tools, platform tools), JDK 21, NDK and a Swift SDK for Android whose triple matches the NDK; `adb` for devices |
| WinUI | Windows | - | Windows toolchain, NuGet packages and existing projections |
| GTK | Linux | - | `pkg-config`, GTK 4.14 with headers, libadwaita 1.5, WebKitGTK 6.0, an SVG loader, and a Wayland or X11 session |
| Web | macOS, Linux | browsers; no devices | a Swift SDK for WebAssembly matching the toolchain's release; a browser for in-browser tests |

Every host needs a swift.org Swift 6.4 or newer; `lldb-dap` backs debugging for
the native hosts; Git is what lists and clones release branches; Node 20 is what
Web test builds use. `stateui doctor --json` names each component, which hosts
need it, whether its absence blocks the host, and what to install.

`stateui hosts --json` reports what the current machine can do now. `ready`
means the toolchain probe passed; it is not a claim that every application
builds, runs, tests or deploys.

## WinUI limitation

Full WinUI projection generation is not performed by the native tool. The driver
discovers the NuGet packages a projection is built against and validates
projections that already exist; where none exist it refuses and names what has to
be generated. `lib/Backends/WebView.WinUI/SelfContained.ps1` remains the script
that does it on Windows; the tool does not invoke `.scripts/*` in normal
operation.

## Debug adapters per host

| Host | Adapter and request |
| --- | --- |
| AppKit, GTK, WinUI | `lldb-dap`, launch |
| UIKit | `lldb-dap`, attach by pid, or device attach commands |
| Android | `lldb-dap` attach through `remote-android`, with the NDK's `lldb-server` |
| Web | the browser JavaScript debugger, not LLDB |

Preparation writes the facts a plan cannot name - the pid, the simulator or
device serial, the served URL and port - into `debugger.json` under the host's
build directory, where a client reads them after `debug/prepare` finishes.
