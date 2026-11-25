import AppKit
import SwiftUI
import WebKit
import Wenku8Core

private enum AuthImportMode: String, CaseIterable, Hashable {
    case externalImport = "外部浏览器 / cURL 导入"
    case embeddedBrowser = "内置网页登录"
}

struct WebLoginSheet: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var currentURLString: String = ""
    @State private var webViewRef: WKWebView?
    @State private var statusHint: String = ""
    @State private var mode: AuthImportMode = .embeddedBrowser
    @State private var pastedCredentials: String = ""

    private var activePlugin: (any BookSourcePlugin)? {
        vm.sourceRegistry.plugin(for: vm.activeLoginSourceId)
    }

    private var activeSourceName: String {
        activePlugin?.descriptor.displayName ?? "轻小说文库"
    }

    private var activeUserAgent: String {
        let ua = vm.sourceConfig(for: vm.activeLoginSourceId).userAgent
        return ua.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? HTTPRuntime.defaultUserAgent : ua
    }

    private var parsedPreview: ImportedCredentials {
        CurlImportParser.parse(pastedCredentials)
    }

    private var defaultHint: String {
        switch vm.activeLoginSourceId {
        case "bilinovel":
            return "若内置浏览器无法通过 Cloudflare 人机验证，请切换到「外部浏览器 / cURL 导入」，在 Safari/Chrome 手动验证后粘贴 cURL 或 Cookie。"
        case "copymanga":
            return "拷贝漫画搜索与阅读无需登录；如需同步个人云端收藏，可在浏览器登录后复制 cURL / Authorization Token 导入。"
        default:
            return "请在下方网页登录你的账号，或直接粘贴浏览器 Copy as cURL / Cookie 导入。"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(activeSourceName) · 会话认证")
                            .font(.headline)
                        StudioSourceBadge(title: vm.sourceBadgeTitle(for: vm.activeLoginSourceId), sourceId: vm.activeLoginSourceId)
                    }
                    Text(statusHint.isEmpty ? defaultHint : statusHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                StudioSegmentedTabs(selection: $mode, items: AuthImportMode.allCases)

                StudioPillButton(title: "取消", size: .small) {
                    vm.showWebLoginSheet = false
                }
            }
            .padding()
            .background(.bar)

            Divider()

            if mode == .externalImport {
                externalImportBody
            } else {
                embeddedBrowserBody
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .onAppear {
            if vm.activeLoginSourceId == "bilinovel" || vm.activeLoginSourceId == "copymanga" {
                mode = .externalImport
            } else {
                mode = .embeddedBrowser
            }
        }
    }

    private var externalImportBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("步骤 1 · 在系统浏览器中完成手动登录 / 人机验证")
                        .font(.subheadline.weight(.semibold))
                    Text("使用你本机的 Safari / Chrome 打开站点（可正常通过 Cloudflare 人机验证），登录后在开发者工具（Network）右键任意页面请求选择「Copy as cURL (bash)」，或直接复制 Cookie / Token。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        StudioPillButton(
                            title: "在系统浏览器打开 \(activeSourceName)",
                            systemImage: "arrow.up.right.square",
                            variant: .primary,
                            size: .regular
                        ) {
                            vm.openExternalBrowserForLogin(sourceId: vm.activeLoginSourceId)
                        }

                        StudioPillButton(
                            title: "从剪贴板粘贴",
                            systemImage: "doc.on.clipboard",
                            size: .regular
                        ) {
                            if let clip = NSPasteboard.general.string(forType: .string) {
                                pastedCredentials = clip
                            }
                        }
                    }
                }
                .studioCard(cornerRadius: StudioTokens.cardRadius, padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("步骤 2 · 粘贴 Copy as cURL / Cookie / Token")
                        .font(.subheadline.weight(.semibold))

                    TextEditor(text: $pastedCredentials)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 150)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.9)
                        }

                    if !pastedCredentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: parsedPreview.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .foregroundStyle(parsedPreview.isEmpty ? .orange : .green)
                            if parsedPreview.isEmpty {
                                Text("暂未解析出有效 Cookie / User-Agent / Token")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(spacing: 8) {
                                    if !parsedPreview.cookie.isEmpty {
                                        Text("Cookie ✓")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.14), in: Capsule())
                                    }
                                    if let ua = parsedPreview.userAgent, !ua.isEmpty {
                                        Text("User-Agent ✓")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.14), in: Capsule())
                                    }
                                    if let tok = parsedPreview.authorizationToken, !tok.isEmpty {
                                        Text("Token ✓")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.14), in: Capsule())
                                    }
                                }
                            }
                            Spacer()
                        }
                    }

                    HStack {
                        if vm.activeLoginSourceId == "bilinovel" {
                            Text("提示：导入含 cf_clearance 的 cURL 后，如仍遇 403，可在「设置 → 哔哩轻小说」启用本地 Python curl_cffi 传输桥接以对齐浏览器 TLS 指纹。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StudioPillButton(
                            title: "解析并应用凭证",
                            systemImage: "checkmark.shield.fill",
                            variant: .primary,
                            size: .regular,
                            isDisabled: parsedPreview.isEmpty
                        ) {
                            vm.importCredentials(rawText: pastedCredentials, sourceId: vm.activeLoginSourceId)
                        }
                    }
                }
                .studioCard(cornerRadius: StudioTokens.cardRadius, padding: 16)
            }
            .padding(20)
        }
    }

    private var embeddedBrowserBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(currentURLString.isEmpty ? vm.activeLoginURL().absoluteString : currentURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                StudioCircleButton(systemImage: "arrow.clockwise", size: .small, accessibilityLabel: "刷新页面") {
                    webViewRef?.reload()
                }
                .help("刷新页面")

                StudioPillButton(title: "在系统浏览器打开", systemImage: "safari", size: .small) {
                    vm.openExternalBrowserForLogin(sourceId: vm.activeLoginSourceId)
                }

                StudioPillButton(title: "提取 Cookie 并验证", systemImage: "checkmark.shield.fill", variant: .primary, size: .small) {
                    extractCookies()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            Wenku8WebView(
                initialURL: vm.activeLoginURL(),
                userAgent: activeUserAgent,
                currentURLString: $currentURLString,
                webViewRef: $webViewRef
            )
        }
    }

    private func extractCookies() {
        guard let store = webViewRef?.configuration.websiteDataStore.httpCookieStore else {
            statusHint = "无法读取浏览器 Cookie 存储"
            return
        }
        let targetSourceId = vm.activeLoginSourceId
        let activeHost = vm.activeLoginURL().host?.lowercased() ?? ""
        let mirrorHosts: [String] = (activePlugin?.descriptor.defaultMirrors ?? []).compactMap {
            URL(string: $0)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        }

        store.getAllCookies { cookies in
            let relevant = cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                let normalizedActive = activeHost.replacingOccurrences(of: "www.", with: "")
                if !normalizedActive.isEmpty && domain.contains(normalizedActive) {
                    return true
                }
                return mirrorHosts.contains(where: { !$0.isEmpty && domain.contains($0) })
            }
            if relevant.isEmpty {
                DispatchQueue.main.async {
                    statusHint = "尚未检测到该站点 Cookie，请确认已完成登录或验证，或改用「外部浏览器 / cURL 导入」。"
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
    let userAgent: String
    @Binding var currentURLString: String
    @Binding var webViewRef: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = userAgent
        webView.load(URLRequest(url: initialURL))
        DispatchQueue.main.async {
            self.webViewRef = webView
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.customUserAgent != userAgent {
            nsView.customUserAgent = userAgent
        }
    }

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
