import Foundation
import WebKit
import Wenku8Core

/// Headless WKWebView DOM fetcher sharing `WKWebsiteDataStore.default()` session cookies
/// with `WebLoginSheet` (so user-authenticated / user-verified sessions apply transparently).
@MainActor
final class WebKitFetchService: NSObject, SourceBrowserRuntime, WKNavigationDelegate {
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        wv.navigationDelegate = self
        return wv
    }()

    private var pendingContinuation: CheckedContinuation<Void, Error>?

    func fetchRenderedHTML(
        sourceId: String,
        url urlString: String,
        stripAbsoluteHiddenParagraphs: Bool
    ) async throws -> FetchedDOMPage {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidInput("无效 URL：\(urlString)")
        }

        // Wait cleanly if another load is in progress
        while pendingContinuation != nil {
            try await Task.sleep(for: .milliseconds(80))
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.pendingContinuation = cont
            self.webView.load(URLRequest(url: url))
        }

        if stripAbsoluteHiddenParagraphs {
            try? await Task.sleep(for: .milliseconds(350))
            let cleanupJS = """
            (function() {
                document.querySelectorAll('p').forEach(function(p) {
                    if (window.getComputedStyle(p).position === 'absolute') {
                        p.remove();
                    }
                });
                return document.documentElement.outerHTML;
            })();
            """
            let result = try await webView.evaluateJavaScript(cleanupJS)
            let html = (result as? String) ?? ""
            return FetchedDOMPage(html: html, resolvedURL: webView.url?.absoluteString ?? urlString)
        } else {
            let result = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
            let html = (result as? String) ?? ""
            return FetchedDOMPage(html: html, resolvedURL: webView.url?.absoluteString ?? urlString)
        }
    }

    func currentCookiesHeader(forURL urlString: String) async -> String {
        guard let targetURL = URL(string: urlString),
              let host = targetURL.host?.lowercased() else {
            return ""
        }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let matching = cookies.filter { c in
            let d = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == d || host.hasSuffix("." + d)
        }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingContinuation?.resume(throwing: SourceError.networkError(error.localizedDescription))
        pendingContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingContinuation?.resume(throwing: SourceError.networkError(error.localizedDescription))
        pendingContinuation = nil
    }
}
