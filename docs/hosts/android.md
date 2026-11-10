# Android Views host

The Android Views host renders a StateUI application with Android views. It is
Swift, in the application's own process, beside the application module and the
library: it applies the typed sparse patches of the
[host contract](../internals/host-contract.md) directly and calls the views through JNI.

It presents StateUI's controls, arrangements and pages over the runtime every
host shares - the [platform contract](../platform-contract.md#control-creation) says
which, member by member - and shows any other control's name in red where the control
belongs, so a gap is visible rather than silent.

```text
lib/StateUI/StateUI.Android/
  Sources/StateUIAndroid/    the host: its runtime, elements, registrations, layout and JNI
  Sources/CStateUIAndroid/   the NDK's C surface: JNI, the looper, the log
  Java/stateui/android/      the Java layer: the activity, the views and view groups the host makes, the frame callback and the listeners
  Tests/                     the host's suite, run in a test APK on a device
.scripts/Android/
  build-swift.sh             the older shell path (macOS); the stateui CLI drives build, run, deploy and test
  draw-app-icon.swift        the older launcher-icon drawer, used by the macOS shell path
apps/<App>/Platforms/Android/
  Swift/<App>Android.swift   the application's Android head
  Java/                      the application's own views, where it has any
  build.gradle.kts           its APK: the host's Java layer, the application's, and the Swift libraries
  AndroidManifest.xml        the activity, and the library it loads
```

## Requirements

The host builds on macOS and Windows, for Android 9 (API 28) or newer. The
`stateui` CLI is the supported build, run, deploy and test path on both:

- Swift 6.4 from swift.org, `swift-6.4.0-RELEASE`, and the matching Swift SDK for
  Android, installed with `swift sdk install`. The CLI accepts a patch release of
  the same minor - for example the 6.4.1 SDK with the 6.4.0 compiler - which is
  what this checkout is verified with. Xcode's own Swift 6.4 is a different build
  and cannot read the SDK's modules; the CLI finds the matching toolchain itself;
- the Android NDK r30 or newer: the one `ANDROID_NDK_ROOT` or
  `ANDROID_NDK_HOME` names, else the
  one the Swift SDK's setup linked into its bundle, else the Android SDK's
  newest;
- the Android SDK with platform 36, its build tools and platform-tools, and JDK
  21 for Gradle. The CLI fetches Gradle 9.4.1 itself the first time;
- on Windows - and any other host without AppKit - `resvg` on `PATH`: the CLI
  draws the application's SVGs and its adaptive launcher icon with it;
- no Swift runtime is installed on the device: the CLI copies the runtime
  libraries the head needs from the Swift SDK into the APK.

## The head

An application's Android head is a library Android loads. Its `JNI_OnLoad`
names the application and hands the virtual machine to the host. Android calls
it on the UI thread from C, which no actor's type can say, so the head enters
`MainActor` there once, with `MainActor.assumeIsolated` - here the Gallery's,
which also says what it answers for the application:

```swift listing android.md.head
// Platforms/Android/Swift/GalleryAndroid.swift
import GalleryUI
import StateUI
import StateUIAndroid

// What Android calls as it loads this library, on the UI thread: the application is named to the host, this head
// says what it answers for the application - the controls it realizes, the acts it performs, the events it raises,
// each in Host/ beside this file - and the host registers the native methods its activity calls.
@_cdecl("JNI_OnLoad")
public func JNI_OnLoad(_ machine: UnsafeMutableRawPointer?, _ reserved: UnsafeMutableRawPointer?) -> Int32 {
    MainActor.assumeIsolated {
        GalleryApp.register()
        GalleryControls.register()
        GalleryActs.register()
        GalleryEventSources.register()
    }
    return AndroidHost.load(machine)
}
```

The head's `AndroidManifest.xml` declares the host's activity,
`stateui.android.StateUIActivity`, with the library to load as its
`stateui.library`. The activity loads it and starts the host; an application
needs no Java of its own. Its `build.gradle.kts` depends on AndroidX's
`recyclerview`, the collection an ItemsView stands on, and its
`swiperefreshlayout`, the pull a scroller or a list stands in. One that extends the host with views of its own
keeps their Java beside the head, in `Java/`, and may extend the activity,
declaring its own class in the manifest instead.

`STATEUI_HOST=android` is what makes a build an Android Views one: the
application's manifest reads it, declares its `Platforms/Android/Swift` head
and the library it makes, and defines the `ANDROID` compilation condition for
every module of the application; `lib/StateUI.Head` brings the
`StateUIAndroid` host to the head. Swift written for this host alone stands
under `#if ANDROID`. The CLI sets it as it builds the head, and nothing else:
the library itself is built as every host builds it.

A new application made in `apps/` - **StateUI: New Application in apps/**, or
`stateui new NAME` - has an Android head, as HelloWorld does, and runs and is
debugged as soon as it is made.

## Controls, acts, and events registered in Swift

An application extends the host from its Android head. Registrations run in
`JNI_OnLoad`, on the UI thread - the main actor's - before
`AndroidHost.load`. Registering a contract or an act again replaces the
earlier registration. Every registration is written against the
application's own contracts, so they are `public`: the host lives in a module
of its own and must see them. The Gallery's Android halves are in
`apps/Gallery/Platforms/Android/`: Swift in `Swift/Host/`, Java in `Java/`.

### A control

A control of the application's own is an object holding the Android view it
shows, an `AndroidControl`. The view is a class of the application's own
Java, made from Swift through `Java` - the host's JNI, the same calls it
makes itself - with the activity, `AndroidHost.context`, and held as a
`JavaObject`. `StateUIControls.add` says which contract it realizes:

```swift quote
public static func add<Realized: ElementContract, Made: AndroidControl>(
    _ contract: Realized.Type,
    create: @escaping @MainActor (ControlReports<Realized>) -> Made,
    members: @MainActor (AndroidRegistration<Realized, Made>) -> Void = { _ in })
```

- **`create`** makes the control once per element, and wires what it reports:
  `reports.raise(Contract.member, values)` for an event of the element's own
  or of a tier it wears, and `reports.report(property, value, as: event)` for
  a value the USER changed.
- **`members`** registers what the control takes: `property(_:_:)` hands a
  value over as the type its contract declares, `nil` where it is no longer
  described, and `declares(_:)` records an event the control raises.

```swift listing android.md.control
// Platforms/Android/Swift/Host/TrafficLightView.swift
extension TrafficLightView {
    /// Adds the light for `TrafficLightContract`: `create` makes the control once per element and wires the tap it
    /// reports, and `property` puts the described signal on it. Said once, as the library loads.
    @MainActor
    static func register() {
        StateUIControls.add(TrafficLightContract.self, create: { reports -> TrafficLightView in
            let light = TrafficLightView()
            light.onLampTapped = { index in reports.raise(TrafficLightContract.lampTapped, index) }
            return light
        }) { light in
            light.property(TrafficLightContract.signal) { control, signal in
                control.signal = signal ?? .stop
            }
            light.declares(TrafficLightContract.lampTapped)
        }
    }
}
```

The host places, sizes and shows the view as it does its own - margins,
alignment, opacity, gestures, frame reports - measuring it by the view's own
`onMeasure`. A registered control is a leaf: it draws the children of a
contract it names itself, as the next section says. The view tells its Swift half
what the user did through a native method of the application's own, found by
its JNI name (`@_cdecl("Java_..._lampTapped")`), handed the number the
control made it with. A control that draws with the GPU is a view like any
other: the Gallery's `Cube3D` is a `TextureView` whose surface Swift draws
into with OpenGL ES 3.0 over EGL, following the display's frames only while
it spins and stands in a window - the same declaration Metal draws on AppKit.

### Properties taken together

A control that must take properties together - a rating bar its stars and
its rating, a web view its agent before its page - names them with `applies`,
and is handed them whole whenever any of them changes: each as the type its
contract declares, and whether it changed (`ControlValues`). Each `property`
alone comes in no promised order. The Gallery's rating bar also reports the
rating the user taps, with `reports.report`:

```swift listing android.md.applies
// Platforms/Android/Swift/Host/RatingBarView.swift
StateUIControls.add(RatingBarContract.self, create: { reports -> RatingBarView in
    let bar = RatingBarView()
    bar.onRatingChanged = { rating in
        reports.report(RatingBarContract.rating, rating, as: RatingBarContract.ratingChanged)
    }
    return bar
}) { bar in
    // The stars and the rating come together: a rating stands within the stars, whichever of the two changed.
    bar.applies(RatingBarContract.maximum, RatingBarContract.rating) { control, values in
        control.show(
            rating: values[RatingBarContract.rating] ?? 0, of: Int(values[RatingBarContract.maximum] ?? 5))
    }
    bar.declares(RatingBarContract.ratingChanged)
}
```

### Children a control draws

A control may draw the children of one contract itself - a map draws its markers.
`children` names their contract and what of each the control realizes, and hands
it every such child, in the tree's order, whenever the element's children
change: one added, moved, taken away, or given another value. A child is an
`ControlChild` - its values read as the types its contract declares, and its own
`reports` to raise its events on it - and stays the same child for as long as
it lives, so the control keeps what it drew for one by it. Such a child has no
view of its own. The Gallery's Google map draws its markers so:

```swift listing android.md.children
// Platforms/Android/Swift/Host/GoogleMapView.swift
StateUIControls.add(MapContract.self, create: { reports in GoogleMapView(reports) }) { map in
    map.property(MapContract.region) { control, region in control.show(region) }
    map.property(MapContract.kind) { control, type in control.show(type) }
    map.property(MapContract.showsTraffic) { control, on in control.showTraffic(on ?? false) }
    map.property(MapContract.showsUserLocation) { control, on in control.showUserLocation(on ?? false) }
    map.property(MapContract.isZoomEnabled) { control, on in control.allow(zooms: on ?? true) }
    map.property(MapContract.isScrollEnabled) { control, on in control.allow(scrolls: on ?? true) }
    map.declares(MapContract.locationTapped)
    map.children(
        MarkerContract.self,
        properties: MarkerContract.title, MarkerContract.subtitle, MarkerContract.location, MarkerContract.kind,
        events: MarkerContract.selected, MarkerContract.detailsClicked
    ) { control, markers in
        control.show(markers)
    }
}
```

A library element a host does not realize - a `Map` where the platform has no
map of its own - is registered the same way, with the provider and the key it
needs.

This host leaves `Map` and its `Marker` to the application: the platform has
no map of its own, and a map needs a provider and its key, so the host makes
neither (`byApplication` in `AndroidRealization.swift`), and the
[platform contract](../platform-contract.md#reading-the-matrix) marks them 🧩.
What the user sees there is the application's own registration. The
Gallery's is Google's: its `GoogleMapView` over the Maps SDK for Android, its
markers the map's children. Its key is the application's own, never the
repository's - `Platforms/Android/google-maps-key.properties` beside
`build.gradle.kts`, which git keeps out:

```properties
key=your key
```

The build hands it to the manifest's `com.google.android.geo.API_KEY`, which
stands even empty, as a map that finds none stops its page. Without a key the
map draws no tiles, and the Gallery says so under it. Every other
element of the library is the host's own, its `WebView` included: Android's
web view, in the Java layer's `StateUIWebView`, which makes it again, blank,
should its web process die. The head registers nothing for it.

### An act

`StateUIActs.add` registers a function the application calls by its act, and
`StateUIActs.add(_:on:_:)` one aimed at the application's own element, handed
that element's control:

```swift listing android.md.acts
// Platforms/Android/Swift/Host/GalleryActs.swift
StateUIActs.add(GalleryContract.log) { line in
    Java.frame { Java.callStatic(Self.device, Self.log, .object(Java.string(line))) }
}

// Platforms/Android/Swift/Host/RatingBarView.swift
// An act aimed at a control is its control's: the identity the aim sent is turned back into the control
// this host made, and the performer is handed that control.
StateUIActs.add(RatingBarContract.flash, on: RatingBarView.self) { bar in
    // The Java view fades itself, with its own animate().
    bar.flash()
}
```

A head calls its Java half through `Java`: `Java.call` and `Java.callStatic`
read the answer as the type the call stands for - `let width: Int32 =
Java.call(view, method)` - an `int`, a `long`, a `boolean`, a `float`, a
`double` or an object, each a `JavaResult` - and one standing as a statement
answers nothing.
`Java.frame` lets go of the local references the calls inside it make.
`Java.env` and `Java.jni` are the main thread's environment and its function
table, for what the calls do not cover; a call through them is the head's
own, on the main thread, its exceptions its own to clear.

A performer runs on the UI thread, and may await, the call answered once it
returns. Its arguments and answer are the act's own types; a call carrying
anything else fails with the reason. A thrown error fails the act, and so does
an aim at nothing; an act nobody registered is refused by name.

### An event without a control

`StateUIEvents.raise` pushes an event of the application's that belongs to no
element, from any thread; `StateUIEvents.declares` declares it before the host
starts, so a handler listening for one no source raises is told so. Its
source is often Android's own - the Gallery's activity registers a receiver
for the battery while it lives:

```swift listing android.md.event
// Platforms/Android/Swift/Host/GalleryEventSources.swift
/// Declares the event the activity's watcher raises. Said once, as the library loads.
@MainActor
static func register() {
    StateUIEvents.declares(GalleryContract.batteryChanged)
}

@MainActor private static var lastSaid: (level: Double, charging: Bool)?

/// The battery said its level and whether it charges: raised where it changed, and a device with no battery
/// says nothing.
@MainActor
static func report(level: Double, charging: Bool) {
    guard level > 0 else { return }
    guard lastSaid?.level != level || lastSaid?.charging != charging else { return }

    lastSaid = (level, charging)
    StateUIEvents.raise(GalleryContract.batteryChanged, level, charging)
}
```

## Running

```bash
stateui devices --host android
stateui build HelloWorld --host android
stateui run HelloWorld --host android --device emulator-5554
```

`stateui devices --host android` lists attached devices and emulators, and
stopped AVDs; a running emulator is named by its AVD. Builds, runs, tests and
deploys take `--device`; with one device attached it is implied. `run --detach`
returns once the activity starts, and without it the CLI follows logcat.
Everything a build writes stays in the application's `.build/android/`.

The CLI builds the application's Swift for the device's ABI alone, then the
APK, installs it and starts it. The APK carries the libraries the head needs -
the Swift runtime's own among them - stripped, with the unstripped copies kept
in `.build/android/symbols/` for `ndk-stack` and a debugger. Android draws no
SVG, so the application's `Resources/Images` are drawn for it as the APK is
built: an SVG three times over, as a PNG, which `Image("mark.png")` finds as it
does on UIKit. An application's `print` reaches logcat under the tag `StateUI`,
and so does what `STATEUI_TALLY=1` and `STATEUI_INSPECT=1` write: the CLI hands
every `STATEUI_` variable of the shell that runs it to the application's
environment. A head's manifest asks for `ACCESS_NETWORK_STATE`, which the host
needs to report the network to the application's views.

An emulator is an Android SDK tool, not a `.scripts` script. Once the SDK is
installed, `avdmanager` creates the AVD and the SDK's `emulator` starts it:

```powershell
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.1.0" "emulator" "ndk;30.0.16248370" "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n StateUI -k "system-images;android-36;google_apis;x86_64" -d pixel_7
emulator -avd StateUI
```

`stateui doctor --host android` names what the SDK, NDK, JDK and Swift SDK are
still missing.

In VS Code, choose **Android** as the host and a device, and press **F5**.

## Debugging

**StateUI: Debug** builds, installs and starts the application as `stateui run`
does, and then attaches `lldb-dap` to it: a breakpoint in the application, in
StateUI or in the host stops it, with its source, its stack and its variables.
It is the application running that is attached to, so what runs before - the
first render - runs without the debugger. Only a debug build can be debugged.

`stateui debug prepare Gallery --host android --device emulator-5554` readies
it: the NDK's `lldb-server` runs as the application, in its own sandbox, and
`.build/android/debugger.json` says where it listens and which process to attach
to. `stateui debug plan` prints the same steps without running them. From a
terminal, with the toolchain's `lldb`:

```bash
stateui debug prepare Gallery --host android --device emulator-5554
cat apps/Gallery/.build/android/debugger.json
lldb -o "settings set plugin.jit-loader.gdb.enable off" \
     -o "platform select remote-android" \
     -o "platform connect unix-abstract-connect://emulator-5554/com.stateui.gallery/stateui-debugger.sock" \
     -o "settings append target.exec-search-paths $PWD/apps/Gallery/.build/android/symbols/arm64-v8a" \
     -o "process attach --pid <process from debugger.json>" \
     -o "process handle SIGSEGV SIGBUS --pass true --stop false --notify false"
```

The libraries are read from the build, which kept them unstripped; they must
be the ones installed, so the application is always run through the script
before it is attached to. Android's runtime raises SIGSEGV and SIGBUS on purpose,
and the debugger passes them to it rather than stopping. Nor does the debugger
follow the code the runtime's JIT compiles: the runtime announces each method
it compiles, and a debugger that reads each announcement stops the whole
application every time, which over USB holds the UI thread for seconds. End a
session by detaching - stopping the debugger itself leaves its breakpoints in
the application, which the next of them then ends.

## Deploying

```bash
stateui deploy Gallery --host android --device emulator-5554 --destination artifacts/Gallery/Android
```

The CLI builds an application's head for release, for the ABI of the device
named - `ANDROID_SERIAL`, or the one device attached, where none is named; a
device not attached is named by `--architecture x86_64|arm64-v8a`. It lays the
APK, `<application>.apk`, in the folder named, made anew. The APK is signed as
the head's `build.gradle.kts` says: HelloWorld's and the Gallery's sign a
release with the debug key. **StateUI: Deploy** in the editor runs it for the
application and the device chosen, and lays the APK in
`artifacts/<application>/Android` of the folder that holds the application's
`apps/` - a checkout's, or a project group's.

## Testing

A view exists only in an application's process, so the host's suite is a
library a test APK loads, run on the device's UI thread by its
instrumentation:

```bash
stateui test Gallery --host android --device emulator-5554
```

The CLI builds the test APK, installs it and runs its instrumentation. The
suite is XCTest. With no discovery on Android, each test case lists its tests in
`allTests` and the runner lists the cases; the CLI refuses to run while a test
or a case is listed nowhere. Each test and each conformance case says as it ends
where the run stands, followed from the device's log, and the run ends with
*Executed N tests, with M failures*.

The suite runs the conformance families too, one test a family -
`AndroidConformanceTests.testButton`. A whole run holds what it says to
`lib/StateUI/exports/`: what the host declares to `android.txt`, and the
verdicts it takes off the device to `marks/android/<Family>.txt`, each under
the revision its family stands at in
`lib/StateUI/StateUI.Conformance/revisions.txt`, which the CLI writes over
them, as the device reads no repository. A run that says otherwise fails;
`--update-exports` writes them instead. `--filter` runs the tests whose
`Case.test` name holds one of its comma-separated names, and then holds nothing
to `lib/StateUI/exports/`: a part of the suite proves only part of what the host
declares. `--stale` runs only the families whose verdict files stand at another
revision, or at none - the CLI chooses them - and holds or writes only theirs.

```bash
stateui test Gallery --host android --device emulator-5554 --filter testPicker,AndroidShapeViewTests
stateui test Gallery --host android --device emulator-5554 --update-exports
stateui test Gallery --host android --device emulator-5554 --update-exports --stale
STATEUI_UPDATE_DOCS=1 swift test --filter ControlDictionaryTests
```

With the verdicts written, the last line - at the repository's root - renders
the [platform contract](../platform-contract.md#reading-the-matrix) and
[the control dictionary](../controls/README.md) from them. In the editor,
with Android and a device chosen, **StateUI: Conformance - Rebuild all** runs
the whole suite on the device with `--update-exports`, then renders the
documents. **StateUI: Conformance - Rebuild changed** runs nothing for Android:
the editor answers that the device reads no repository, so its marks are made
again whole, by Rebuild all. From a terminal, `--stale` runs the stale families
alone, as above.

The test APK can be built with no device attached:
`stateui test Gallery --host android --build-only --architecture x86_64` builds
it for that ABI and prints where it is. The CLI builds and installs the test APK
itself for a normal run; an APK built elsewhere is installed with `--test-apk
PATH`, and the build's public API record is held after a normal build. A stopped
AVD is started with `stateui devices boot --host android --avd StateUI`, or by
naming it with `--device StateUI --boot` on `test` or `run`. CI builds on macOS,
where the build draws the pictures, and runs the suite on a Linux emulator.
