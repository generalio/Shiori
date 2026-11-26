import Foundation

public enum ContentKind: String, Codable, Hashable, Sendable {
    case lightNovel
    case manga
    case mixed
}

public struct ScopedBookID: Hashable, Codable, Sendable {
    public let sourceId: String
    public let bookId: String

    public var rawKey: String { "\(sourceId):\(bookId)" }

    public init(sourceId: String, bookId: String) {
        self.sourceId = sourceId
        self.bookId = bookId
    }

    public static func parse(_ raw: String, defaultSourceId: String = "wenku8") -> ScopedBookID {
        if let idx = raw.firstIndex(of: ":"), idx > raw.startIndex {
            let src = String(raw[..<idx])
            let bid = String(raw[raw.index(after: idx)...])
            return ScopedBookID(sourceId: src, bookId: bid)
        }
        return ScopedBookID(sourceId: defaultSourceId, bookId: raw)
    }
}

public struct BookSourceDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let shortBadge: String
    public let subtitle: String
    public let defaultMirrors: [String]
    public let supportedSearchScopes: [SearchScope]
    public let requiresBrowserRuntime: Bool
    public let contentKind: ContentKind
    public let isLocalSource: Bool

    public init(
        id: String,
        displayName: String,
        shortBadge: String,
        subtitle: String,
        defaultMirrors: [String],
        supportedSearchScopes: [SearchScope],
        requiresBrowserRuntime: Bool = false,
        contentKind: ContentKind = .lightNovel,
        isLocalSource: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.shortBadge = shortBadge
        self.subtitle = subtitle
        self.defaultMirrors = defaultMirrors
        self.supportedSearchScopes = supportedSearchScopes
        self.requiresBrowserRuntime = requiresBrowserRuntime
        self.contentKind = contentKind
        self.isLocalSource = isLocalSource
    }
}

public struct DiscoveryChannel: Identifiable, Hashable, Sendable {
    public let id: String
    public let sourceId: String
    public let title: String
    public let path: String
    public let icon: String

    public init(id: String? = nil, sourceId: String, title: String, path: String, icon: String) {
        self.id = id ?? "\(sourceId):\(path)"
        self.sourceId = sourceId
        self.title = title
        self.path = path
        self.icon = icon
    }
}

public enum SourceTransportEngine: String, Codable, Hashable, Sendable, CaseIterable {
    case native
    case curlCFFI

    public var displayTitle: String {
        switch self {
        case .native: return "原生网络 (URLSession)"
        case .curlCFFI: return "本地 Python curl_cffi 桥接"
        }
    }
}

public struct SourceAuthState: Codable, Hashable, Sendable {
    public var sourceId: String
    public var cookie: String
    public var userAgent: String
    public var authorizationToken: String
    public var accountLabel: String
    public var isVerified: Bool
    public var lastVerifiedAt: Date?
    public var supportsSilentRefresh: Bool
    public var lastErrorMessage: String?

    public init(
        sourceId: String,
        cookie: String = "",
        userAgent: String = HTTPRuntime.defaultUserAgent,
        authorizationToken: String = "",
        accountLabel: String = "",
        isVerified: Bool = false,
        lastVerifiedAt: Date? = nil,
        supportsSilentRefresh: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.sourceId = sourceId
        self.cookie = cookie
        self.userAgent = userAgent
        self.authorizationToken = authorizationToken
        self.accountLabel = accountLabel
        self.isVerified = isVerified
        self.lastVerifiedAt = lastVerifiedAt
        self.supportsSilentRefresh = supportsSilentRefresh
        self.lastErrorMessage = lastErrorMessage
    }

