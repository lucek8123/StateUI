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

| Host | Development platforms | Beyond build, run, test, deploy, debug and LSP | Availability probe |
| --- | --- | --- | --- |
| AppKit | macOS | - | needs the Swift toolchain and `lldb-dap`; cannot run on Linux |
| UIKit | macOS | devices: simulators and physical devices | same, plus a simulator runtime or device; Linux never runs it |
| Android | macOS, Linux | devices: emulators and physical devices | Android SDK (platform 36, build tools, platform tools), JDK 21, NDK and a Swift SDK for Android whose triple matches the NDK; `adb` for devices |
| WinUI | Windows | - | Windows toolchain, NuGet packages and existing projections |
| GTK | Linux | - | `pkg-config`, GTK 4.14 with headers, libadwaita 1.5, WebKitGTK 6.0, an SVG loader, and a Wayland or X11 session |
| Web | macOS, Linux | browsers; no devices | a Swift SDK for WebAssembly matching the toolchain's release; a browser for in-browser tests |

Every host needs a swift.org Swift 6.4 or newer; `lldb-dap` backs debugging for
the native hosts; Git is what lists and clones release branches; Node 20 is what
the editor and Web test builds use. `stateui doctor --json` names each component,
which hosts need it, whether its absence blocks the host, and what to install.

## What this Linux machine actually runs

`stateui hosts --json` on the checkout here reports:

* `gtk`: ready - the probe passed, so a GTK head can be built and run here;
* `web`: ready - a Swift SDK for WebAssembly matching the toolchain's release
  (`swift-6.4.2-RELEASE_wasm`) is installed, so Web builds compile and serve here. It
  reported `toolchain-missing` earlier in this work, before that SDK was installed;
* `android`: `toolchain-missing` - no SDK, NDK, JDK or matching Swift SDK;
* `appkit`, `uikit`, `winui`: `unsupported-os`.

"ready" means the toolchain probe passed. It is not a claim that every
application builds, runs, tests or deploys.

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
build directory, where both editors read them after `debug/prepare` finishes.
