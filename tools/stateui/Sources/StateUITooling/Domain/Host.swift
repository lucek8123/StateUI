// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A StateUI host: the platform toolkit an application is built for.
public enum HostID: String, Codable, CaseIterable, Sendable, Hashable {
    case appKit = "appkit"
    case uiKit = "uikit"
    case android
    case winUI = "winui"
    case gtk
    case web

    public init?(parsing raw: String) {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        switch normalized {
        case "appkit", "macos", "mac": self = .appKit
        case "uikit", "ios", "ipados": self = .uiKit
        case "android": self = .android
        case "winui", "windows": self = .winUI
        case "gtk", "linux": self = .gtk
        case "web", "wasm", "webassembly": self = .web
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .appKit: return "AppKit"
        case .uiKit: return "UIKit"
        case .android: return "Android"
        case .winUI: return "WinUI"
        case .gtk: return "GTK"
        case .web: return "Web"
        }
    }

    public var manifestCondition: String {
        switch self {
        case .appKit: return "APPKIT"
        case .uiKit: return "UIKIT"
        case .android: return "ANDROID"
        case .winUI: return "WINUI"
        case .gtk: return "GTK"
        case .web: return "WEB"
        }
    }

    public var productSuffix: String {
        switch self {
        case .appKit: return "AppKit"
        case .uiKit: return "UIKit"
        case .android: return "Android"
        case .winUI: return "WinUI"
        case .gtk: return "GTK"
        case .web: return "Web"
        }
    }

    /// The directory under `.build` where this host's builds live.
    public var buildDirectoryName: String { rawValue }

    /// The language server's index directory for this host.
    public var indexDirectory: String { ".build/\(rawValue)/index-build" }

    /// The head marker an application needs for this host.
    public var headMarker: String {
        switch self {
        case .android: return "Platforms/Android/build.gradle.kts"
        default: return "Platforms/\(productSuffix)/main.swift"
        }
    }

    public var developmentPlatforms: Set<ProjectPlatform> {
        switch self {
        case .appKit, .uiKit: return [.macOS]
        case .android: return [.macOS, .linux]
        case .winUI: return [.windows]
        case .gtk: return [.linux]
        case .web: return [.macOS, .linux]
        }
    }

    public var description: String {
        switch self {
        case .appKit: return "macOS, in the application's own process"
        case .uiKit: return "iOS and iPadOS on a simulator or device, in the application's own process"
        case .android: return "Android Views, in the application's own process"
        case .winUI: return "WinUI 3 on Windows, in the application's own process"
        case .gtk: return "GTK 4 with libadwaita on Linux, in the application's own process"
        case .web: return "a page in a browser, the application a WebAssembly module in it"
        }
    }

    public var target: HostTarget? {
        switch self {
        case .uiKit:
            return HostTarget(triple: "arm64-apple-ios26.0-simulator", xcodeSDK: "iphonesimulator")
        case .android:
            return HostTarget(triple: "aarch64-unknown-linux-android28", swiftSDKFamily: "android")
        case .web:
            return HostTarget(triple: "wasm32-unknown-wasip1", swiftSDKFamily: "wasm")
        case .appKit, .winUI, .gtk:
            return nil
        }
    }
}

/// What a host compiles for when that is not this machine.
public struct HostTarget: Codable, Sendable, Hashable {
    public let triple: String
    public let swiftSDKFamily: String?
    public let xcodeSDK: String?

    public init(triple: String, swiftSDKFamily: String? = nil, xcodeSDK: String? = nil) {
        self.triple = triple
        self.swiftSDKFamily = swiftSDKFamily
        self.xcodeSDK = xcodeSDK
    }
}

public enum ProjectPlatform: String, Codable, Sendable, Hashable, CaseIterable {
    case macOS
    case iOS
    case android
    case windows
    case linux
    case web
}

public struct HostCapabilities: Codable, Sendable, Hashable {
    public let build: Bool
    public let run: Bool
    public let test: Bool
    public let deploy: Bool
    public let debug: Bool
    public let devices: Bool
    public let browsers: Bool
    public let lsp: Bool

    public init(
        build: Bool = true, run: Bool = true, test: Bool = true, deploy: Bool = true,
        debug: Bool = true, devices: Bool = false, browsers: Bool = false, lsp: Bool = true
    ) {
        self.build = build
        self.run = run
        self.test = test
        self.deploy = deploy
        self.debug = debug
        self.devices = devices
        self.browsers = browsers
        self.lsp = lsp
    }

    public static let standard = HostCapabilities()
}

public enum HostAvailabilityStatus: String, Codable, Sendable {
    case ready
    case unsupportedOperatingSystem = "unsupported-os"
    case toolchainMissing = "toolchain-missing"
    case deviceMissing = "device-missing"
    case unavailable
}

public struct HostAvailability: Codable, Sendable, Hashable {
    public let host: HostID
    public let status: HostAvailabilityStatus
    public let reason: String?
    public let toolchainReady: Bool
    public let deviceAvailable: Bool

    public init(
        host: HostID, status: HostAvailabilityStatus, reason: String? = nil,
        toolchainReady: Bool = false, deviceAvailable: Bool = false
    ) {
        self.host = host
        self.status = status
        self.reason = reason
        self.toolchainReady = toolchainReady
        self.deviceAvailable = deviceAvailable
    }

    public var isReady: Bool { status == .ready }
}

public struct HostDescriptor: Codable, Sendable, Hashable {
    public let id: HostID
    public let label: String
    public let detail: String
    public let platforms: [ProjectPlatform]
    public let capabilities: HostCapabilities
    public let indexDirectory: String
    public let target: HostTarget?

    public init(id: HostID) {
        self.id = id
        self.label = id.label
        self.detail = id.description
        self.platforms = ProjectPlatform.allCases.filter { id.developmentPlatforms.contains($0) }
        switch id {
        case .web:
            self.capabilities = HostCapabilities(devices: false, browsers: true)
        case .android, .uiKit:
            self.capabilities = HostCapabilities(devices: true)
        default:
            self.capabilities = .standard
        }
        self.indexDirectory = id.indexDirectory
        self.target = id.target
    }
}
