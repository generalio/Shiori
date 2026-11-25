import Foundation

public actor BilinovelPlugin: BookSourcePlugin, DiscoveryCapableSource, AuthenticatedSource {
    public static let officialMirrors = [
        "https://www.linovelib.com",
        "https://www.bilinovel.com",
    ]

    public nonisolated let descriptor = BookSourceDescriptor(
        id: "bilinovel",
        displayName: "哔哩轻小说",
        shortBadge: "哔哩",
        subtitle: "www.linovelib.com · 支持榜单发现、搜书、多分页章节拼接与 WOFF2 字体还原",
        defaultMirrors: officialMirrors,
        supportedSearchScopes: [.articleName, .author, .bookId],
        requiresBrowserRuntime: true,
        contentKind: .lightNovel
    )

    private var baseURL: String
    private var cookie: String
    private var userAgent: String
    private var transportEngine: SourceTransportEngine
    private var pythonExecutablePath: String
    private var requestTimeout: TimeInterval
    private var politeDelaySeconds: Double
    private let httpRuntime: HTTPRuntime
    private let usesInjectedHTTPRuntime: Bool
    private var browserRuntime: (any SourceBrowserRuntime)?

    public init(
        baseURL: String = "https://www.linovelib.com",
        cookie: String = "",
        userAgent: String = HTTPRuntime.defaultUserAgent,
        timeout: TimeInterval = 18,
        politeDelaySeconds: Double = 1.5,
        httpRuntime: HTTPRuntime? = nil
    ) {
        self.baseURL = Wenku8Client.normalizeBaseURL(baseURL)
        self.cookie = Wenku8Client.normalizeCookie(cookie)
        self.userAgent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? HTTPRuntime.defaultUserAgent
            : userAgent
        self.transportEngine = .native
        self.pythonExecutablePath = ""
        self.requestTimeout = timeout
        self.politeDelaySeconds = politeDelaySeconds
        if let httpRuntime {
            self.httpRuntime = httpRuntime
            self.usesInjectedHTTPRuntime = true
        } else {
            self.httpRuntime = HTTPRuntime(timeout: timeout)
            self.usesInjectedHTTPRuntime = false
        }
    }

    public nonisolated func canHandle(rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bili:") || lower.hasPrefix("bilinovel:") {
            let suffix = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let bid = Self.extractBookId(from: suffix)
            return bid.isEmpty ? nil : bid
        }
        if lower.contains("linovelib.com") || lower.contains("bilinovel.com") {
            let bid = Self.extractBookId(from: trimmed)
            return bid.isEmpty ? nil : bid
        }
        if trimmed.allSatisfy(\.isNumber) {
            return trimmed
        }
        return nil
    }

    public func updateConfig(_ config: SourceRuntimeConfig) async {
        baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.officialMirrors[0]
            : Wenku8Client.normalizeBaseURL(config.baseURL)
        cookie = Wenku8Client.normalizeCookie(config.cookie)
        let ua = config.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        userAgent = ua.isEmpty ? HTTPRuntime.defaultUserAgent : ua
        transportEngine = config.transportEngine
        pythonExecutablePath = config.pythonExecutablePath
        requestTimeout = max(5, config.requestTimeout)
        politeDelaySeconds = max(0, config.politeDelaySeconds)

        if !usesInjectedHTTPRuntime {
            if transportEngine == .curlCFFI {
                let env = CurlCFFITransport.detectEnvironment(preferredPythonPath: pythonExecutablePath)
                if env.isAvailable, let py = env.pythonPath {
                    await httpRuntime.setTransport(CurlCFFITransport(
                        pythonExecutable: py,
                        impersonateProfile: CurlCFFITransport.inferImpersonateProfile(fromUserAgent: userAgent)
                    ))
                } else {
                    await httpRuntime.setTransport(nil)
                }
            } else {
                await httpRuntime.setTransport(nil)
            }
        }
    }

    public func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async {
        browserRuntime = runtime
    }

    // MARK: - Fetch Helpers

    private func fetchHTML(urlString: String, referer: String?, stripAbsoluteParagraphs: Bool = false) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidInput("无效 URL：\(urlString)")
        }

        // Sync cookies from browser store when explicit cookie is empty
        var effectiveCookie = cookie
        if effectiveCookie.isEmpty, let runtime = browserRuntime {
            effectiveCookie = await runtime.currentCookiesHeader(forURL: urlString)
        }
        if !effectiveCookie.contains("night=") {
            effectiveCookie = effectiveCookie.isEmpty ? "night=1" : "\(effectiveCookie); night=1"
        }

        // Direct HTTP (native URLSession or curl_cffi bridge) first for speed & concurrency
        do {
            let (html, _, pairs) = try await httpRuntime.fetchText(
                url: url,
                sourceId: descriptor.id,
                encoding: .utf8,
                cookie: effectiveCookie,
                referer: referer ?? baseURL,
                userAgent: userAgent,
                minDelaySeconds: politeDelaySeconds,
                timeout: requestTimeout
            )
            if !pairs.isEmpty {
                cookie = HTTPRuntime.mergeCookieHeader(existing: cookie, updating: pairs)
            }
            return html
        } catch let err as SourceError {
            // Fall back to WKWebView DOM runtime only on challenge/403 when browserRuntime is attached
            switch err {
            case .challengeRequired, .httpError(403, _):
                if let runtime = browserRuntime {
                    await httpRuntime.enforceRateLimit(hostKey: descriptor.id, minDelaySeconds: politeDelaySeconds)
                    let page = try await runtime.fetchRenderedHTML(
                        sourceId: descriptor.id,
                        url: urlString,
                        stripAbsoluteHiddenParagraphs: stripAbsoluteParagraphs
                    )
                    if HTTPRuntime.looksLikeCloudflareChallenge(page.html) {
                        throw SourceError.challengeRequired(
                            sourceId: descriptor.id,
                            url: urlString,
                            message: "哔哩轻小说触发 Cloudflare 验证，请在系统浏览器完成验证后通过「导入 Cookie / cURL」更新会话"
                        )
                    }
                    return page.html
                }
                throw err
            default:
                throw err
            }
        }
    }

    // MARK: - Core BookSourcePlugin

    public func search(query: String, scope: SearchScope, page: Int) async throws -> PagedBookResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw SourceError.invalidInput("请输入搜索关键词")
        }

        if scope == .bookId, q.allSatisfy(\.isNumber) {
            let detail = try await fetchBookDetail(bookIdOrURL: q, onProgress: nil)
            let item = AuthorBookItem(
                id: detail.bookId,
                sourceId: descriptor.id,
                title: detail.title,
                author: detail.author,
                category: detail.publisher,
                updatedAt: detail.lastUpdated,
                wordCount: detail.wordCount,
                status: detail.status,
                popularity: detail.popularity,
                tags: detail.tags,
                summary: detail.description,
                coverURL: detail.coverURL
            )
            return PagedBookResult(items: [item], currentPage: 1, totalPages: 1)
        }

        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let targetURL = "\(baseURL)/search/\(encoded)_\(max(1, page)).html"
        let html = try await fetchHTML(urlString: targetURL, referer: baseURL)
        return Self.parseBookListPage(html: html, baseURL: baseURL, currentPage: max(1, page))
    }

    public func fetchBookDetail(
        bookIdOrURL: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> BookDetail {
        let bookId = Self.extractBookId(from: bookIdOrURL)
        guard !bookId.isEmpty else {
            throw SourceError.invalidInput("无法识别哔哩轻小说书号：\(bookIdOrURL)")
        }

        let mainURL = "\(baseURL)/novel/\(bookId).html"
        onProgress?("正在请求哔哩轻小说详情页...")
        let mainHTML = try await fetchHTML(urlString: mainURL, referer: baseURL)
        let parsedMain = try Self.parseBookPage(html: mainHTML, bookId: bookId, baseURL: baseURL)

        let catalogURL = "\(baseURL)/novel/\(bookId)/catalog"
        onProgress?("正在拉取分卷与章节目录...")
        let catalogHTML = try await fetchHTML(urlString: catalogURL, referer: mainURL)
        var volumes = Self.parseCatalogPage(html: catalogHTML, bookTitle: parsedMain.title, baseURL: baseURL, bookId: bookId)

        // Resolve adjacent missing-link chapter placeholders when needed (best-effort)
        volumes = try await resolveMissingChapterLinksIfNeeded(volumes: volumes)

        return BookDetail(
            bookId: bookId,
            sourceId: descriptor.id,
            baseURL: baseURL,
            title: parsedMain.title,
            author: parsedMain.author,
            publisher: parsedMain.publisher,
            status: parsedMain.status,
            lastUpdated: parsedMain.lastUpdated,
            wordCount: parsedMain.wordCount,
            popularity: parsedMain.popularity,
            latestChapter: parsedMain.latestChapter,
            tags: parsedMain.tags,
            description: parsedMain.description,
            coverURL: parsedMain.coverURL,
            catalogURL: catalogURL,
            volumes: volumes,
            recommendations: parsedMain.recommendations
        )
    }

    public func fetchChapterContent(chapter: ChapterItem, book: BookDetail) async throws -> ChapterContent {
        guard !chapter.url.isEmpty, !Self.isUnresolvedURL(chapter.url) else {
            throw SourceError.parseError("章节《\(chapter.title)》暂无有效直达链接")
        }

        var allTokens: [ChapterToken] = []
        var allImages: [String] = []
        var seenImages = Set<String>()
        var unresolvedPUACount = 0

        var pageNo = 1
        var currentURL = chapter.url
        let maxPages = 30

        while pageNo <= maxPages {
            let html = try await fetchHTML(
                urlString: currentURL,
                referer: book.catalogURL,
                stripAbsoluteParagraphs: true
            )
            let parsed = Self.parseChapterPageHTML(
                html: html,
                chapterURL: currentURL,
                baseChapterURL: chapter.url,
                pageIndex: pageNo,
                baseURL: baseURL
            )

            allTokens.append(contentsOf: parsed.tokens)
            unresolvedPUACount += parsed.unresolvedPUACount
            for img in parsed.imageURLs where seenImages.insert(img).inserted {
                allImages.append(img)
            }

            if let nextPageURL = parsed.nextSubpageURL, nextPageURL != currentURL {
                currentURL = nextPageURL
                pageNo += 1
            } else {
                break
            }
        }

        let warning: String? = unresolvedPUACount > 0
            ? "检测到 \(unresolvedPUACount) 个未解码私有区字符，哔哩轻小说可能已更新混淆字库映射，部分汉字可能显示异常。"
            : nil
        return ChapterContent(
            chapter: chapter,
            tokens: allTokens,
            imageURLs: allImages,
            contentKind: .lightNovel,
            warningMessage: warning
        )
    }

    public func downloadImage(url: String, referer: String?) async throws -> DownloadedImageAsset {
        try await httpRuntime.downloadSingleImage(
            urlString: url,
            referer: referer ?? baseURL,
            cookie: cookie,
            userAgent: userAgent
        )
    }

    public func downloadImages(
        urls: [String],
        referer: String?,
        maxConcurrency: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String: DownloadedImageAsset] {
        await httpRuntime.downloadImages(
            urls: urls,
            referer: referer ?? baseURL,
            cookie: cookie,
            userAgent: userAgent,
            maxConcurrency: maxConcurrency,
            onProgress: onProgress
        )
    }

    // MARK: - DiscoveryCapableSource

    public nonisolated func discoveryChannels() -> [DiscoveryChannel] {
        [
            DiscoveryChannel(sourceId: descriptor.id, title: "总点击榜", path: "/top/allvisit/1.html", icon: "flame.fill"),
            DiscoveryChannel(sourceId: descriptor.id, title: "月点击榜", path: "/top/monthvisit/1.html", icon: "calendar"),
            DiscoveryChannel(sourceId: descriptor.id, title: "周点击榜", path: "/top/weekvisit/1.html", icon: "chart.line.uptrend.xyaxis"),
            DiscoveryChannel(sourceId: descriptor.id, title: "总收藏榜", path: "/top/goodnum/1.html", icon: "bookmark.fill"),
            DiscoveryChannel(sourceId: descriptor.id, title: "最近更新", path: "/top/lastupdate/1.html", icon: "clock.arrow.circlepath"),
            DiscoveryChannel(sourceId: descriptor.id, title: "完结轻小说", path: "/wenku/allvisit_0_0_0_0_0_1_0_1.html", icon: "checkmark.seal.fill"),
        ]
    }

    public func fetchChannelBooks(channel: DiscoveryChannel, page: Int) async throws -> PagedBookResult {
        var resolvedPath = channel.path
        if page > 1 {
            resolvedPath = resolvedPath.replacingOccurrences(of: "/1.html", with: "/\(page).html")
        }
        let targetURL = HTTPRuntime.resolveURL(resolvedPath, baseURL: baseURL)
        let html = try await fetchHTML(urlString: targetURL, referer: baseURL)
        return Self.parseBookListPage(html: html, baseURL: baseURL, currentPage: page)
    }

    public func fetchTagGroups() async throws -> [TagGroup] {
        []
    }

    public func fetchBooksByTag(tag: String, sort: TagSortOption, page: Int) async throws -> PagedBookResult {
        try await search(query: tag, scope: .articleName, page: page)
    }

    // MARK: - AuthenticatedSource

    public nonisolated func loginURL(baseURL: String) -> URL {
        let norm = Wenku8Client.normalizeBaseURL(baseURL.isEmpty ? Self.officialMirrors[0] : baseURL)
        return URL(string: "\(norm)/login.php") ?? URL(string: "https://www.linovelib.com/login.php")!
    }

    public nonisolated func diagnoseCookie(_ raw: String) -> SourceAuthCookieDiagnostic {
        let norm = Wenku8Client.normalizeCookie(raw)
        if norm.isEmpty {
            return SourceAuthCookieDiagnostic(
                isLikelyValidFormat: false,
                isForeignSiteCookie: false,
                message: "如触发 Cloudflare 人机验证或访问限制，可点击「网页登录 / 验证」自动获取会话 Cookie。",
                normalizedCookie: ""
            )
        }
        let hasSession = norm.contains("cf_clearance") || norm.contains("jieqiUserInfo") || norm.contains("PHPSESSID")
        return SourceAuthCookieDiagnostic(
            isLikelyValidFormat: hasSession || norm.contains("="),
            isForeignSiteCookie: false,
            message: hasSession ? "检测到有效会话或验证凭据。" : "已保存自定义 Cookie。",
            normalizedCookie: norm
        )
    }

    public func verifySession(cookie: String, baseURL: String) async -> SourceVerifyResult {
        let target = baseURL.isEmpty ? self.baseURL : Wenku8Client.normalizeBaseURL(baseURL)
        self.cookie = Wenku8Client.normalizeCookie(cookie)
        do {
            let html = try await fetchHTML(urlString: "\(target)/top/allvisit/1.html", referer: target)
            let ok = !HTTPRuntime.looksLikeCloudflareChallenge(html)
            return SourceVerifyResult(
                passed: ok,
                profile: nil,
                message: ok ? "哔哩轻小说站点连接正常" : "仍需完成 Cloudflare 验证"
            )
        } catch {
            return SourceVerifyResult(passed: false, profile: nil, message: error.localizedDescription)
        }
    }

    public func refreshSession(baseURL: String) async -> SourceCookieRefreshResult {
        let res = await verifySession(cookie: cookie, baseURL: baseURL)
        return SourceCookieRefreshResult(refreshed: res.passed, updatedCookieHeader: cookie, message: res.message)
    }

    public func currentCookieHeader() async -> String {
        cookie
    }

    // MARK: - Missing Chapter Link Repair

    private func resolveMissingChapterLinksIfNeeded(volumes: [VolumeItem]) async throws -> [VolumeItem] {
        var resolvedVolumes: [VolumeItem] = []
        for vol in volumes {
            var chaps = vol.chapters
            let hasMissing = chaps.contains { Self.isUnresolvedURL($0.url) }
            if hasMissing, chaps.count > 1 {
                // Backward fix using "上一页" link from subsequent resolved chapters (matches ShqWW/bilinovel-download)
                for idx in stride(from: chaps.count - 2, through: 0, by: -1) {
                    if Self.isUnresolvedURL(chaps[idx].url), !Self.isUnresolvedURL(chaps[idx + 1].url) {
                        if let nextHTML = try? await fetchHTML(urlString: chaps[idx + 1].url, referer: baseURL, stripAbsoluteParagraphs: false),
                           let prevHref = Self.extractPrevChapterLink(from: nextHTML, baseURL: baseURL) {
                            let c = chaps[idx]
                            chaps[idx] = ChapterItem(
                                id: c.id,
                                sourceId: c.sourceId,
                                title: c.title,
                                url: prevHref,
                                volumeIndex: c.volumeIndex,
                                chapterIndex: c.chapterIndex,
                                isIllustrationChapter: c.isIllustrationChapter
                            )
                        }
                    }
                }
            }
            resolvedVolumes.append(VolumeItem(id: vol.id, index: vol.index, title: vol.title, chapters: chaps))
        }
        return resolvedVolumes
    }

    public static func isUnresolvedURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.isEmpty || lower.contains("javascript") || lower.contains("cid") || lower.hasPrefix("unresolved:")
    }

    // MARK: - Static Parsers (Tested Standalone)

    public static func extractBookId(from rawInput: String) -> String {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.allSatisfy(\.isNumber) {
            return trimmed
        }
        if let regex = try? NSRegularExpression(pattern: #"/novel/(\d+)"#),
           let m = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r = Range(m.range(at: 1), in: trimmed) {
            return String(trimmed[r])
        }
        return ""
    }

    public struct ParsedBilinovelBookPage: Sendable {
        public let title: String
        public let author: String
        public let publisher: String
        public let status: String
        public let lastUpdated: String
        public let wordCount: String
        public let popularity: String
        public let latestChapter: String
        public let tags: [String]
        public let description: String
        public let coverURL: String
        public let recommendations: [RecommendedBook]
    }

    public static func parseBookPage(html: String, bookId: String, baseURL: String) throws -> ParsedBilinovelBookPage {
        let title = firstRegexGroup(#"<meta[^>]+property=["']og:novel:book_name["'][^>]+content=["']([^"']+)["']"#, in: html)
            ?? firstRegexGroup(#"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:novel:book_name["']"#, in: html)
            ?? firstRegexGroup(#"<h1[^>]*class=["']book-name["'][^>]*>([\s\S]*?)</h1>"#, in: html).map(HTTPRuntime.stripHTMLTags)
            ?? ""

        guard !title.isEmpty else {
            throw SourceError.parseError("未能解析哔哩轻小说书名（ID: \(bookId)）")
        }

        let author = firstRegexGroup(#"<meta[^>]+property=["']og:novel:author["'][^>]+content=["']([^"']+)["']"#, in: html)
            ?? firstRegexGroup(#"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:novel:author["']"#, in: html)
            ?? "未知"

        let status = firstRegexGroup(#"<meta[^>]+property=["']og:novel:status["'][^>]+content=["']([^"']+)["']"#, in: html) ?? ""
        let lastUpdated = firstRegexGroup(#"<meta[^>]+property=["']og:novel:update_time["'][^>]+content=["']([^"']+)["']"#, in: html) ?? ""
        let latestChapter = firstRegexGroup(#"<meta[^>]+property=["']og:novel:latest_chapter_name["'][^>]+content=["']([^"']+)["']"#, in: html) ?? ""

        let labelBlock = firstRegexGroup(#"<div[^>]*class=["'][^"']*book-label[^"']*["'][^>]*>([\s\S]*?)</div>"#, in: html) ?? ""
        let publisher = firstRegexGroup(#"<a[^>]*class=["'][^"']*label[^"']*["'][^>]*>([\s\S]*?)</a>"#, in: labelBlock)
            .map(HTTPRuntime.stripHTMLTags) ?? ""

        var tags: [String] = []
        if let spanBlock = firstRegexGroup(#"<span[^>]*>([\s\S]*?)</span>"#, in: labelBlock) {
            tags = allRegexGroups(#"<a[^>]*>([\s\S]*?)</a>"#, in: spanBlock)
                .map(HTTPRuntime.stripHTMLTags)
                .filter { !$0.isEmpty }
        }

        var brief = ""
        if let decBlock = firstRegexGroup(#"<div[^>]*class=["'][^"']*book-dec[^"']*["'][^>]*>([\s\S]*?)</div>"#, in: html) {
            brief = firstRegexGroup(#"<p[^>]*>([\s\S]*?)</p>"#, in: decBlock)
                .map { HTTPRuntime.stripHTMLTags($0.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)) } ?? ""
        }

        let coverBlock = firstRegexGroup(#"<div[^>]*class=["'][^"']*book-img[^"']*["'][^>]*>([\s\S]*?)</div>"#, in: html) ?? ""
        let rawCover = firstRegexGroup(#"<img[^>]+src=["']([^"']+)["']"#, in: coverBlock) ?? ""
        let coverURL = rawCover.isEmpty ? "" : HTTPRuntime.resolveURL(rawCover, baseURL: baseURL)

        var recs: [RecommendedBook] = []
        let recMatches = allRegexGroups(#"<a[^>]+href=["'](/novel/(\d+)\.html)["'][^>]*title=["']([^"']+)["']"#, in: html)
        if !recMatches.isEmpty {
            // Alternate regex capture helper for paired groups
            let recRegex = try? NSRegularExpression(pattern: #"<a[^>]+href=["']/novel/(\d+)\.html["'][^>]*title=["']([^"']+)["']"#)
            let ns = html as NSString
            for m in recRegex?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? [] {
                if m.numberOfRanges >= 3 {
                    let rid = ns.substring(with: m.range(at: 1))
                    let rtitle = HTTPRuntime.unescapeHTML(ns.substring(with: m.range(at: 2)))
                    if rid != bookId && !recs.contains(where: { $0.id == rid }) {
                        recs.append(RecommendedBook(id: rid, sourceId: "bilinovel", title: rtitle, coverURL: "", isCompleted: false))
                    }
                }
            }
        }

        return ParsedBilinovelBookPage(
            title: HTTPRuntime.unescapeHTML(title),
            author: HTTPRuntime.unescapeHTML(author),
            publisher: publisher,
            status: status,
            lastUpdated: lastUpdated,
            wordCount: "",
            popularity: "",
            latestChapter: latestChapter,
            tags: tags,
            description: brief,
            coverURL: coverURL,
            recommendations: Array(recs.prefix(12))
        )
    }

    public static func parseCatalogPage(html: String, bookTitle: String, baseURL: String, bookId: String = "") -> [VolumeItem] {
        var volumes: [VolumeItem] = []
        let volPattern = #"<div[^>]*class=["'][^"']*volume\s+clearfix[^"']*["'][^>]*>([\s\S]*?)</ul>\s*</div>"#
        guard let volRegex = try? NSRegularExpression(pattern: volPattern) else { return [] }
        let nsHTML = html as NSString
        let volMatches = volRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        let chapRegex = try? NSRegularExpression(pattern: #"<li[^>]*class=["'][^"']*col-4[^"']*["'][^>]*>[\s\S]*?<a[^>]+href=["']([^"']*)["'][^>]*>([\s\S]*?)</a>"#)
        let idScope = bookId.isEmpty ? "" : "\(bookId)_"

        for (vIdx, vm) in volMatches.enumerated() {
            let block = nsHTML.substring(with: vm.range(at: 1))
            var volTitle = firstRegexGroup(#"<h2[^>]*class=["'][^"']*v-line[^"']*["'][^>]*>([\s\S]*?)</h2>"#, in: block)
                .map(HTTPRuntime.stripHTMLTags) ?? "第 \(vIdx + 1) 卷"
            if !bookTitle.isEmpty {
                volTitle = volTitle.replacingOccurrences(of: bookTitle + " ", with: "")
            }

            var chapters: [ChapterItem] = []
            let nsBlock = block as NSString
            let chapMatches = chapRegex?.matches(in: block, range: NSRange(location: 0, length: nsBlock.length)) ?? []
            for (cIdx, cm) in chapMatches.enumerated() where cm.numberOfRanges >= 3 {
                let rawHref = nsBlock.substring(with: cm.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawTitle = HTTPRuntime.stripHTMLTags(nsBlock.substring(with: cm.range(at: 2)))
                let resolvedURL: String
                if rawHref.isEmpty || rawHref.lowercased().contains("javascript") || rawHref.lowercased().contains("cid") {
                    resolvedURL = "unresolved:\(vIdx + 1):\(cIdx + 1)"
                } else {
                    resolvedURL = HTTPRuntime.resolveURL(rawHref, baseURL: baseURL)
                }

                let chapId = "bili_\(idScope)v\(vIdx + 1)_c\(cIdx + 1)"
                let isIllus = rawTitle == "插图" || rawTitle == "彩页" || rawTitle.contains("插图")
                chapters.append(
                    ChapterItem(
                        id: chapId,
                        sourceId: "bilinovel",
                        title: rawTitle,
                        url: resolvedURL,
                        volumeIndex: vIdx + 1,
                        chapterIndex: cIdx + 1,
                        isIllustrationChapter: isIllus
                    )
                )
            }

            if !chapters.isEmpty {
                volumes.append(VolumeItem(id: "bili_\(idScope)vol_\(vIdx + 1)", index: vIdx + 1, title: volTitle, chapters: chapters))
            }
        }
        return volumes
    }

    public struct ParsedBilinovelChapterPage: Sendable {
        public let tokens: [ChapterToken]
        public let imageURLs: [String]
        public let nextSubpageURL: String?
        public let unresolvedPUACount: Int
    }

    public static func parseChapterPageHTML(
        html: String,
        chapterURL: String,
        baseChapterURL: String,
        pageIndex: Int,
        baseURL: String
    ) -> ParsedBilinovelChapterPage {
        let usesWoff2 = html.contains("woff2")

        // Extract TextContent body with balanced nested <div> handling
        var contentHTML = extractElementInnerHTML(divId: "TextContent", in: html) ?? ""

        // Cut notice block if present
        let noticeMarker = "————————————以下为告示，读者请无视——————————————"
        if let range = contentHTML.range(of: noticeMarker) {
            contentHTML = String(contentHTML[..<range.lowerBound])
        }

        // Remove known noise elements, inline position:absolute decoy paragraphs & HTML comments
        let noisePatterns = [
            #"<!--[\s\S]*?-->"#,
            #"<div[^>]*id=["'](?:show-more-images|hidden-images)["'][^>]*>[\s\S]*?</div>"#,
            #"<div[^>]*class=["'][^"']*(?:google-auto-placed|dag)[^"']*["'][^>]*>[\s\S]*?</div>"#,
            #"<p[^>]*style=["'][^"']*position\s*:\s*absolute[^"']*["'][^>]*>[\s\S]*?</p>"#,
            #"<p[^>]*style=["'][^"']*display\s*:\s*none[^"']*["'][^>]*>[\s\S]*?</p>"#,
            #"<p\d+[^>]*>[\s\S]*?</p\d+>"#,
            #"<script[\s\S]*?</script>"#,
        ]
        for pattern in noisePatterns {
            contentHTML = contentHTML.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        var tokens: [ChapterToken] = []
        var imageURLs: [String] = []
        var seenImages = Set<String>()
        var unresolvedPUACount = 0

        // Walk `<p>...</p>` and `<img ...>` in document order
        let tokenPattern = #"<p[^>]*>([\s\S]*?)</p>|<img[^>]+>"#
        if let regex = try? NSRegularExpression(pattern: tokenPattern, options: [.caseInsensitive]) {
            let ns = contentHTML as NSString
            let matches = regex.matches(in: contentHTML, range: NSRange(location: 0, length: ns.length))
            var paragraphIndices: [Int] = []

            for m in matches {
                let fullTag = ns.substring(with: m.range)
                if fullTag.lowercased().hasPrefix("<img") {
                    if let imgURL = extractNormalizedImageURL(fromImgTag: fullTag, baseURL: baseURL) {
                        tokens.append(.image(imgURL))
                        if seenImages.insert(imgURL).inserted {
                            imageURLs.append(imgURL)
                        }
                    }
                } else if m.numberOfRanges > 1 {
                    let inner = ns.substring(with: m.range(at: 1))
                    // Handle inline images embedded inside <p>
                    let inlineImgs = allRegexGroups(#"(<img[^>]+>)"#, in: inner)
                    if !inlineImgs.isEmpty {
                        for imgTag in inlineImgs {
                            if let imgURL = extractNormalizedImageURL(fromImgTag: imgTag, baseURL: baseURL) {
                                tokens.append(.image(imgURL))
                                if seenImages.insert(imgURL).inserted {
                                    imageURLs.append(imgURL)
                                }
                            }
                        }
                    }
                    let cleanedText = HTTPRuntime.stripHTMLTags(inner)
                    if !cleanedText.isEmpty {
                        paragraphIndices.append(tokens.count)
                        tokens.append(.paragraph(cleanedText))
                    }
                }
            }

            // Restore PUA scrambled characters on affected paragraphs and detect unmapped drift
            for idx in paragraphIndices {
                if case .paragraph(let txt) = tokens[idx] {
                    if usesWoff2 || BilinovelSecretMap.containsPrivateUseCharacters(txt) {
                        let decoded = BilinovelSecretMap.decodeParagraphWithStats(txt)
                        tokens[idx] = .paragraph(decoded.text)
                        unresolvedPUACount += decoded.unmappedPUACount
                    }
                }
            }
        }

        // Detect paginated next page: `/novel/2704/12345_2.html`
        let nextRel = baseChapterURL
            .replacingOccurrences(of: baseURL, with: "")
            .replacingOccurrences(of: ".html", with: "_\(pageIndex + 1).html")
        let nextSubpageURL = (!nextRel.isEmpty && html.contains(nextRel))
            ? HTTPRuntime.resolveURL(nextRel, baseURL: baseURL)
            : nil

        return ParsedBilinovelChapterPage(
            tokens: tokens,
            imageURLs: imageURLs,
            nextSubpageURL: nextSubpageURL,
            unresolvedPUACount: unresolvedPUACount
        )
    }

    public static func extractPrevChapterLink(from html: String, baseURL: String) -> String? {
        if let href = firstRegexGroup(#"<div[^>]*class=["'][^"']*mlfy_page[^"']*["'][^>]*>[\s\S]*?<a[^>]+href=["']([^"']+)["'][^>]*>\s*上一页\s*</a>"#, in: html),
           !isUnresolvedURL(href) {
            return HTTPRuntime.resolveURL(href, baseURL: baseURL)
        }
        return nil
    }

    public static func parseBookListPage(html: String, baseURL: String, currentPage: Int) -> PagedBookResult {
        var items: [AuthorBookItem] = []
        let liPattern = #"<li[^>]*class=["'][^"']*book-li[^"']*["'][^>]*>([\s\S]*?)</li>"#
        let ns = html as NSString
        let liMatches = (try? NSRegularExpression(pattern: liPattern))?.matches(in: html, range: NSRange(location: 0, length: ns.length)) ?? []

        for m in liMatches {
            let block = ns.substring(with: m.range(at: 1))
            guard let href = firstRegexGroup(#"href=["'](/novel/\d+\.html)["']"#, in: block) else { continue }
            let bookId = extractBookId(from: href)
            guard !bookId.isEmpty else { continue }

            let title = firstRegexGroup(#"<h4[^>]*class=["'][^"']*book-title[^"']*["'][^>]*>([\s\S]*?)</h4>"#, in: block).map(HTTPRuntime.stripHTMLTags)
                ?? firstRegexGroup(#"title=["']([^"']+)["']"#, in: block).map(HTTPRuntime.unescapeHTML)
                ?? ""
            guard !title.isEmpty else { continue }

            let author = firstRegexGroup(#"<span[^>]*class=["'][^"']*book-author[^"']*["'][^>]*>([\s\S]*?)</span>"#, in: block)
                .map { HTTPRuntime.stripHTMLTags($0).replacingOccurrences(of: "作者：", with: "") } ?? ""
            let summary = firstRegexGroup(#"<p[^>]*class=["'][^"']*book-desc[^"']*["'][^>]*>([\s\S]*?)</p>"#, in: block)
                .map(HTTPRuntime.stripHTMLTags) ?? ""
            let rawCover = firstRegexGroup(#"data-original=["']([^"']+)["']"#, in: block)
                ?? firstRegexGroup(#"<img[^>]+src=["']([^"']+)["']"#, in: block)
                ?? ""
            let coverURL = rawCover.isEmpty ? "" : HTTPRuntime.resolveURL(rawCover, baseURL: baseURL)
            let tags = allRegexGroups(#"<em[^>]*class=["'][^"']*tag[^"']*["'][^>]*>([\s\S]*?)</em>"#, in: block)
                .map(HTTPRuntime.stripHTMLTags)
                .filter { !$0.isEmpty }

            items.append(AuthorBookItem(
                id: bookId,
                sourceId: "bilinovel",
                title: title,
                author: author,
                category: tags.first ?? "",
                updatedAt: "",
                wordCount: "",
                status: "",
                popularity: "",
                tags: tags,
                summary: summary,
                coverURL: coverURL
            ))
        }

        let totalPages = Int(firstRegexGroup(#"class=["'][^"']*last["'][^>]*>(\d+)<"#, in: html) ?? "") ?? max(1, currentPage)
        return PagedBookResult(items: items, currentPage: currentPage, totalPages: max(currentPage, totalPages))
    }

    // MARK: - Balanced Tag & Regex Micro Helpers

    private static func extractElementInnerHTML(divId: String, in html: String) -> String? {
        let openPattern = #"<div[^>]*\bid=["']"# + NSRegularExpression.escapedPattern(for: divId) + #"["'][^>]*>"#
        guard let openRegex = try? NSRegularExpression(pattern: openPattern, options: [.caseInsensitive]),
              let tagRegex = try? NSRegularExpression(pattern: #"<div\b[^>]*>|</div>"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = html as NSString
        guard let openMatch = openRegex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let contentStart = openMatch.range.location + openMatch.range.length
        let remainingRange = NSRange(location: contentStart, length: ns.length - contentStart)
        let matches = tagRegex.matches(in: html, range: remainingRange)
        var depth = 1
        for m in matches {
            let token = ns.substring(with: m.range).lowercased()
            if token.hasPrefix("</div") {
                depth -= 1
                if depth == 0 {
                    let innerRange = NSRange(location: contentStart, length: m.range.location - contentStart)
                    return ns.substring(with: innerRange)
                }
            } else {
                depth += 1
            }
        }
        return ns.substring(from: contentStart)
    }

    private static func extractNormalizedImageURL(fromImgTag tag: String, baseURL: String) -> String? {
        let rawSrc = firstRegexGroup(#"data-src=["']([^"']+)["']"#, in: tag)
            ?? firstRegexGroup(#"src=["']([^"']+)["']"#, in: tag)
            ?? ""
        let trimmed = rawSrc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("data:") else { return nil }
        if let m = firstRegexGroup(#"\.[a-zA-Z]{3}/(.*?\.(?:jpg|png|jpeg|webp))"#, in: trimmed) {
            return "https://img3.readpai.com/\(m)"
        }
        return HTTPRuntime.resolveURL(trimmed, baseURL: baseURL)
    }

    private static func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func allRegexGroups(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }
}
