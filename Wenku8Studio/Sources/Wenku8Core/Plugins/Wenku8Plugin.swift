import Foundation

extension Wenku8Client: BookSourcePlugin, DiscoveryCapableSource, AuthenticatedSource, CloudBookshelfCapableSource, ReviewCapableSource {
    public nonisolated var descriptor: BookSourceDescriptor {
        BookSourceDescriptor(
            id: "wenku8",
            displayName: "轻小说文库",
            shortBadge: "文库",
            subtitle: "www.wenku8.cc / www.wenku8.net · 支持全站搜索、榜单、云端书架与书评",
            defaultMirrors: Wenku8Client.officialMirrors,
            supportedSearchScopes: SearchScope.allCases,
            requiresBrowserRuntime: false,
            contentKind: .lightNovel
        )
    }

    public nonisolated func canHandle(rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("wenku8:") || lower.hasPrefix("wk8:") {
            let suffix = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            let bid = Self.extractBookId(from: suffix)
            return bid.isEmpty ? nil : bid
        }
        if lower.contains("wenku8") || trimmed.allSatisfy(\.isNumber) {
            let bid = Self.extractBookId(from: trimmed)
            return bid.isEmpty ? nil : bid
        }
        return nil
    }

    public func updateConfig(_ config: SourceRuntimeConfig) async {
        updateSettings(
            baseURL: config.baseURL,
            cookie: config.cookie,
            timeout: config.requestTimeout,
            politeDelaySeconds: config.politeDelaySeconds
        )
    }

    public func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async {
        // Wenku8 uses pure HTTP URLSession with GB18030 decoding; browser runtime optional.
    }

    public func search(query: String, scope: SearchScope, page: Int) async throws -> PagedBookResult {
        try await mapErrors {
            try await searchBooksPaged(query: query, scope: scope, page: page)
        }
    }

