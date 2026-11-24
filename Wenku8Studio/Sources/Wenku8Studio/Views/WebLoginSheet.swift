import SwiftUI
import WebKit
import Wenku8Core

struct WebLoginSheet: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var currentURLString: String = ""
    @State private var webViewRef: WKWebView?
    @State private var statusHint: String = ""

    private var activeSourceName: String {
        vm.sourceRegistry.plugin(for: vm.activeLoginSourceId)?.descriptor.displayName ?? "轻小说文库"
    }

    private var defaultHint: String {
        if vm.activeLoginSourceId == "bilinovel" {
            return "若站点弹出人机验证或登录页，请在下方完成验证后点击右上角「同步会话 / Cookie」。"
        }
        return "请在下方网页登录你的账号，登录成功后点击右上角「提取 Cookie」。"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(activeSourceName) · 内置登录与验证")
                        .font(.headline)
                    Text(statusHint.isEmpty ? defaultHint : statusHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    StudioCircleButton(systemImage: "arrow.clockwise", size: .small, accessibilityLabel: "刷新页面") {
                        webViewRef?.reload()
                    }
                    .help("刷新页面")

                    StudioPillButton(title: "取消", size: .small) {
                        vm.showWebLoginSheet = false
                    }

                    StudioPillButton(title: "提取 Cookie 并验证", systemImage: "checkmark.shield.fill", variant: .primary, size: .small) {
                        extractCookies()
                    }
                }
            }
            .padding()
            .background(.bar)

            Divider()

            Wenku8WebView(
                initialURL: vm.activeLoginURL(),
                currentURLString: $currentURLString,
                webViewRef: $webViewRef
            )
        }
        .frame(minWidth: 780, minHeight: 560)
    }

    private func extractCookies() {
        guard let store = webViewRef?.configuration.websiteDataStore.httpCookieStore else {
            statusHint = "无法读取浏览器 Cookie 存储"
            return
        }
        let targetSourceId = vm.activeLoginSourceId
        let activeHost = vm.activeLoginURL().host?.lowercased() ?? ""
        store.getAllCookies { cookies in
            let relevant = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                if targetSourceId == "bilinovel" {
                    return domain.contains("linovelib") || domain.contains("bilinovel") || (!activeHost.isEmpty && domain.contains(activeHost.replacingOccurrences(of: "www.", with: "")))
                }
                return domain.contains("wenku8") || (!activeHost.isEmpty && domain.contains(activeHost.replacingOccurrences(of: "www.", with: "")))
            }
            if relevant.isEmpty {
                DispatchQueue.main.async {
                    statusHint = "尚未检测到该站点 Cookie，请确认已完成登录或验证。"
                }
                return
            }
            let cookieString = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            DispatchQueue.main.async {
                vm.applyWebLoginCookie(cookieString, sourceId: targetSourceId)
            }
        }
    }
}

private struct Wenku8WebView: NSViewRepresentable {
    let initialURL: URL
    @Binding var currentURLString: String
    @Binding var webViewRef: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        webView.load(URLRequest(url: initialURL))
        DispatchQueue.main.async {
            self.webViewRef = webView
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: Wenku8WebView

        init(parent: Wenku8WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let urlStr = webView.url?.absoluteString ?? ""
            parent.currentURLString = urlStr
            if urlStr.contains("login.php") {
                // Default session persistence to 1 month so PHPSESSID/jieqiUserInfo doesn't expire immediately
                webView.evaluateJavaScript("""
                (function() {
                    var sel = document.querySelector("select[name='usecookie']");
                    if (sel && sel.value === "0") {
                        for (var i = 0; i < sel.options.length; i++) {
                            if (sel.options[i].value === "2592000") {
                                sel.value = "2592000";
                                break;
                            }
                        }
                    }
                })();
                """)
            }
        }
    }
}
