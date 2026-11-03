// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The NuGet packages a WinUI head is laid out with. The ids and versions stand
/// here and nowhere else: every WinUI step takes them as `--package` arguments,
/// so the tool that fetches them reads no pin of its own.
public enum WinUIPackages {
    public static let cppwinrt = "3.0.260818.1"
    public static let winUI = "1.8.260528001"
    public static let foundation = "1.8.260527000"
    public static let interactiveExperiences = "1.8.260525001"
    public static let webView2 = "1.0.3179.45"

    /// The packages the C++/WinRT projection reads, in the order its inputs are
    /// handed to cppwinrt in.
    public static let projection: [(id: String, version: String)] = [
        ("microsoft.windows.cppwinrt", cppwinrt),
        ("microsoft.windowsappsdk.winui", winUI),
        ("microsoft.windowsappsdk.foundation", foundation),
        ("microsoft.windowsappsdk.interactiveexperiences", interactiveExperiences),
        ("microsoft.web.webview2", webView2),
    ]

    /// The packages a directory made self-contained is laid with: the Windows
    /// App SDK's components beside the head, and the web view's engine where the
    /// head links that backend.
    public static let laying: [(id: String, version: String)] = [
        ("microsoft.windowsappsdk.winui", winUI),
        ("microsoft.windowsappsdk.foundation", foundation),
        ("microsoft.windowsappsdk.interactiveexperiences", interactiveExperiences),
        ("microsoft.web.webview2", webView2),
    ]

    /// Where NuGet keeps the packages it has fetched: the cache the machine's
    /// own tool fills, which the WinUI tool fills too where a package is missing.
    public static func root(environment: Environment) -> URL {
        if let named = environment["NUGET_PACKAGES"], !named.isEmpty {
            return FileSystem.expand(named)
        }
        return FileSystem.home().appendingPathComponent(".nuget/packages")
    }

    /// The `--package <id>=<version>` arguments a step is given, in the order
    /// the packages are read in.
    public static func arguments(_ packages: [(id: String, version: String)]) -> [String] {
        packages.flatMap { ["--package", "\($0.id)=\($0.version)"] }
    }
}