    public var hasCredentials: Bool {
        !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !authorizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SecureStateFileWriter {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct SourceRuntimeConfig: Codable, Hashable, Sendable {
    public var sourceId: String
    public var isEnabled: Bool
    public var baseURL: String
    public var cookie: String
    public var userAgent: String
    public var authorizationToken: String
    public var transportEngine: SourceTransportEngine
    public var pythonExecutablePath: String
    public var cdnRegion: String
    public var preferHighQualityImages: Bool
    public var requestTimeout: TimeInterval
    public var politeDelaySeconds: Double
    public var autoRefreshCookie: Bool
    public var refreshIntervalMinutes: Int
    public var lastCookieRefreshAt: Date?

    public init(
        sourceId: String,
        isEnabled: Bool = true,
        baseURL: String,
        cookie: String = "",
        userAgent: String = HTTPRuntime.defaultUserAgent,
        authorizationToken: String = "",
        transportEngine: SourceTransportEngine = .native,
        pythonExecutablePath: String = "",
        cdnRegion: String = "1",
        preferHighQualityImages: Bool = true,
        requestTimeout: TimeInterval = 15,
        politeDelaySeconds: Double = 0.25,
        autoRefreshCookie: Bool = true,
        refreshIntervalMinutes: Int = 15,
        lastCookieRefreshAt: Date? = nil
    ) {
        self.sourceId = sourceId
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.cookie = cookie
        self.userAgent = userAgent
        self.authorizationToken = authorizationToken
        self.transportEngine = transportEngine
        self.pythonExecutablePath = pythonExecutablePath
        self.cdnRegion = cdnRegion
        self.preferHighQualityImages = preferHighQualityImages
        self.requestTimeout = requestTimeout
        self.politeDelaySeconds = politeDelaySeconds
        self.autoRefreshCookie = autoRefreshCookie
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.lastCookieRefreshAt = lastCookieRefreshAt
    }

    enum CodingKeys: String, CodingKey {
        case sourceId, isEnabled, baseURL, cookie, userAgent, authorizationToken
        case transportEngine, pythonExecutablePath, cdnRegion, preferHighQualityImages
        case requestTimeout, politeDelaySeconds, autoRefreshCookie, refreshIntervalMinutes, lastCookieRefreshAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceId = try c.decode(String.self, forKey: .sourceId)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        baseURL = try c.decode(String.self, forKey: .baseURL)
        cookie = try c.decodeIfPresent(String.self, forKey: .cookie) ?? ""
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent) ?? HTTPRuntime.defaultUserAgent
        authorizationToken = try c.decodeIfPresent(String.self, forKey: .authorizationToken) ?? ""
        transportEngine = try c.decodeIfPresent(SourceTransportEngine.self, forKey: .transportEngine) ?? .native
        pythonExecutablePath = try c.decodeIfPresent(String.self, forKey: .pythonExecutablePath) ?? ""
        cdnRegion = try c.decodeIfPresent(String.self, forKey: .cdnRegion) ?? "1"
        preferHighQualityImages = try c.decodeIfPresent(Bool.self, forKey: .preferHighQualityImages) ?? true
        requestTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .requestTimeout) ?? 15
        politeDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .politeDelaySeconds) ?? 0.25
        autoRefreshCookie = try c.decodeIfPresent(Bool.self, forKey: .autoRefreshCookie) ?? (sourceId == "wenku8")
        refreshIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 15
        lastCookieRefreshAt = try c.decodeIfPresent(Date.self, forKey: .lastCookieRefreshAt)
    }
}

public protocol SourceDOMFetchResult: Sendable {
    var html: String { get }
    var resolvedURL: String { get }
}

public struct FetchedDOMPage: SourceDOMFetchResult, Sendable {
    public let html: String
    public let resolvedURL: String

    public init(html: String, resolvedURL: String) {
        self.html = html
        self.resolvedURL = resolvedURL
    }
}

/// Optional browser/DOM-backed runtime bridge injected by host app (e.g. WKWebView on macOS)
/// for sources whose content relies on JS DOM rendering or user-verified session cookies.
public protocol SourceBrowserRuntime: Sendable {
    func fetchRenderedHTML(sourceId: String, url: String, stripAbsoluteHiddenParagraphs: Bool) async throws -> FetchedDOMPage
    func currentCookiesHeader(forURL url: String) async -> String
}