    public func fetchBookDetail(
        bookIdOrURL: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> BookDetail {
        try await mapErrors {
            try await fetchBookDetail(rawInput: bookIdOrURL, onLog: onProgress)
        }
    }

    public func fetchChapterContent(chapter: ChapterItem, book: BookDetail) async throws -> ChapterContent {
        try await mapErrors {
            try await fetchChapterContent(chapter: chapter, baseURL: book.baseURL)
        }
    }

    public func downloadImage(url: String, referer: String?) async throws -> DownloadedImageAsset {
        try await mapErrors {
            try await downloadSingleImage(urlString: url, referer: referer)
        }
    }

    // MARK: - DiscoveryCapableSource

    public nonisolated func discoveryChannels() -> [DiscoveryChannel] {
        [
            DiscoveryChannel(sourceId: "wenku8", title: "总点击榜", path: "/modules/article/toplist.php?sort=allvisit", icon: "flame.fill"),
            DiscoveryChannel(sourceId: "wenku8", title: "最近更新", path: "/modules/article/toplist.php?sort=lastupdate", icon: "clock.arrow.circlepath"),
            DiscoveryChannel(sourceId: "wenku8", title: "总推荐榜", path: "/modules/article/toplist.php?sort=allvote", icon: "hand.thumbsup.fill"),
            DiscoveryChannel(sourceId: "wenku8", title: "总收藏榜", path: "/modules/article/toplist.php?sort=goodnum", icon: "bookmark.fill"),
            DiscoveryChannel(sourceId: "wenku8", title: "周点击榜", path: "/modules/article/toplist.php?sort=weekvisit", icon: "chart.line.uptrend.xyaxis"),
            DiscoveryChannel(sourceId: "wenku8", title: "月点击榜", path: "/modules/article/toplist.php?sort=monthvisit", icon: "calendar"),
            DiscoveryChannel(sourceId: "wenku8", title: "新书一览", path: "/modules/article/toplist.php?sort=postdate", icon: "sparkle"),
            DiscoveryChannel(sourceId: "wenku8", title: "字数排行", path: "/modules/article/toplist.php?sort=size", icon: "text.word.spacing"),
            DiscoveryChannel(sourceId: "wenku8", title: "完结专区", path: "/modules/article/articlelist.php?fullflag=1", icon: "checkmark.seal.fill"),
            DiscoveryChannel(sourceId: "wenku8", title: "动画化作品", path: "/modules/article/toplist.php?sort=anime", icon: "sparkles.tv"),
        ]
    }

    public func fetchChannelBooks(channel: DiscoveryChannel, page: Int) async throws -> PagedBookResult {
        try await mapErrors {
            try await fetchDiscoveryBooksPaged(listPath: channel.path, page: page)
        }
    }

    public func fetchTagGroups() async throws -> [TagGroup] {
        try await mapErrors {
            try await fetchTagGroups(baseURL: nil)
        }
    }

    public func fetchBooksByTag(tag: String, sort: TagSortOption, page: Int) async throws -> PagedBookResult {
        try await mapErrors {
            try await fetchBooksByTag(tag: tag, sort: sort, page: page, baseURL: nil)
        }
    }

    // MARK: - AuthenticatedSource

    public nonisolated func loginURL(baseURL: String) -> URL {
        let normalized = Self.normalizeBaseURL(baseURL)
        return URL(string: "\(normalized)/login.php") ?? URL(string: "https://www.wenku8.cc/login.php")!
    }

    public nonisolated func diagnoseCookie(_ raw: String) -> SourceAuthCookieDiagnostic {
        let d = Self.diagnoseCookieFormat(raw)
        return SourceAuthCookieDiagnostic(
            isLikelyValidFormat: d.isLikelyValidFormat,
            isForeignSiteCookie: d.isForeignSiteCookie,
            message: d.message,
            normalizedCookie: d.normalizedCookie
        )
    }

    public func verifySession(cookie: String, baseURL: String) async -> SourceVerifyResult {
        let res = await verifyCookieLive(cookie: cookie, baseURL: baseURL)
        let profile = res.isLoggedIn ? (try? await fetchUserProfile(baseURL: baseURL)) : nil
        return SourceVerifyResult(passed: res.isLoggedIn, profile: profile, message: res.message)
    }

    public func refreshSession(baseURL: String) async -> SourceCookieRefreshResult {
        let res = await refreshCookieSession(baseURL: baseURL)
        return SourceCookieRefreshResult(
            refreshed: res.isLoggedIn,
            updatedCookieHeader: res.updatedCookie,
            message: res.message
        )
    }

    public func currentCookieHeader() async -> String {
        currentCookieSnapshot()
    }

    // MARK: - CloudBookshelfCapableSource

    public func fetchAllCloudBookcase(baseURL: String) async throws -> CloudBookcasePage {
        try await mapErrors {
            try await fetchAllCloudBookcase(baseURL: Optional(baseURL))
        }
    }

    public func addToCloudBookcase(bookId: String, classId: String, baseURL: String) async throws -> String {
        try await mapErrors {
            try await addToCloudBookcase(bookId: bookId, baseURL: Optional(baseURL))
        }
    }

    public func removeFromCloudBookcase(recordId: String, baseURL: String) async throws {
        try await mapErrors {
            try await removeFromCloudBookcase(recordId: recordId, baseURL: Optional(baseURL))
        }
    }

    public func moveCloudBookcaseItems(recordIds: [String], fromClassId: String, toClassId: String, baseURL: String) async throws {
        try await mapErrors {
            try await moveCloudBookcaseItems(
                recordIds: recordIds,
                fromClassId: fromClassId,
                toClassId: toClassId,
                baseURL: Optional(baseURL)
            )
        }
    }

    public func voteBook(bookId: String, baseURL: String) async throws -> String {
        try await mapErrors {
            try await voteBook(bookId: bookId, baseURL: Optional(baseURL))
        }
    }

    // MARK: - ReviewCapableSource

    public func fetchReviews(bookId: String, baseURL: String) async throws -> [BookReview] {
        try await mapErrors {
            try await fetchReviews(bookId: bookId, baseURL: Optional(baseURL))
        }
    }

    public func fetchReviewThread(review: BookReview, baseURL: String) async throws -> [ReviewPost] {
        try await mapErrors {
            try await fetchReviewThread(reviewURL: review.url, baseURL: Optional(baseURL))
        }
    }

    // MARK: - Error Mapping

    private func mapErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let err as Wenku8Error {
            switch err {
            case .invalidBookInput(let msg):
                throw SourceError.invalidInput(msg)
            case .bookNotFound(let msg):
                throw SourceError.notFound(msg)
            case .cloudflareBlocked(let url):
                throw SourceError.challengeRequired(
                    sourceId: "wenku8",
                    url: url,
                    message: "轻小说文库触发 Cloudflare 拦截，请通过网页登录或切换站点重试"
                )
            case .httpError(let code, let url):
                throw SourceError.httpError(code, url)
            case .parseError(let msg):
                throw SourceError.parseError(msg)
            case .networkError(let msg):
                throw SourceError.networkError(msg)
            case .loginRequired(let msg):
                throw SourceError.loginRequired(sourceId: "wenku8", message: msg)
            }
        }
    }
}
