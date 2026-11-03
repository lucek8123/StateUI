// SPDX-FileCopyrightText: 2026 Paweł Krzywdziński and Contributors
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Lays an application's Web page out beside its WebAssembly module.
public enum WebPageLayout {
    public static func actions(
        application: Application, checkout: URL, products: URL, site: URL
    ) throws -> [FileAction] {
        let javascript = checkout.appendingPathComponent("lib/StateUI/StateUI.Web/JavaScript", isDirectory: true)
        let template = javascript.appendingPathComponent("index.html")
        let relay = javascript.appendingPathComponent("stateui-web.js")
        let style = javascript.appendingPathComponent("stateui-web.css")
        for required in [template, relay, style] where !FileSystem.exists(required) {
            throw ToolingError.toolchainMissing(
                "The Web host's page assets are missing: \(required.path).",
                context: ["checkout": checkout.path],
                suggestion: "Point the application at a complete StateUI checkout."
            )
        }

        let product = application.product(for: .web)
        let module = products.appendingPathComponent("\(product).wasm")
        let page = application.directory.appendingPathComponent("Platforms/Web/Page", isDirectory: true)
        let stamp = String(Int(Date().timeIntervalSince1970))

        var scripts = ""
        var pageActions: [FileAction] = []
        if FileSystem.isDirectory(page) {
            for script in FileSystem.children(page) where script.pathExtension == "js" {
                pageActions.append(.copy(script, to: site.appendingPathComponent(script.lastPathComponent)))
                scripts += "<script type=\"module\" src=\"./\(script.lastPathComponent)?v=\(stamp)\"></script>"
            }
        }

        let headFile = page.appendingPathComponent("head.html")
        let head = (try? FileSystem.read(headFile)) ?? ""
        let title = head.range(of: "<title", options: .caseInsensitive) == nil
            ? "<title>\(application.name)</title>\n" : ""
        let html = (try? FileSystem.read(template))?
            .replacingOccurrences(of: "{{application}}", with: application.name)
            .replacingOccurrences(of: "{{module}}", with: "\(product).wasm")
            .replacingOccurrences(of: "{{stamp}}", with: stamp)
            .replacingOccurrences(of: "{{scripts}}", with: scripts)
            .replacingOccurrences(of: "{{head}}", with: title + head)
        guard let html else {
            throw ToolingError.toolchainMissing("The Web page template could not be read: \(template.path).")
        }

        var actions: [FileAction] = [
            .remove(site),
            .createDirectory(site),
            .copy(module, to: site.appendingPathComponent("\(product).wasm")),
            .copy(relay, to: site.appendingPathComponent("stateui-web.js")),
            .copy(style, to: site.appendingPathComponent("stateui-web.css")),
        ]
        actions.append(contentsOf: pageActions)
        actions.append(.write(html, to: site.appendingPathComponent("index.html")))
        let images = HostSupport.images(application)
        if FileSystem.isDirectory(images) {
            actions.append(.copyTree(images, to: site.appendingPathComponent("Images", isDirectory: true)))
        }
        return actions
    }

    /// The query a page's address carries: every `STATEUI_` variable of the
    /// calling environment except `STATEUI_HOST`.
    public static func query(_ environment: Environment) -> String {
        environment.stateuiVariables
            .filter { $0.key != "STATEUI_HOST" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}
