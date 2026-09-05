import Foundation
import UIKit
import WebKit

/// Per-tab owner of a WKWebView. Owns the navigation/session delegates,
/// download handling and page events. Every tab shares the same persistent
/// `WKWebsiteDataStore`, so cookies / localStorage survive app restarts.
final class WebCoordinator: NSObject {
    weak var browser: BrowserStore?

    let tabID: UUID
    let webView: WKWebView

    private var activeDownloads: [WKDownload: DownloadContext] = [:]
    private(set) var isDesktopAgent: Bool

    /// Desktop-mode user agent used when the setting is on.
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    init(tabID: UUID, desktopMode: Bool, ephemeral: Bool = false) {
        self.tabID = tabID
        self.isDesktopAgent = desktopMode

        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: BrowserJavaScript.coreScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController = controller
        // Private tabs use an isolated, non-persistent store: their cookies and
        // local storage do not survive the session (official WebKit API).
        config.websiteDataStore = ephemeral ? WKWebsiteDataStore.nonPersistent() : WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        if desktopMode {
            view.customUserAgent = Self.desktopUserAgent
        }
        self.webView = view

        super.init()

        view.navigationDelegate = self
        view.uiDelegate = self
    }

    func setDesktopMode(_ on: Bool) {
        guard on != isDesktopAgent else { return }
        isDesktopAgent = on
        webView.customUserAgent = on ? Self.desktopUserAgent : nil
        webView.reload()
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Route an update to the owning store from a WebKit delegate callback,
    /// hopping onto the main actor. WebKit calls us on the main thread, so this
    /// is just an isolation shim.
    func notify(_ action: @escaping @MainActor (BrowserStore) -> Void) {
        guard let browser else { return }
        Task { @MainActor in action(browser) }
    }

    @MainActor
    func evaluate(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            self.webView.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebCoordinator: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        notify { $0.webChromeDidChange(tabID: self.tabID) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        notify { $0.webChromeDidChange(tabID: self.tabID) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notify { $0.webChromeDidChange(tabID: self.tabID) }
        notify { $0.webPageDidFinish(tabID: self.tabID) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        notify { $0.webLoadFailed(tabID: self.tabID, error: error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        notify { $0.webLoadFailed(tabID: self.tabID, error: error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        let isWeb = scheme == "http" || scheme == "https"

        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated, isWeb, let url = navigationAction.request.url {
                notify { $0.openNewTab(url: url) }
            }
            return
        }

        if isWeb {
            decisionHandler(.allow)
        } else if let url = navigationAction.request.url,
                  url.scheme == "mailto" || url.scheme == "tel" {
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let disposition = response.allHeaderFields["Content-Disposition"] as? String,
           disposition.lowercased().contains("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension WebCoordinator: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Handled via decidePolicyFor (targetFrame == nil).
        return nil
    }
}

// MARK: - WKDownloadDelegate

extension WebCoordinator: WKDownloadDelegate {
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
        activeDownloads[download] = DownloadContext()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = URL.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let sanitized = suggestedFilename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let unique = Self.uniquePath(in: folder, filename: sanitized)
        let ctx = activeDownloads[download] ?? DownloadContext()
        ctx.targetURL = unique
        ctx.suggestedFilename = sanitized
        ctx.mime = response.mimeType ?? "application/octet-stream"
        activeDownloads[download] = ctx
        completionHandler(unique)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let ctx = activeDownloads.removeValue(forKey: download) {
            notify { $0.downloadDidComplete(context: ctx) }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        activeDownloads.removeValue(forKey: download)
    }

    private static func uniquePath(in folder: URL, filename: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(filename)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var idx = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(idx)" : "\(stem) \(idx).\(ext)"
            candidate = folder.appendingPathComponent(name)
            idx += 1
        }
        return candidate
    }
}

// MARK: - Supporting types

final class DownloadContext {
    var targetURL: URL?
    var suggestedFilename = ""
    var mime = "application/octet-stream"
}
