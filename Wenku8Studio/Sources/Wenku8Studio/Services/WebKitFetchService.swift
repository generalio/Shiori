import Foundation
import WebKit
import Wenku8Core

/// Headless WKWebView DOM fetcher sharing `WKWebsiteDataStore.default()` session cookies
/// with `WebLoginSheet`, supporting synchronized custom User-Agent, external cookie injection,
/// and strict navigation timeouts so a stalled page never deadlocks subsequent fetches.
@MainActor
final class WebKitFetchService: NSObject, SourceBrowserRuntime, WKNavigationDelegate {
    private var configuredUserAgent: String = HTTPRuntime.defaultUserAgent

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        wv.customUserAgent = configuredUserAgent
        wv.navigationDelegate = self
        return wv
    }()

    private var pendingContinuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    func updateUserAgent(_ ua: String) {
        let trimmed = ua.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? HTTPRuntime.defaultUserAgent : trimmed
        configuredUserAgent = resolved
        webView.customUserAgent = resolved
    }

    func syncCookieHeader(_ cookieHeader: String, forURL urlString: String) async {
        guard let url = URL(string: urlString), let host = url.host else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(3)) : host
        for segment in cookieHeader.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let props: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: "/",
                .name: name,
                .value: value,
                .secure: url.scheme == "https" ? "TRUE" : "FALSE",
                .expires: Date().addingTimeInterval(30 * 24 * 3600)
            ]
            if let httpCookie = HTTPCookie(properties: props) {
                await store.setCookie(httpCookie)
            }
        }
    }

    func fetchRenderedHTML(
        sourceId: String,
        url urlString: String,
        stripAbsoluteHiddenParagraphs: Bool
    ) async throws -> FetchedDOMPage {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidInput("无效 URL：\(urlString)")
        }

        // Wait cleanly if another load is in progress (bounded wait)
        var waitTicks = 0
        while pendingContinuation != nil && waitTicks < 250 {
            waitTicks += 1
            try await Task.sleep(for: .milliseconds(80))
        }
        if pendingContinuation != nil {
            finishPending(throwing: SourceError.networkError("内置浏览器前序请求超时，已重置"))
            webView.stopLoading()
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.pendingContinuation = cont
            self.timeoutTask?.cancel()
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.pendingContinuation != nil else { return }
                self.webView.stopLoading()
                self.finishPending(throwing: SourceError.networkError("页面加载超时（20s）：\(urlString)"))
            }
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

    private func finishPending(throwing error: Error? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishPending()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPending(throwing: SourceError.networkError(error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPending(throwing: SourceError.networkError(error.localizedDescription))
    }
}
