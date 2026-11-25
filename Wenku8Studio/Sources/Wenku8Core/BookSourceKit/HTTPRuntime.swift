import AppKit
import CoreFoundation
import Foundation

public enum HTTPTextEncoding: Sendable {
    case utf8
    case gb18030
    case auto
}

public struct HTTPTransportRequest: Sendable {
    public let url: URL
    public let method: String
    public let body: Data?
    public let cookie: String
    public let referer: String?
    public let userAgent: String
    public let extraHeaders: [String: String]
    public let timeout: TimeInterval

    public init(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        cookie: String = "",
        referer: String? = nil,
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 15
    ) {
        self.url = url
        self.method = method
        self.body = body
        self.cookie = cookie
        self.referer = referer
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
        self.timeout = timeout
    }
}

public struct HTTPTransportResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]
    public let finalURL: String
    public let setCookiePairs: [(String, String)]

    public init(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:],
        finalURL: String = "",
        setCookiePairs: [(String, String)] = []
    ) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
        self.finalURL = finalURL
        self.setCookiePairs = setCookiePairs
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse
}

public actor HTTPRuntime {
    public static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private static let cloudflareMarkers = [
        "used Cloudflare to restrict access",
        "Just a moment...",
        "请稍候…",
        "请稍候...",
        "Attention Required! | Cloudflare",
        "challenges.cloudflare.com",
        "/cdn-cgi/challenge-platform",
        "_cf_chl_opt"
    ]

    private let session: URLSession
    private var customTransport: (any HTTPTransport)?
    private var lastRequestTimeByHost: [String: Date] = [:]

    public init(
        timeout: TimeInterval = 15,
        maxConnectionsPerHost: Int = 12,
        transport: (any HTTPTransport)? = nil
    ) {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(30, timeout * 2)
        self.session = URLSession(configuration: config)
        self.customTransport = transport
    }

    public func setTransport(_ transport: (any HTTPTransport)?) {
        self.customTransport = transport
    }

    public func enforceRateLimit(hostKey: String, minDelaySeconds: Double) async {
        guard minDelaySeconds > 0 else { return }
        if let last = lastRequestTimeByHost[hostKey] {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minDelaySeconds {
                let waitNs = UInt64((minDelaySeconds - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNs)
            }
        }
        lastRequestTimeByHost[hostKey] = Date()
    }

    public func fetchRaw(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        cookie: String = "",
        referer: String? = nil,
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> HTTPTransportResponse {
        let resolvedUA = userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultUserAgent
            : userAgent
        if let customTransport {
            return try await customTransport.send(HTTPTransportRequest(
                url: url,
                method: method,
                body: body,
                cookie: cookie,
                referer: referer,
                userAgent: resolvedUA,
                extraHeaders: extraHeaders,
                timeout: timeout
            ))
        }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(resolvedUA, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        for (k, v) in extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw SourceError.networkError(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw SourceError.networkError("无效的 HTTP 响应")
        }

        let pairs = Self.extractSetCookiePairs(from: http, url: url)
        var headerMap: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            headerMap[String(describing: k)] = String(describing: v)
        }
        return HTTPTransportResponse(
            statusCode: http.statusCode,
            data: data,
            headers: headerMap,
            finalURL: http.url?.absoluteString ?? url.absoluteString,
            setCookiePairs: pairs
        )
    }

    public func fetchData(
        url: URL,
        method: String = "GET",
        body: Data? = nil,
        cookie: String = "",
        referer: String? = nil,
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 15
    ) async throws -> (data: Data, response: HTTPURLResponse, setCookiePairs: [(String, String)]) {
        let raw = try await fetchRaw(
            url: url,
            method: method,
            body: body,
            cookie: cookie,
            referer: referer,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            timeout: timeout
        )
        let responseURL = URL(string: raw.finalURL) ?? url
        let http = HTTPURLResponse(
            url: responseURL,
            statusCode: raw.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: raw.headers
        )!
        return (raw.data, http, raw.setCookiePairs)
    }

    public func fetchText(
        url: URL,
        sourceId: String,
        encoding: HTTPTextEncoding = .utf8,
        cookie: String = "",
        referer: String? = nil,
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        minDelaySeconds: Double = 0,
        timeout: TimeInterval = 15
    ) async throws -> (text: String, statusCode: Int, setCookiePairs: [(String, String)]) {
        await enforceRateLimit(hostKey: sourceId, minDelaySeconds: minDelaySeconds)
        let raw = try await fetchRaw(
            url: url,
            cookie: cookie,
            referer: referer,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            timeout: timeout
        )
        let text = Self.decodeText(raw.data, preference: encoding)
        if Self.looksLikeCloudflareChallenge(text, statusCode: raw.statusCode) {
            throw SourceError.challengeRequired(
                sourceId: sourceId,
                url: url.absoluteString,
                message: "站点触发 Cloudflare 人机验证，请在系统浏览器完成验证后导入 Cookie / cURL"
            )
        }
        if raw.statusCode == 404 {
            throw SourceError.notFound("请求的页面或作品不存在（HTTP 404）：\(url.absoluteString)")
        }
        if raw.statusCode == 429 {
            throw SourceError.rateLimited(sourceId: sourceId, message: "请求频率受限（HTTP 429），请稍后重试")
        }
        if !(200..<400).contains(raw.statusCode) {
            throw SourceError.httpError(raw.statusCode, url.absoluteString)
        }
        return (text, raw.statusCode, raw.setCookiePairs)
    }

    public func downloadSingleImage(
        urlString: String,
        referer: String?,
        cookie: String = "",
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        timeout: TimeInterval = 20
    ) async throws -> DownloadedImageAsset {
        guard let url = URL(string: urlString) else {
            throw SourceError.invalidInput("无效图片 URL：\(urlString)")
        }
        let raw = try await fetchRaw(
            url: url,
            cookie: cookie,
            referer: referer,
            userAgent: userAgent,
            extraHeaders: extraHeaders,
            timeout: timeout
        )
        guard (200..<400).contains(raw.statusCode), !raw.data.isEmpty else {
            throw SourceError.httpError(raw.statusCode, urlString)
        }

        let (ext, mime) = Self.detectImageFormat(data: raw.data, urlString: urlString)
        var w = 0
        var h = 0
        if let rep = NSBitmapImageRep(data: raw.data) {
            w = rep.pixelsWide
            h = rep.pixelsHigh
        } else if let img = NSImage(data: raw.data) {
            w = Int(img.size.width)
            h = Int(img.size.height)
        }
        return DownloadedImageAsset(url: urlString, data: raw.data, fileExtension: ext, mimeType: mime, width: w, height: h)
    }

    public func downloadImages(
        urls: [String],
        referer: String?,
        cookie: String = "",
        userAgent: String = HTTPRuntime.defaultUserAgent,
        extraHeaders: [String: String] = [:],
        maxConcurrency: Int = 4,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [String: DownloadedImageAsset] {
        let unique = Array(NSOrderedSet(array: urls).compactMap { $0 as? String })
        guard !unique.isEmpty else { return [:] }

        let limit = max(1, min(16, maxConcurrency))
        var result: [String: DownloadedImageAsset] = [:]
        var completed = 0
        var nextIdx = 0

        await withTaskGroup(of: (String, DownloadedImageAsset?).self) { group in
            for _ in 0..<min(limit, unique.count) {
                let target = unique[nextIdx]
                nextIdx += 1
                group.addTask {
                    let asset = try? await self.downloadSingleImage(
                        urlString: target,
                        referer: referer,
                        cookie: cookie,
                        userAgent: userAgent,
                        extraHeaders: extraHeaders
                    )
                    return (target, asset)
                }
            }

            while let (url, asset) = await group.next() {
                completed += 1
                if let asset { result[url] = asset }
                onProgress?(completed, unique.count)

                if nextIdx < unique.count {
                    let target = unique[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        let nextAsset = try? await self.downloadSingleImage(
                            urlString: target,
                            referer: referer,
                            cookie: cookie,
                            userAgent: userAgent,
                            extraHeaders: extraHeaders
                        )
                        return (target, nextAsset)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Shared Helpers

    public static func looksLikeCloudflareChallenge(_ html: String, statusCode: Int = 200) -> Bool {
        if statusCode == 403 || statusCode == 503 {
            if cloudflareMarkers.contains(where: { html.contains($0) }) {
                return true
            }
        }
        return html.contains("<title>Just a moment...</title>")
            || html.contains("<title>请稍候…</title>")
            || html.contains("<title>请稍候...</title>")
            || html.contains("Attention Required! | Cloudflare")
            || html.contains("/cdn-cgi/challenge-platform")
            || html.contains("window._cf_chl_opt")
    }

    public static func decodeText(_ data: Data, preference: HTTPTextEncoding) -> String {
        switch preference {
        case .utf8:
            if let s = String(data: data, encoding: .utf8) { return s }
            return decodeGB18030(data) ?? String(decoding: data, as: UTF8.self)
        case .gb18030:
            return decodeGB18030(data) ?? String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .auto:
            if let s = String(data: data, encoding: .utf8), !s.contains("") {
                return s
            }
            return decodeGB18030(data) ?? String(decoding: data, as: UTF8.self)
        }
    }

    public static func decodeGB18030(_ data: Data) -> String? {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String(data: data, encoding: String.Encoding(rawValue: nsEnc))
    }

    public static func extractSetCookiePairs(from response: HTTPURLResponse, url: URL) -> [(String, String)] {
        var headerDict: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                headerDict[ks] = vs
            }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerDict, for: url)
        return cookies.map { ($0.name, $0.value) }
    }

    public static func mergeCookieHeader(existing: String, updating pairs: [(String, String)]) -> String {
        var orderedKeys: [String] = []
        var map: [String: String] = [:]
        for part in existing.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                if map[key] == nil { orderedKeys.append(key) }
                map[key] = val
            }
        }
        for (k, v) in pairs where !k.isEmpty {
            if map[k] == nil { orderedKeys.append(k) }
            map[k] = v
        }
        return orderedKeys.compactMap { k in
            guard let v = map[k] else { return nil }
            return "\(k)=\(v)"
        }.joined(separator: "; ")
    }

    public static func detectImageFormat(data: Data, urlString: String) -> (String, String) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("png", "image/png") }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return ("gif", "image/gif") }
        if data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8) {
            return ("webp", "image/webp")
        }
        let lower = urlString.lowercased()
        if lower.hasSuffix(".png") { return ("png", "image/png") }
        if lower.hasSuffix(".webp") { return ("webp", "image/webp") }
        if lower.hasSuffix(".gif") { return ("gif", "image/gif") }
        return ("jpg", "image/jpeg")
    }

    public static func unescapeHTML(_ str: String) -> String {
        var s = str
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")

        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                if m.numberOfRanges > 1,
                   let code = UInt32(ns.substring(with: m.range(at: 1))),
                   let scalar = UnicodeScalar(code) {
                    s = (s as NSString).replacingCharacters(in: m.range, with: String(scalar))
                }
            }
        }
        return s
    }

    public static func stripHTMLTags(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescapeHTML(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolveURL(_ href: String, baseURL: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        if trimmed.hasPrefix("/") {
            return base + trimmed
        }
        return base + "/" + trimmed
    }
}
