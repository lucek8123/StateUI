# StateUI Developer Tooling — Migration

This document maps current components to the native toolchain. Status values:
**implemented**, **implemented (plan + execution)**, **implemented, native
execution not verified here**, **retained**, **deprecated**.

## 1. Feature and script mapping

| Existing component | New component | Status |
| --- | --- | --- |
| `.scripts/AppKit/build-gallery-appkit.sh` | `AppKitHostDriver.planBuild` + `BundleAssembler` | implemented |
| `.scripts/AppKit/deploy.sh` | `AppKitHostDriver.planDeploy` | implemented |
| `.scripts/AppKit/test-appkit.sh` | `AppKitHostDriver.planTest` | implemented |
| `.scripts/UIKit/tools.sh` target/build/bundle | `UIKitHostDriver`, `UIKitDeviceService`, `BundleAssembler` | implemented, native execution not verified here |
| `.scripts/UIKit/build-app.sh` | `UIKitHostDriver.planBuild` | implemented, native execution not verified here |
| `.scripts/UIKit/run-app.sh` | `UIKitHostDriver.planRun` + `DebugService` | implemented, native execution not verified here |
| `.scripts/UIKit/test-uikit.sh` | `UIKitHostDriver.planTest` | implemented, native execution not verified here |
| `.scripts/UIKit/deploy.sh` | `UIKitHostDriver.planDeploy` | implemented, native execution not verified here |
| `.scripts/Android/build-swift.sh` | `AndroidHostDriver` (`AndroidSwiftBuilder`) | implemented, native execution not verified here |
| `.scripts/Android/tools.sh` | `AndroidToolchain`, `AndroidHostDriver` | implemented, native execution not verified here |
| `.scripts/Android/devices.sh` | `AndroidHostDriver.discoverDevices`, `bootEmulator` | implemented, native execution not verified here |
| `.scripts/Android/run-app.sh` | `AndroidHostDriver.planRun` + `DebugService` | implemented, native execution not verified here |
| `.scripts/Android/test-android.sh` | `AndroidHostDriver.planTest` | implemented, native execution not verified here |
| `.scripts/Android/deploy.sh` | `AndroidHostDriver.planDeploy` | implemented, native execution not verified here |
| `.scripts/WinUI/tools.ps1` projection/runtime | `WinUIHostDriver` (native SwiftPM build, projection validation, NuGet package discovery) | implemented, native execution not verified here; full projection generation remains a documented limitation |
| `.scripts/WinUI/run-app.ps1` | `WinUIHostDriver.planBuild/planRun` | implemented, native execution not verified here |
| `.scripts/WinUI/test-winui.ps1` | `WinUIHostDriver.planTest` | implemented, native execution not verified here |
| `.scripts/WinUI/deploy.ps1` | `WinUIHostDriver.planDeploy` | implemented, native execution not verified here |
| `.scripts/GTK/run-app.sh` | `GTKHostDriver.planBuild/planRun` | implemented |
| `.scripts/GTK/deploy.sh` | `GTKHostDriver.planDeploy` | implemented |
| `.scripts/GTK/test-gtk.sh` | `GTKHostDriver.planTest` | implemented |
| `.scripts/Web/swift-sdk.sh` | `WebHostDriver.resolveSwiftSDK` | implemented |
| `.scripts/Web/run-app.sh` | `WebHostDriver.planBuild/planRun` + `__serve-web` | implemented |
| `.scripts/Web/page.sh` | `WebHostDriver.layoutPage` | implemented |
| `.scripts/Web/serve.py` | `stateui __serve-web` (Swift HTTP server) | implemented |
| `.scripts/Web/browsers.sh` | `WebHostDriver.discoverBrowsers`, `openBrowser` | implemented |
| `.scripts/Web/deploy.sh` | `WebHostDriver.planDeploy` | implemented |
| `.scripts/Web/test-web.sh` | `WebHostDriver.planTest` (Node/browser runners) | implemented |
| `.scripts/Web/size-budgets.sh` | retained (release-size check) | retained |
| `.scripts/new-app.sh` | `ScaffoldService` | implemented |
| `.scripts/new-app.ps1` | `ScaffoldService` (cross-platform) | implemented |
| `.scripts/test-native.sh` | `stateui test` / per-host test plans | implemented; script retained for CI parity until host suites migrate |
| `.scripts/Marks/revision.sh` | retained (conformance bookkeeping) | retained |
| `.scripts/rasterize-images.swift` | `ImageRasterizer` invokes `sips`/`rsvg-convert` where needed | implemented |
| `.scripts/*/draw-app-icon.swift` | `BundleAssembler` icon pipeline (`sips`, `iconutil`, `actool`) | implemented |
| VS Code host selection | RPC `host/get`, `host/set` + `ConfigurationService` | implemented |
| VS Code application selection | RPC `apps/list`, `config/set` | implemented |
| VS Code Android device selection | RPC `devices/list`, `devices/boot` | implemented |
| VS Code UIKit device selection | RPC `devices/list` (UIKit) | implemented, native execution not verified here |
| VS Code browser selection | RPC `browsers/list` | implemented |
| VS Code `stateui.checkToolchain` | `ToolchainService`, CLI `doctor`, RPC `doctor` | implemented |
| VS Code debug provider | `DebugService` + thin VS Code provider | implemented |
| VS Code LSP editor mode | `LSPService` + editor restart glue | implemented |
| VS Code `stateui.deploy` | `DeployService` | implemented |
| VS Code `stateui.runTests` | `TestService` + RPC task notifications | implemented |
| VS Code `stateui.newApplicationInApps` | `ScaffoldService` | implemented |
| VS Code `stateui.newProjectGroup` | `ScaffoldService.planProjectGroup` | implemented |
| VS Code conformance rebuild commands | `stateui conformance` (retained script bridge for host suites) | retained, documented |
| VS Code `stateui.cleanIndex` | `stateui lsp clean` | implemented |

