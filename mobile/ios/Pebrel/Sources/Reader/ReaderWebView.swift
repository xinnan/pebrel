import SwiftUI
import UIKit
import WebKit

/// Serves only the exact offline allowlist under `Bundle.main/reader/` via `pebrel-reader://local/reader/...`.
/// Never touches the network or arbitrary filesystem paths.
final class ReaderAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let exactAllowed: [String: String] = [
        "reader/reader.css": "text/css; charset=utf-8",
        "reader/highlight.min.js": "application/javascript; charset=utf-8",
        "reader/reader.js": "application/javascript; charset=utf-8",
        "reader/extensions.js": "application/javascript; charset=utf-8",
        "reader/reader-compat.js": "application/javascript; charset=utf-8",
        "reader/katex/katex.min.js": "application/javascript; charset=utf-8",
        "reader/katex/katex.min.css": "text/css; charset=utf-8",
        "reader/mermaid/mermaid.min.js": "application/javascript; charset=utf-8",
    ]
    private static let katexFontRegex = try! NSRegularExpression(pattern: "^reader/katex/fonts/KaTeX_[A-Za-z0-9-]+\\.woff2$")

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            respondEmpty(urlSchemeTask)
            return
        }
        let rel = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let mime: String?
        if let exact = Self.exactAllowed[rel] {
            mime = exact
        } else {
            let range = NSRange(rel.startIndex..<rel.endIndex, in: rel)
            mime = Self.katexFontRegex.firstMatch(in: rel, range: range) != nil ? "font/woff2" : nil
        }

        guard let mime,
              let root = Bundle.main.resourceURL,
              let data = try? Data(contentsOf: root.appendingPathComponent(rel)) else {
            respondEmpty(urlSchemeTask)
            return
        }

        let response = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func respondEmpty(_ task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 0, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(Data())
        task.didFinish()
    }
}

/// Offline sandboxed rich reader hosting Markdown, KaTeX, Mermaid, and highlight.js in `WKWebView`.
struct ReaderWebView: UIViewRepresentable {
    let document: ReaderDocument
    let colors: ReaderColors
    let scrollToHeadingId: String?
    let onCopyCode: (Int) -> Void
    let onOpenLink: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCopyCode: onCopyCode, onOpenLink: onOpenLink)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(ReaderAssetSchemeHandler(), forURLScheme: ReaderMarkdown.scheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.webView = webView
        load(document: document, colors: colors, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.onCopyCode = onCopyCode
        context.coordinator.onOpenLink = onOpenLink
        if context.coordinator.loadedToken != document.token || context.coordinator.loadedColors != colors {
            load(document: document, colors: colors, in: uiView, coordinator: context.coordinator)
        }
        if let heading = scrollToHeadingId, heading != context.coordinator.lastHeadingId {
            context.coordinator.lastHeadingId = heading
            if let json = try? JSONSerialization.data(withJSONObject: [heading]),
               let arr = String(data: json, encoding: .utf8) {
                uiView.evaluateJavaScript("document.getElementById((\(arr))[0])?.scrollIntoView({behavior:'smooth'});", completionHandler: nil)
            }
        }
    }

    private func load(document: ReaderDocument, colors: ReaderColors, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentDocument = document
        coordinator.loadedToken = document.token
        coordinator.loadedColors = colors
        webView.loadHTMLString(document.html, baseURL: ReaderMarkdown.baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var currentDocument: ReaderDocument?
        var loadedToken: String = ""
        var loadedColors: ReaderColors?
        var lastHeadingId: String?
        var onCopyCode: (Int) -> Void
        var onOpenLink: (String) -> Void
        private var resetCopyWork: DispatchWorkItem?

        init(onCopyCode: @escaping (Int) -> Void, onOpenLink: @escaping (String) -> Void) {
            self.onCopyCode = onCopyCode
            self.onOpenLink = onOpenLink
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let errLabel = L10n.tr("reader_extension_error")
            let loadLabel = L10n.tr("reader_extension_loading")
            if let data = try? JSONSerialization.data(withJSONObject: [errLabel, loadLabel]),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("if (window.pebrelSetReaderLabels) { var _l = \(json); window.pebrelSetReaderLabels(_l[0], _l[1]); }", completionHandler: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == ReaderMarkdown.scheme || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            guard let doc = currentDocument else { return }
            let raw = url.absoluteString

            if raw.hasPrefix("pebrel-copy:") {
                let parts = raw.dropFirst("pebrel-copy:".count).split(separator: ":")
                if parts.count == 2, String(parts[0]) == doc.token, let idx = Int(parts[1]),
                   idx >= 0, idx < doc.codeBlocks.count {
                    onCopyCode(idx)
                    showCopiedFeedback(index: idx)
                }
            } else if raw.hasPrefix("pebrel-link:") {
                let parts = raw.dropFirst("pebrel-link:".count).split(separator: ":")
                if parts.count == 2, String(parts[0]) == doc.token, let idx = Int(parts[1]),
                   idx >= 0, idx < doc.links.count {
                    let href = doc.links[idx]
                    if href.hasPrefix("#") {
                        let slug = String(href.dropFirst())
                        if let data = try? JSONSerialization.data(withJSONObject: [slug]),
                           let json = String(data: data, encoding: .utf8) {
                            webView.evaluateJavaScript("document.getElementById((\(json))[0])?.scrollIntoView({behavior:'smooth'});", completionHandler: nil)
                        }
                    } else {
                        onOpenLink(href)
                    }
                }
            }
        }

        private func showCopiedFeedback(index: Int) {
            guard let webView else { return }
            let copyLabel = L10n.tr("reader_copy")
            let copiedLabel = L10n.tr("reader_copied")
            if let data = try? JSONSerialization.data(withJSONObject: [copyLabel, copiedLabel]),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript(
                    "var _c=\(json); document.querySelectorAll('[data-copy]').forEach(function(el){ el.textContent = (Number(el.dataset.copy)===\(index)) ? _c[1] : _c[0]; });",
                    completionHandler: nil
                )
            }
            resetCopyWork?.cancel()
            let item = DispatchWorkItem { [weak webView] in
                if let data = try? JSONSerialization.data(withJSONObject: [copyLabel]),
                   let json = String(data: data, encoding: .utf8) {
                    webView?.evaluateJavaScript(
                        "var _c=\(json); document.querySelectorAll('[data-copy]').forEach(function(el){ el.textContent = _c[0]; });",
                        completionHandler: nil
                    )
                }
            }
            resetCopyWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }
}