public enum SourceError: LocalizedError, Sendable {
    case invalidInput(String)
    case notFound(String)
    case challengeRequired(sourceId: String, url: String, message: String)
    case loginRequired(sourceId: String, message: String)
    case rateLimited(sourceId: String, message: String)
    case mirrorUnavailable(sourceId: String, message: String)
    case httpError(Int, String)
    case parseError(String)
    case networkError(String)
    case sourceNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let msg):
            return "无效输入：\(msg)"
        case .notFound(let msg):
            return msg
        case .challengeRequired(_, let url, let msg):
            return "\(msg)：\(url)"
        case .loginRequired(_, let msg):
            return msg
        case .rateLimited(_, let msg):
            return msg
        case .mirrorUnavailable(_, let msg):
            return msg
        case .httpError(let code, let url):
            switch code {
            case 404: return "请求的书籍或页面不存在（HTTP 404）：\(url)"
            case 403: return "站点拒绝访问（HTTP 403）：\(url)"
            case 500...599: return "站点服务器暂时不可用（HTTP \(code)）：\(url)"
            default: return "HTTP \(code) 请求失败：\(url)"
            }
        case .parseError(let msg):
            return "页面解析失败：\(msg)"
        case .networkError(let msg):
            return "网络请求失败：\(msg)"
        case .sourceNotFound(let id):
            return "未找到书源插件：\(id)"
        }
    }
}

public struct SourceVerifyResult: Sendable {
    public let passed: Bool
    public let profile: Wenku8UserProfile?
    public let message: String

    public init(passed: Bool, profile: Wenku8UserProfile? = nil, message: String) {
        self.passed = passed
        self.profile = profile
        self.message = message
    }
}

public struct SourceCookieRefreshResult: Sendable {
    public let refreshed: Bool
    public let updatedCookieHeader: String
    public let message: String

    public init(refreshed: Bool, updatedCookieHeader: String, message: String) {
        self.refreshed = refreshed
        self.updatedCookieHeader = updatedCookieHeader
        self.message = message
    }
}

public struct SourceAuthCookieDiagnostic: Sendable {
    public let isLikelyValidFormat: Bool
    public let isForeignSiteCookie: Bool
    public let message: String
    public let normalizedCookie: String

    public init(
        isLikelyValidFormat: Bool,
        isForeignSiteCookie: Bool,
        message: String,
        normalizedCookie: String
    ) {
        self.isLikelyValidFormat = isLikelyValidFormat
        self.isForeignSiteCookie = isForeignSiteCookie
        self.message = message
        self.normalizedCookie = normalizedCookie
    }
}

// MARK: - Core & Optional Capability Protocols

public protocol BookSourcePlugin: Sendable {
    var descriptor: BookSourceDescriptor { get }

    func canHandle(rawInput: String) -> String?
    func updateConfig(_ config: SourceRuntimeConfig) async
    func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async

    func search(query: String, scope: SearchScope, page: Int) async throws -> PagedBookResult
    func fetchBookDetail(
        bookIdOrURL: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> BookDetail
    func fetchChapterContent(chapter: ChapterItem, book: BookDetail) async throws -> ChapterContent
    func downloadImage(url: String, referer: String?) async throws -> DownloadedImageAsset
    func downloadImages(
        urls: [String],
        referer: String?,
        maxConcurrency: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String: DownloadedImageAsset]
}

public protocol DiscoveryCapableSource: BookSourcePlugin {
    func discoveryChannels() -> [DiscoveryChannel]
    func fetchChannelBooks(channel: DiscoveryChannel, page: Int) async throws -> PagedBookResult
    func fetchTagGroups() async throws -> [TagGroup]
    func fetchBooksByTag(tag: String, sort: TagSortOption, page: Int) async throws -> PagedBookResult
}

public protocol AuthenticatedSource: BookSourcePlugin {
    func loginURL(baseURL: String) -> URL
    func diagnoseCookie(_ raw: String) -> SourceAuthCookieDiagnostic
    func verifySession(cookie: String, baseURL: String) async -> SourceVerifyResult
    func refreshSession(baseURL: String) async -> SourceCookieRefreshResult
    func currentCookieHeader() async -> String
}

public protocol CloudBookshelfCapableSource: BookSourcePlugin {
    func fetchAllCloudBookcase(baseURL: String) async throws -> CloudBookcasePage
    func addToCloudBookcase(bookId: String, classId: String, baseURL: String) async throws -> String
    func removeFromCloudBookcase(recordId: String, baseURL: String) async throws
    func moveCloudBookcaseItems(recordIds: [String], fromClassId: String, toClassId: String, baseURL: String) async throws
    func voteBook(bookId: String, baseURL: String) async throws -> String
}

public protocol ReviewCapableSource: BookSourcePlugin {
    func fetchReviews(bookId: String, baseURL: String) async throws -> [BookReview]
    func fetchReviewThread(review: BookReview, baseURL: String) async throws -> [ReviewPost]
}