## 2. Directory migration

| Before | After |
| --- | --- |
| `lib/StateUI.VSCode/` | `editors/vscode/` |
| — | `editors/neovim/` |
| — | `tools/stateui/` |
| — | `docs/developer-tooling/` |

The VS Code extension keeps `name: stateui`, `publisher: idexus`, version
`0.7.1`, debugger type `stateui`, and command identifiers. New commands are
additive. Existing workspace state keys are read once and migrated to
`.stateui/local.json`.

## 3. CI migration

* New `tooling.yml`: builds/tests `tools/stateui` on Linux, macOS and Windows;
  builds/tests/packages the VS Code extension; runs Neovim headless tests.
* Existing host workflows keep the host conformance suites through
  `.scripts/...` where those suites are not yet expressible as app-level CLI
  tests. They are not a second build implementation for normal development.
* Core workflows gain a CLI smoke job: `stateui --version`, `stateui doctor
  --json`, `stateui apps`, `stateui hosts`, and a `--dry-run` build.
* `CONTRIBUTING.md`, `README.md`, `.vscode/tasks.json` and
  `docs/development.md` move to `stateui` commands.

## 4. Script retirement policy

Scripts are retained while they still provide:

1. host conformance suites whose runners are part of the test harness;
2. conformance mark bookkeeping (`Marks/revision.sh`);
3. release size budgets;
4. reference behavior for platform verification.

Normal CLI operations never invoke `.scripts/*`. The Android/UIKit/WinUI/GTK/Web
drivers construct native toolchain invocations directly.

## 5. Compatibility

* Old VS Code command IDs remain registered.
* `stateui` debugger type and launch schema remain accepted.
* `stateui.checkout` and `stateui.minimumRelease` settings remain.
* `STATEUI_*` environment variables continue to pass through to applications.
* Deployment layout remains `artifacts/<app>/<platform>` (WinUI adds the
  architecture directory).
* SourceKit-LSP index layout is unchanged (`.build/<host>/index-build`).
