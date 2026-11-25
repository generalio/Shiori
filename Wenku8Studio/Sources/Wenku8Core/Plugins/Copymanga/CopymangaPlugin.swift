import Foundation

/// Copymanga (拷贝漫画) App API v3 plugin supporting comic search, discovery channels,
/// multi-group chapters (`default` / `tankobon`), `words`-ordered chapter image extraction,
/// HD/SD image quality toggle, and optional Token-authenticated personal CloudShelf sync.
public actor CopymangaPlugin: BookSourcePlugin, DiscoveryCapableSource, AuthenticatedSource, CloudBookshelfCapableSource {
    public static let officialMirrors = [
        "https://mapi.hotmangasd.com",
        "https://api.mangacopy.com",
        "https://api.copy2000.online",
        "https://api.copy-manga.com",
    ]

    public static let deprecatedMirrorHosts: Set<String> = [
        "api.2025copy.com",
        "api.copymanga.site",
        "api.copymanga.tv",
    ]

    public nonisolated let descriptor = BookSourceDescriptor(
        id: "copymanga",
        displayName: "拷贝漫画",
        shortBadge: "拷贝",
        subtitle: "App API v3 · 支持搜漫、连载/单行本分组、高清画质切换、自动镜像容灾与 Token 云收藏",
        defaultMirrors: officialMirrors,
        supportedSearchScopes: [.articleName, .author, .bookId],
        requiresBrowserRuntime: false,
        contentKind: .manga
    )

    private var baseURL: String
    private var authorizationToken: String
    private var userAgent: String
    private var cdnRegion: String
    private var preferHighQualityImages: Bool
    private var requestTimeout: TimeInterval
    private var politeDelaySeconds: Double
    private let httpRuntime: HTTPRuntime

    public init(
        baseURL: String = "https://mapi.hotmangasd.com",
        authorizationToken: String = "",
        userAgent: String = "COPY/3.0.6",
        cdnRegion: String = "1",
        preferHighQualityImages: Bool = true,
        timeout: TimeInterval = 18,
        politeDelaySeconds: Double = 0.4,
        httpRuntime: HTTPRuntime? = nil
    ) {
        self.baseURL = Self.normalizeAPIBaseURL(baseURL)
        self.authorizationToken = Self.normalizeToken(authorizationToken)
        self.userAgent = userAgent.isEmpty ? "COPY/3.0.6" : userAgent
        self.cdnRegion = cdnRegion.isEmpty ? "1" : cdnRegion
        self.preferHighQualityImages = preferHighQualityImages
        self.requestTimeout = timeout
        self.politeDelaySeconds = politeDelaySeconds
        self.httpRuntime = httpRuntime ?? HTTPRuntime(timeout: timeout)
    }

    public static func migrateLegacyMirrorIfNeeded(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return officialMirrors[0] }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        if let host = URL(string: withScheme)?.host?.lowercased(),
           deprecatedMirrorHosts.contains(host) {
            return officialMirrors[0]
        }
        return Wenku8Client.normalizeBaseURL(withScheme)
    }

    public static func normalizeAPIBaseURL(_ raw: String) -> String {
        migrateLegacyMirrorIfNeeded(raw)
    }

    public static func normalizeToken(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("token ") {
            s = String(s.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lower.hasPrefix("bearer ") {
            s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    public nonisolated func canHandle(rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("copy:") || lower.hasPrefix("copymanga:") {
            let suffix = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let slug = Self.extractPathWord(from: suffix)
            return slug.isEmpty ? nil : slug
        }

        if lower.contains("copymanga") || lower.contains("mangacopy") || lower.contains("copy-manga")
            || lower.contains("2025copy") || lower.contains("copy2000") || lower.contains("copy4000")
            || lower.contains("copy20") || lower.contains("hotmangasd") {
            let slug = Self.extractPathWord(from: trimmed)
            return slug.isEmpty ? nil : slug
        }

        // Pure ASCII slug with letters (e.g. yaoyeluying) — never steal bare numeric IDs from novel sources
        if !trimmed.allSatisfy(\.isNumber),
           trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil {
            return trimmed.lowercased()
        }
        return nil
    }

    public static func extractPathWord(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let regex = try? NSRegularExpression(pattern: #"/comic/([a-zA-Z0-9_-]+)"#, options: .caseInsensitive) {
            let ns = trimmed as NSString
            if let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        if !trimmed.contains("/") && !trimmed.contains(" ") {
            return trimmed
        }
        return ""
    }

    public func updateConfig(_ config: SourceRuntimeConfig) async {
        baseURL = Self.normalizeAPIBaseURL(config.baseURL)
        authorizationToken = Self.normalizeToken(config.authorizationToken.isEmpty ? config.cookie : config.authorizationToken)
        let ua = config.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ua.isEmpty && ua != HTTPRuntime.defaultUserAgent {
            userAgent = ua
        } else {
            userAgent = "COPY/3.0.6"
        }
        cdnRegion = config.cdnRegion.isEmpty ? "1" : config.cdnRegion
        preferHighQualityImages = config.preferHighQualityImages
        requestTimeout = max(5, config.requestTimeout)
        politeDelaySeconds = max(0, config.politeDelaySeconds)
    }

    public func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async {
        // Copymanga uses App API v3 JSON directly; no browser DOM runtime required.
    }

    // MARK: - API Request Helpers

    private func apiHeaders(includeAuth: Bool = true) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "source": "copyApp",
            "webp": "1",
            "region": cdnRegion,
            "platform": "3",
            "version": "3.0.6"
        ]
        if includeAuth && !authorizationToken.isEmpty {
            headers["authorization"] = "Token \(authorizationToken)"
        }
        return headers
    }

    private func relativePathAndQuery(from input: String) -> String {
        if input.hasPrefix("http://") || input.hasPrefix("https://"),
           let url = URL(string: input) {
            var rel = url.path
            if let q = url.query, !q.isEmpty {
                rel += "?\(q)"
            }
            return rel
        }
        return input.hasPrefix("/") ? input : "/\(input)"
    }

    private func candidateMirrors() -> [String] {
        var list = [baseURL]
        for mirror in Self.officialMirrors where !list.contains(mirror) {
            list.append(mirror)
        }
        return list
    }

    private func fetchAPIJSON(
        pathAndQuery: String,
        includeAuth: Bool = true,
        requireNonNullResults: Bool = true,
        maxThrottleRetries: Int = 2
    ) async throws -> [String: Any] {
        let rel = relativePathAndQuery(from: pathAndQuery)
        let mirrors = candidateMirrors()
        var lastError: Error = SourceError.networkError("拷贝漫画所有可用镜像均请求失败")

        for (mirrorIdx, mirrorBase) in mirrors.enumerated() {
            do {
                let obj = try await fetchSingleMirrorJSON(
                    base: mirrorBase,
                    relPathAndQuery: rel,
                    includeAuth: includeAuth,
                    requireNonNullResults: requireNonNullResults,
                    maxThrottleRetries: maxThrottleRetries
                )
                if mirrorIdx > 0 {
                    // Remember healthy fallback mirror for subsequent calls in this session
                    baseURL = mirrorBase
                }
                return obj
            } catch let err as SourceError {
                lastError = err
                switch err {
                case .loginRequired, .invalidInput, .rateLimited:
                    // Auth / input / throttle errors are not fixed by mirror hopping
                    throw err
                case .notFound:
                    // A genuine 404 on a live mirror should surface immediately (caller may try alternate path)
                    throw err
                case .networkError, .mirrorUnavailable, .challengeRequired, .httpError, .parseError, .sourceNotFound:
                    // Try next healthy mirror automatically
                    continue
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func fetchSingleMirrorJSON(
        base: String,
        relPathAndQuery: String,
        includeAuth: Bool,
        requireNonNullResults: Bool,
        maxThrottleRetries: Int
    ) async throws -> [String: Any] {
        let fullStr = "\(base)\(relPathAndQuery)"
        guard let url = URL(string: fullStr) else {
            throw SourceError.invalidInput("无效拷贝漫画 API 地址：\(fullStr)")
        }

        var attempt = 0
        while true {
            await httpRuntime.enforceRateLimit(hostKey: descriptor.id, minDelaySeconds: politeDelaySeconds)
            let raw = try await httpRuntime.fetchRaw(
                url: url,
                referer: "com.copymanga.app-3.0.6",
                userAgent: userAgent,
                extraHeaders: apiHeaders(includeAuth: includeAuth),
                timeout: requestTimeout
            )

            if raw.statusCode == 401 {
                throw SourceError.loginRequired(sourceId: descriptor.id, message: "拷贝漫画 Token 无效或已过期，请重新导入 Token")
            }
            if raw.statusCode == 404 {
                throw SourceError.notFound("拷贝漫画中未找到该作品或章节（HTTP 404）")
            }
            if raw.statusCode == 429 {
                if attempt < maxThrottleRetries {
                    attempt += 1
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                    continue
                }
                throw SourceError.rateLimited(sourceId: descriptor.id, message: "拷贝漫画请求过于频繁（HTTP 429），请稍后重试")
            }

            let text = HTTPRuntime.decodeText(raw.data, preference: .utf8)
            if HTTPRuntime.looksLikeCloudflareChallenge(text, statusCode: raw.statusCode) {
                throw SourceError.challengeRequired(
                    sourceId: descriptor.id,
                    url: fullStr,
                    message: "当前拷贝漫画镜像触发风控拦截，请在设置中切换 API 镜像域名"
                )
            }

            guard (200..<400).contains(raw.statusCode) else {
                throw SourceError.httpError(raw.statusCode, fullStr)
            }

            guard let obj = try? JSONSerialization.jsonObject(with: raw.data) as? [String: Any] else {
                throw SourceError.parseError("拷贝漫画 API 返回非 JSON 内容")
            }

            let code = obj["code"] as? Int ?? 200
            let msg = (obj["message"] as? String) ?? ""
            if msg.lowercased().contains("throttl") || msg.contains("频繁") || code == 429 {
                if attempt < maxThrottleRetries {
                    attempt += 1
                    try? await Task.sleep(for: .milliseconds(500 * attempt))
                    continue
                }
                throw SourceError.rateLimited(sourceId: descriptor.id, message: "拷贝漫画接口限流：\(msg.isEmpty ? "请稍后重试" : msg)")
            }
            if code == 210 {
                throw SourceError.mirrorUnavailable(
                    sourceId: descriptor.id,
                    message: "当前拷贝漫画接口镜像受限（code 210：\(msg)），请在「设置 → 拷贝漫画」切换其他镜像域名"
                )
            }
            if code == 401 || code == 403 {
                throw SourceError.loginRequired(sourceId: descriptor.id, message: "拷贝漫画认证失败：\(msg)")
            }
            if code != 200 {
                throw SourceError.parseError("拷贝漫画 API 错误（code \(code)）：\(msg)")
            }
            if requireNonNullResults {
                let resVal = obj["results"]
                if resVal == nil || resVal is NSNull {
                    throw SourceError.mirrorUnavailable(
                        sourceId: descriptor.id,
                        message: "当前拷贝漫画镜像返回空数据（可能需要客户端签名），正在尝试切换备用镜像"
                    )
                }
            }
            return obj
        }
    }

    // MARK: - Core BookSourcePlugin

    public func search(query: String, scope: SearchScope, page: Int) async throws -> PagedBookResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            throw SourceError.invalidInput("请输入漫画搜索关键词")
        }

        if scope == .bookId, let slug = canHandle(rawInput: q) {
            let detail = try await fetchBookDetail(bookIdOrURL: slug, onProgress: nil)
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

        let limit = 20
        let safePage = max(1, page)
        let offset = (safePage - 1) * limit
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        let qType = scope == .author ? "author" : ""
        let json = try await fetchAPIJSON(
            pathAndQuery: "/api/v3/search/comic?limit=\(limit)&offset=\(offset)&q=\(encoded)&q_type=\(qType)&platform=3"
        )
        let results = (json["results"] as? [String: Any]) ?? [:]
        let total = results["total"] as? Int ?? 0
        let list = (results["list"] as? [[String: Any]]) ?? []
        let items = list.compactMap { Self.parseComicListItem($0) }
        let totalPages = max(1, Int(ceil(Double(max(total, items.count)) / Double(limit))))
        return PagedBookResult(items: items, currentPage: safePage, totalPages: totalPages)
    }

    public func fetchBookDetail(
        bookIdOrURL: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> BookDetail {
        let slug = Self.extractPathWord(from: bookIdOrURL)
        guard !slug.isEmpty else {
            throw SourceError.invalidInput("无法识别拷贝漫画标识：\(bookIdOrURL)")
        }

        onProgress?("正在拉取拷贝漫画详情...")
        let detailJSON = try await fetchAPIJSON(pathAndQuery: "/api/v3/comic2/\(slug)?platform=3")
        guard let results = detailJSON["results"] as? [String: Any],
              let comic = results["comic"] as? [String: Any] else {
            throw SourceError.parseError("未能解析拷贝漫画详情：\(slug)")
        }

        let title = (comic["name"] as? String) ?? slug
        let authors = ((comic["author"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: " / ")
        let brief = (comic["brief"] as? String) ?? ""
        let cover = (comic["cover"] as? String) ?? ""
        let updated = (comic["datetime_updated"] as? String) ?? ""
        let status = ((comic["status"] as? [String: Any])?["display"] as? String) ?? ""
        let popularNum = comic["popular"] as? Int ?? 0
        let popularity = popularNum > 0 ? "人气 \(popularNum)" : ""
        let tags = ((comic["theme"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }

        // Parse WorkGroups (prefer `default` first, then alphabetical/others)
        let rawGroups = (results["groups"] as? [String: [String: Any]]) ?? [:]
        let sortedGroupEntries: [(key: String, pathWord: String, name: String)] = rawGroups.map { k, v in
            let pw = (v["path_word"] as? String) ?? k
            let name = (v["name"] as? String) ?? k
            return (k, pw, name)
        }.sorted { lhs, rhs in
            if lhs.pathWord == "default" { return true }
            if rhs.pathWord == "default" { return false }
            return lhs.name < rhs.name
        }

        let groupsToFetch = sortedGroupEntries.isEmpty
            ? [("default", "default", "默认")]
            : sortedGroupEntries

        var volumes: [VolumeItem] = []
        for (gIdx, grp) in groupsToFetch.enumerated() {
            onProgress?("正在拉取「\(grp.name)」章节目录...")
            let chapters = try await fetchGroupChapters(
                comicPathWord: slug,
                groupPathWord: grp.pathWord,
                volumeIndex: gIdx + 1
            )
            if !chapters.isEmpty {
                volumes.append(VolumeItem(
                    id: "copy_\(slug)_\(grp.pathWord)",
                    index: gIdx + 1,
                    title: grp.name == "默认" ? "连载话（默认）" : grp.name,
                    chapters: chapters
                ))
            }
        }

        let latestChap = volumes.first?.chapters.last?.title ?? ""
        let totalChaps = volumes.reduce(0) { $0 + $1.chapters.count }
        return BookDetail(
            bookId: slug,
            sourceId: descriptor.id,
            contentKind: .manga,
            baseURL: baseURL,
            title: title,
            author: authors.isEmpty ? "未知作者" : authors,
            publisher: "拷贝漫画",
            status: status,
            lastUpdated: updated,
            wordCount: "共 \(totalChaps) 话",
            popularity: popularity,
            latestChapter: latestChap,
            tags: tags,
            description: brief,
            coverURL: cover,
            catalogURL: "\(baseURL)/api/v3/comic2/\(slug)?platform=3",
            volumes: volumes,
            recommendations: []
        )
    }

    private func fetchGroupChapters(
        comicPathWord: String,
        groupPathWord: String,
        volumeIndex: Int
    ) async throws -> [ChapterItem] {
        var allRaw: [[String: Any]] = []
        var offset = 0
        let limit = 500
        var total = Int.max

        while offset < total {
            let json = try await fetchAPIJSON(
                pathAndQuery: "/api/v3/comic/\(comicPathWord)/group/\(groupPathWord)/chapters?limit=\(limit)&offset=\(offset)&platform=3"
            )
            let results = (json["results"] as? [String: Any]) ?? [:]
            let list = (results["list"] as? [[String: Any]]) ?? []
            if list.isEmpty { break }
            allRaw.append(contentsOf: list)
            total = results["total"] as? Int ?? allRaw.count
            offset += limit
            if list.count < limit { break }
        }

        // Sort ascending by `index` (default reading order: chapter 1 -> latest)
        let sorted = allRaw.enumerated().sorted { lhs, rhs in
            let li = (lhs.element["index"] as? Int) ?? lhs.offset
            let ri = (rhs.element["index"] as? Int) ?? rhs.offset
            return li < ri
        }

        return sorted.enumerated().compactMap { pos, item in
            let dict = item.element
            guard let uuid = dict["uuid"] as? String, !uuid.isEmpty else { return nil }
            let name = (dict["name"] as? String) ?? "第 \(pos + 1) 话"
            let chapterURL = "/api/v3/comic/\(comicPathWord)/chapter/\(uuid)?platform=3"
            return ChapterItem(
                id: "copy_\(comicPathWord)_\(uuid)",
                sourceId: descriptor.id,
                title: name,
                url: chapterURL,
                volumeIndex: volumeIndex,
                chapterIndex: pos + 1,
                isIllustrationChapter: false
            )
        }
    }

    public func fetchChapterContent(chapter: ChapterItem, book: BookDetail) async throws -> ChapterContent {
        let json: [String: Any]
        do {
            json = try await fetchAPIJSON(pathAndQuery: chapter.url)
        } catch SourceError.notFound {
            // Fallback cleanly between /chapter/{uuid} and /chapter2/{uuid} across mirror generations
            let alternateURL: String
            if chapter.url.contains("/chapter2/") {
                alternateURL = chapter.url.replacingOccurrences(of: "/chapter2/", with: "/chapter/")
            } else {
                alternateURL = chapter.url.replacingOccurrences(of: "/chapter/", with: "/chapter2/")
            }
            json = try await fetchAPIJSON(pathAndQuery: alternateURL)
        }

        guard let results = json["results"] as? [String: Any],
              let chapObj = results["chapter"] as? [String: Any] else {
            throw SourceError.parseError("未能解析拷贝漫画章节图片列表：\(chapter.title)")
        }

        let rawContents = ((chapObj["contents"] as? [[String: Any]]) ?? []).compactMap { $0["url"] as? String }
        let words = (chapObj["words"] as? [Int]) ?? []

        // Restore true page order via `chapter.words` when present
        var orderedURLs: [String]
        if words.count == rawContents.count && !rawContents.isEmpty {
            var slots = Array(repeating: "", count: rawContents.count)
            var validOrder = true
            for (idx, rawURL) in rawContents.enumerated() {
                let targetSlot = words[idx]
                if targetSlot >= 0 && targetSlot < slots.count {
                    slots[targetSlot] = rawURL
                } else {
                    validOrder = false
                    break
                }
            }
            orderedURLs = validOrder ? slots.filter { !$0.isEmpty } : rawContents
        } else {
            orderedURLs = rawContents
        }

        orderedURLs = orderedURLs.map { urlStr in
            if preferHighQualityImages {
                return urlStr
                    .replacingOccurrences(of: ".c800x.", with: ".c1500x.")
                    .replacingOccurrences(of: "c800x", with: "c1500x")
            } else {
                return urlStr
                    .replacingOccurrences(of: ".c1500x.", with: ".c800x.")
                    .replacingOccurrences(of: "c1500x", with: "c800x")
            }
        }

        let tokens = orderedURLs.map { ChapterToken.image($0) }
        return ChapterContent(
            chapter: chapter,
            tokens: tokens,
            imageURLs: orderedURLs,
            contentKind: .manga
        )
    }

    public func downloadImage(url: String, referer: String?) async throws -> DownloadedImageAsset {
        try await httpRuntime.downloadSingleImage(
            urlString: url,
            referer: "com.copymanga.app-3.0.6",
            cookie: "",
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
            referer: "com.copymanga.app-3.0.6",
            cookie: "",
            userAgent: userAgent,
            maxConcurrency: maxConcurrency,
            onProgress: onProgress
        )
    }

    // MARK: - DiscoveryCapableSource

    public nonisolated func discoveryChannels() -> [DiscoveryChannel] {
        [
            DiscoveryChannel(sourceId: descriptor.id, title: "热门漫画", path: "/api/v3/comics?limit=20&offset=0&ordering=-popular&platform=3", icon: "flame.fill"),
            DiscoveryChannel(sourceId: descriptor.id, title: "最近更新", path: "/api/v3/comics?limit=20&offset=0&ordering=-datetime_updated&platform=3", icon: "clock.arrow.circlepath"),
            DiscoveryChannel(sourceId: descriptor.id, title: "完结漫画", path: "/api/v3/comics?limit=20&offset=0&ordering=-popular&status=1&platform=3", icon: "checkmark.seal.fill"),
        ]
    }

    public func fetchChannelBooks(channel: DiscoveryChannel, page: Int) async throws -> PagedBookResult {
        let limit = 20
        let safePage = max(1, page)
        let offset = (safePage - 1) * limit
        let path = channel.path.replacingOccurrences(of: "offset=0", with: "offset=\(offset)")
        let json = try await fetchAPIJSON(pathAndQuery: path)
        let results = (json["results"] as? [String: Any]) ?? [:]
        let total = results["total"] as? Int ?? 0
        let list = (results["list"] as? [[String: Any]]) ?? []
        let items = list.compactMap { Self.parseComicListItem($0) }
        let totalPages = max(1, Int(ceil(Double(max(total, items.count)) / Double(limit))))
        return PagedBookResult(items: items, currentPage: safePage, totalPages: totalPages)
    }

    public func fetchTagGroups() async throws -> [TagGroup] {
        []
    }

    public func fetchBooksByTag(tag: String, sort: TagSortOption, page: Int) async throws -> PagedBookResult {
        try await search(query: tag, scope: .articleName, page: page)
    }

    // MARK: - AuthenticatedSource

    public nonisolated func loginURL(baseURL: String) -> URL {
        URL(string: "https://www.mangacopy.com/web/login/loginByAccount")!
    }

    public nonisolated func diagnoseCookie(_ raw: String) -> SourceAuthCookieDiagnostic {
        let tok = Self.normalizeToken(raw)
        if tok.isEmpty {
            return SourceAuthCookieDiagnostic(
                isLikelyValidFormat: false,
                isForeignSiteCookie: false,
                message: "拷贝漫画公开搜漫与阅读无需登录；如需同步个人云端书架，请粘贴 Authorization Token 或 cURL。",
                normalizedCookie: ""
            )
        }
        return SourceAuthCookieDiagnostic(
            isLikelyValidFormat: tok.count >= 8,
            isForeignSiteCookie: false,
            message: "检测到拷贝漫画 Authorization Token。",
            normalizedCookie: tok
        )
    }

    public func verifySession(cookie: String, baseURL: String) async -> SourceVerifyResult {
        if !baseURL.isEmpty {
            self.baseURL = Self.normalizeAPIBaseURL(baseURL)
        }
        let tok = Self.normalizeToken(cookie)
        if !tok.isEmpty {
            self.authorizationToken = tok
        }

        do {
            if self.authorizationToken.isEmpty {
                // Anonymous API connectivity check
                _ = try await fetchAPIJSON(pathAndQuery: "/api/v3/comics?limit=1&offset=0&ordering=-popular&platform=3", includeAuth: false)
                return SourceVerifyResult(passed: true, profile: nil, message: "拷贝漫画 API 匿名连通正常（未配置个人 Token）")
            } else {
                let shelf = try await fetchAllCloudBookcase(baseURL: self.baseURL)
                return SourceVerifyResult(passed: true, profile: nil, message: "拷贝漫画 Token 验证通过（云端收藏 \(shelf.items.count) 部）")
            }
        } catch {
            return SourceVerifyResult(passed: false, profile: nil, message: error.localizedDescription)
        }
    }

    public func refreshSession(baseURL: String) async -> SourceCookieRefreshResult {
        let res = await verifySession(cookie: authorizationToken, baseURL: baseURL)
        return SourceCookieRefreshResult(refreshed: res.passed, updatedCookieHeader: authorizationToken, message: res.message)
    }

    public func currentCookieHeader() async -> String {
        authorizationToken
    }

    // MARK: - CloudBookshelfCapableSource

    public func fetchAllCloudBookcase(baseURL: String) async throws -> CloudBookcasePage {
        if !baseURL.isEmpty {
            self.baseURL = Self.normalizeAPIBaseURL(baseURL)
        }
        guard !authorizationToken.isEmpty else {
            throw SourceError.loginRequired(sourceId: descriptor.id, message: "请先导入拷贝漫画 Authorization Token 再同步云端收藏")
        }

        let json = try await fetchAPIJSON(
            pathAndQuery: "/api/v3/member/collect/comics?limit=50&offset=0&ordering=-datetime_modifier&platform=3",
            includeAuth: true
        )
        let results = (json["results"] as? [String: Any]) ?? [:]
        let list = (results["list"] as? [[String: Any]]) ?? []

        let items: [CloudBookcaseItem] = list.compactMap { row in
            guard let comic = row["comic"] as? [String: Any],
                  let slug = comic["path_word"] as? String,
                  !slug.isEmpty else { return nil }
            let recordId = (row["uuid"] as? String) ?? slug
            let title = (comic["name"] as? String) ?? slug
            let authors = ((comic["author"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: " / ")
            let latest = (comic["last_chapter_name"] as? String) ?? ""
            let cover = (comic["cover"] as? String) ?? ""
            return CloudBookcaseItem(
                aid: slug,
                bid: recordId,
                groupId: "copy_collect",
                title: title,
                author: authors.isEmpty ? "未知作者" : authors,
                lastReadChapterId: "",
                lastReadChapterTitle: latest,
                coverURL: cover
            )
        }

        return CloudBookcasePage(
            groups: [CloudBookcaseGroup(id: "copy_collect", title: "拷贝云收藏")],
            items: items,
            capacityTip: "拷贝漫画云端收藏 \(items.count) 部",
            activeClassId: "copy_collect"
        )
    }

    public func addToCloudBookcase(bookId: String, classId: String, baseURL: String) async throws -> String {
        throw SourceError.invalidInput("拷贝漫画当前仅支持拉取云端收藏至本地馆藏")
    }

    public func removeFromCloudBookcase(recordId: String, baseURL: String) async throws {
        throw SourceError.invalidInput("拷贝漫画当前仅支持本地移出馆藏")
    }

    public func moveCloudBookcaseItems(recordIds: [String], fromClassId: String, toClassId: String, baseURL: String) async throws {
        // Not supported on Copymanga
    }

    public func voteBook(bookId: String, baseURL: String) async throws -> String {
        throw SourceError.invalidInput("拷贝漫画暂不支持推荐票功能")
    }

    // MARK: - Parsers

    private static func parseComicListItem(_ dict: [String: Any]) -> AuthorBookItem? {
        guard let slug = dict["path_word"] as? String, !slug.isEmpty else { return nil }
        let title = (dict["name"] as? String) ?? slug
        let cover = (dict["cover"] as? String) ?? ""
        let authors = ((dict["author"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String }
            .joined(separator: " / ")
        let popular = dict["popular"] as? Int ?? 0
        let updated = (dict["datetime_updated"] as? String) ?? ""
        return AuthorBookItem(
            id: slug,
            sourceId: "copymanga",
            title: title,
            author: authors.isEmpty ? "未知作者" : authors,
            category: "漫画",
            updatedAt: updated,
            wordCount: "",
            status: "",
            popularity: popular > 0 ? "人气 \(popular)" : "",
            tags: ["漫画"],
            summary: "",
            coverURL: cover
        )
    }
}
