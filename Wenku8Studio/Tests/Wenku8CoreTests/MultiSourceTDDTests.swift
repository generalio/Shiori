import AppKit
import Foundation
import XCTest
@testable import Wenku8Core

final class MultiSourceTDDTests: XCTestCase {
    // MARK: - Seam 1: CurlImportParser

    func testCurlImportParserExtractsFieldsFromBashCurlCommand() {
        let bashCurl = """
        curl 'https://www.bilinovel.com/novel/2543.html' \\
          -H 'accept: text/html' \\
          -b 'cf_clearance=cf_tok_123; night=1; PHPSESSID=sess_99' \\
          -H 'referer: https://www.bilinovel.com/' \\
          -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36' \\
          -H 'authorization: Token copy_tok_777'
        """

        let parsed = CurlImportParser.parse(bashCurl)
        XCTAssertEqual(parsed.url, "https://www.bilinovel.com/novel/2543.html")
        XCTAssertEqual(parsed.cookie, "cf_clearance=cf_tok_123; night=1; PHPSESSID=sess_99")
        XCTAssertEqual(parsed.userAgent, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36")
        XCTAssertEqual(parsed.referer, "https://www.bilinovel.com/")
        XCTAssertEqual(parsed.authorizationToken, "copy_tok_777")
    }

    func testCurlImportParserHandlesRawHeadersPlainCookieAndPlainToken() {
        let rawHeaders = """
        Cookie: jieqiUserInfo=u1; PHPSESSID=p1
        User-Agent: CustomUA/1.0
        Authorization: Token abc_token_99
        """
        let fromHeaders = CurlImportParser.parse(rawHeaders)
        XCTAssertEqual(fromHeaders.cookie, "jieqiUserInfo=u1; PHPSESSID=p1")
        XCTAssertEqual(fromHeaders.userAgent, "CustomUA/1.0")
        XCTAssertEqual(fromHeaders.authorizationToken, "abc_token_99")

        let plainCookie = CurlImportParser.parse("cf_clearance=xyz; night=1")
        XCTAssertEqual(plainCookie.cookie, "cf_clearance=xyz; night=1")
        XCTAssertNil(plainCookie.authorizationToken)

        let plainToken = CurlImportParser.parse("Token raw_copy_token_42")
        XCTAssertEqual(plainToken.authorizationToken, "raw_copy_token_42")
        XCTAssertEqual(plainToken.cookie, "")
    }

    // MARK: - Seam 2: SourceRuntimeConfig, SourceAuthState & 0600 Persistence

    func testLegacySourceRuntimeConfigDecodesWithSafeDefaults() throws {
        let legacyJSON = """
        {
          "sourceId": "bilinovel",
          "isEnabled": true,
          "baseURL": "https://www.bilinovel.com",
          "cookie": "cf_clearance=old_cf",
          "requestTimeout": 15,
          "politeDelaySeconds": 0.35,
          "autoRefreshCookie": false,
          "refreshIntervalMinutes": 15
        }
        """
        let decoded = try JSONDecoder().decode(SourceRuntimeConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.sourceId, "bilinovel")
        XCTAssertEqual(decoded.cookie, "cf_clearance=old_cf")
        XCTAssertEqual(decoded.userAgent, HTTPRuntime.defaultUserAgent)
        XCTAssertEqual(decoded.authorizationToken, "")
        XCTAssertEqual(decoded.transportEngine, .native)
        XCTAssertEqual(decoded.preferHighQualityImages, true)
    }

    func testSourceAuthStateAndSecureStateFileWriterEnforces0600Permissions() throws {
        let auth = SourceAuthState(
            sourceId: "copymanga",
            cookie: "",
            userAgent: "COPY/3.0.6",
            authorizationToken: "secret_tok_99",
            accountLabel: "tester",
            isVerified: true,
            supportsSilentRefresh: false
        )
        let data = try JSONEncoder().encode(auth)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-sec-\(UUID().uuidString)")
        let fileURL = tmpDir.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try SecureStateFileWriter.write(data, to: fileURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        let readBack = try JSONDecoder().decode(SourceAuthState.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(readBack, auth)
    }

    // MARK: - Seam 3: HTTPTransport, HTTPRuntime & CurlCFFITransport

    func testHTTPRuntimeForwardsUAHeadersAndClassifies404429AndCloudflare() async throws {
        final class StubTransport: HTTPTransport, @unchecked Sendable {
            var capturedRequests: [HTTPTransportRequest] = []
            let handler: @Sendable (HTTPTransportRequest) -> HTTPTransportResponse
            init(handler: @escaping @Sendable (HTTPTransportRequest) -> HTTPTransportResponse) {
                self.handler = handler
            }
            func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
                capturedRequests.append(request)
                return handler(request)
            }
        }

        let stub = StubTransport { req in
            switch req.url.path {
            case "/ok":
                return HTTPTransportResponse(
                    statusCode: 200,
                    data: Data("hello".utf8),
                    headers: ["Content-Type": "text/plain"],
                    finalURL: req.url.absoluteString
                )
            case "/missing":
                return HTTPTransportResponse(statusCode: 404, data: Data("Not Found".utf8), headers: [:], finalURL: req.url.absoluteString)
            case "/limit":
                return HTTPTransportResponse(statusCode: 429, data: Data("Too Many Requests".utf8), headers: [:], finalURL: req.url.absoluteString)
            default:
                return HTTPTransportResponse(statusCode: 403, data: Data("Just a moment... challenges.cloudflare.com".utf8), headers: [:], finalURL: req.url.absoluteString)
            }
        }

        let runtime = HTTPRuntime(transport: stub)
        let (text, status, _) = try await runtime.fetchText(
            url: URL(string: "https://example.com/ok")!,
            sourceId: "bilinovel",
            cookie: "cf_clearance=abc",
            userAgent: "CustomBrowser/99",
            extraHeaders: ["X-Test": "1"]
        )
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(stub.capturedRequests.first?.userAgent, "CustomBrowser/99")
        XCTAssertEqual(stub.capturedRequests.first?.extraHeaders["X-Test"], "1")
        XCTAssertEqual(stub.capturedRequests.first?.cookie, "cf_clearance=abc")

        do {
            _ = try await runtime.fetchText(url: URL(string: "https://example.com/missing")!, sourceId: "bilinovel")
            XCTFail("Expected notFound")
        } catch SourceError.notFound {
            // expected
        }

        do {
            _ = try await runtime.fetchText(url: URL(string: "https://example.com/limit")!, sourceId: "copymanga")
            XCTFail("Expected rateLimited")
        } catch SourceError.rateLimited(let src, _) {
            XCTAssertEqual(src, "copymanga")
        }

        do {
            _ = try await runtime.fetchText(url: URL(string: "https://example.com/cf")!, sourceId: "bilinovel")
            XCTFail("Expected challengeRequired")
        } catch SourceError.challengeRequired(let src, _, _) {
            XCTAssertEqual(src, "bilinovel")
        }
    }

    func testCurlCFFITransportInvokesBridgeExecutableAndReportsMissingEnvironment() async throws {
        // 1. Missing binary degrades with explicit error
        let missingEnv = CurlCFFITransport.detectEnvironment(preferredPythonPath: "/nonexistent/python-shiori")
        XCTAssertFalse(missingEnv.isAvailable)

        // 2. Stub executable verifies JSON request/response contract over stdin/stdout
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let stubScript = tmpDir.appendingPathComponent("fake_python.sh")
        let scriptBody = """
        #!/bin/sh
        python3 -c 'import sys, json, base64; req = json.loads(sys.stdin.read()); payload = ("UA=" + req["headers"].get("User-Agent", "") + ";CK=" + req["headers"].get("Cookie", "")).encode("utf-8"); print(json.dumps({"status": 200, "url": req["url"], "headers": {"Content-Type": "text/plain"}, "body_b64": base64.b64encode(payload).decode("ascii"), "set_cookies": [["night", "1"]]}))'
        """
        try scriptBody.write(to: stubScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubScript.path)

        let bridge = CurlCFFITransport(pythonExecutable: stubScript.path)
        let resp = try await bridge.send(HTTPTransportRequest(
            url: URL(string: "https://www.bilinovel.com/novel/2543.html")!,
            cookie: "cf_clearance=ok_1",
            userAgent: "SafariTest/18"
        ))
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(data: resp.data, encoding: .utf8), "UA=SafariTest/18;CK=cf_clearance=ok_1")
        XCTAssertEqual(resp.setCookiePairs.first?.0, "night")
        XCTAssertEqual(resp.setCookiePairs.first?.1, "1")
    }

    // MARK: - Seam 4: BilinovelPlugin (Direct-HTTP First, Scoped Chapter IDs, Hidden Decoys, PUA Drift)

    func testBilinovelDirectHTTPFirstWithBrowserFallbackScopedIDsAndPUADriftWarning() async throws {
        final class FakeBiliTransport: HTTPTransport, @unchecked Sendable {
            var shouldChallengeCatalog = false
            var requestedURLs: [String] = []
            func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
                requestedURLs.append(request.url.absoluteString)
                let path = request.url.path
                if path == "/novel/2543.html" {
                    let html = """
                    <html><head><meta property="og:novel:author" content="作者A"/></head><body>
                      <h1 class="book-name">测试轻小说</h1>
                      <div class="book-dec"><p>简介正文</p></div>
                    </body></html>
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(html.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/novel/2543/catalog" {
                    if shouldChallengeCatalog {
                        return HTTPTransportResponse(statusCode: 403, data: Data("Just a moment... challenges.cloudflare.com".utf8), finalURL: request.url.absoluteString)
                    }
                    let html = """
                    <div class="volume clearfix"><h2 class="v-line">测试轻小说 第一卷</h2>
                      <ul><li class="col-4"><a href="/novel/2543/9901.html">第一章</a></li></ul>
                    </div>
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(html.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/novel/2543/9901.html" {
                    // Includes an absolute-positioned decoy paragraph and an unmapped PUA character \u{E999}
                    let html = """
                    <html><body><div id="TextContent">
                      <p style="position: absolute; left: -9999px;">防盗诱饵段落</p>
                      <p>正常第一段</p>
                      <p>疑似字库漂移\u{F8FF}</p>
                    </div></body></html>
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(html.utf8), finalURL: request.url.absoluteString)
                }
                return HTTPTransportResponse(statusCode: 404, data: Data(), finalURL: request.url.absoluteString)
            }
        }

        final class CountingBrowserRuntime: SourceBrowserRuntime, @unchecked Sendable {
            var fetchCount = 0
            func fetchRenderedHTML(sourceId: String, url: String, stripAbsoluteHiddenParagraphs: Bool) async throws -> FetchedDOMPage {
                fetchCount += 1
                let html = """
                <div class="volume clearfix"><h2 class="v-line">测试轻小说 第一卷</h2>
                  <ul><li class="col-4"><a href="/novel/2543/9901.html">第一章</a></li></ul>
                </div>
                """
                return FetchedDOMPage(html: html, resolvedURL: url)
            }
            func currentCookiesHeader(forURL url: String) async -> String { "" }
        }

        let transport = FakeBiliTransport()
        let browser = CountingBrowserRuntime()
        let plugin = BilinovelPlugin(politeDelaySeconds: 0, httpRuntime: HTTPRuntime(transport: transport))
        await plugin.setBrowserRuntime(browser)

        // Explicit prefix routing
        XCTAssertEqual(plugin.canHandle(rawInput: "bili:2543"), "2543")

        // 1. Direct HTTP succeeds -> browserRuntime is NOT called
        let detail = try await plugin.fetchBookDetail(bookIdOrURL: "2543", onProgress: nil)
        XCTAssertEqual(browser.fetchCount, 0)
        XCTAssertEqual(detail.volumes.first?.chapters.first?.id, "bili_2543_v1_c1")

        // 2. Chapter content strips absolute decoy paragraph & flags unmapped PUA drift
        let chapter = try XCTUnwrap(detail.volumes.first?.chapters.first)
        let content = try await plugin.fetchChapterContent(chapter: chapter, book: detail)
        XCTAssertEqual(browser.fetchCount, 0)
        let paragraphs = content.tokens.compactMap { tok -> String? in
            if case .paragraph(let s) = tok { return s }
            return nil
        }
        XCTAssertFalse(paragraphs.contains(where: { $0.contains("防盗诱饵段落") }))
        XCTAssertTrue(paragraphs.contains("正常第一段"))
        XCTAssertNotNil(content.warningMessage)

        // 3. When direct HTTP hits Cloudflare challenge, falls back to browserRuntime
        transport.shouldChallengeCatalog = true
        let fallbackDetail = try await plugin.fetchBookDetail(bookIdOrURL: "2543", onProgress: nil)
        XCTAssertEqual(browser.fetchCount, 1)
        XCTAssertEqual(fallbackDetail.volumes.first?.chapters.first?.id, "bili_2543_v1_c1")
    }

    // MARK: - Seam 5: CopymangaPlugin App API v3 Contract

    func testCopymangaSearchDetailWordsReorderingQualityErrorsAndCloudShelf() async throws {
        final class FakeCopyTransport: HTTPTransport, @unchecked Sendable {
            var lastAuthHeader: String?
            var forceMirror210 = false
            func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
                lastAuthHeader = request.extraHeaders["authorization"] ?? request.extraHeaders["Authorization"]
                let path = request.url.path
                if forceMirror210 {
                    let body = #"{"code":210,"message":"非正版客户端或接口受限","results":null}"#
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/search/comic" {
                    let body = """
                    {"code":200,"results":{"total":1,"list":[{"name":"摇曳露营","path_word":"yaoyeluying","cover":"https://img.example/cover.jpg","author":[{"name":"Afro"}]}]}}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/comic2/yaoyeluying" {
                    let body = """
                    {"code":200,"results":{
                      "comic":{
                        "name":"摇曳露营","path_word":"yaoyeluying","brief":"露营日常",
                        "cover":"https://img.example/cover.jpg","datetime_updated":"2026-11-20",
                        "popular":99999,"status":{"display":"连载中"},
                        "author":[{"name":"Afro"}],
                        "theme":[{"name":"日常"},{"name":"治愈"}]
                      },
                      "groups":{
                        "default":{"path_word":"default","name":"默认","count":2},
                        "tankobon":{"path_word":"tankobon","name":"单行本","count":1}
                      }
                    }}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/comic/yaoyeluying/group/default/chapters" {
                    let body = """
                    {"code":200,"results":{"total":2,"list":[
                      {"uuid":"u2","name":"第2话","index":1,"size":3},
                      {"uuid":"u1","name":"第1话","index":0,"size":3}
                    ]}}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/comic/yaoyeluying/group/tankobon/chapters" {
                    let body = """
                    {"code":200,"results":{"total":1,"list":[
                      {"uuid":"ut1","name":"第01卷","index":0,"size":20}
                    ]}}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/comic/yaoyeluying/chapter2/u1" {
                    // Scrambled order in contents; words maps contents[0]->page2, contents[1]->page0, contents[2]->page1
                    let body = """
                    {"code":200,"results":{"chapter":{
                      "uuid":"u1","name":"第1话",
                      "contents":[
                        {"url":"https://cdn.example/p2.jpg.c800x.webp"},
                        {"url":"https://cdn.example/p0.jpg.c800x.webp"},
                        {"url":"https://cdn.example/p1.jpg.c800x.webp"}
                      ],
                      "words":[2, 0, 1]
                    }}}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                if path == "/api/v3/member/collect/comics" {
                    guard let auth = lastAuthHeader, auth == "Token valid_copy_tok" else {
                        return HTTPTransportResponse(statusCode: 401, data: Data("Unauthorized".utf8), finalURL: request.url.absoluteString)
                    }
                    let body = """
                    {"code":200,"results":{"total":1,"list":[
                      {"uuid":"rec1","comic":{"path_word":"yaoyeluying","name":"摇曳露营","cover":"https://img.example/cover.jpg","author":[{"name":"Afro"}],"last_chapter_name":"第2话","datetime_updated":"2026-11-20"}}
                    ]}}
                    """
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                return HTTPTransportResponse(statusCode: 404, data: Data(), finalURL: request.url.absoluteString)
            }
        }

        let transport = FakeCopyTransport()
        let plugin = CopymangaPlugin(politeDelaySeconds: 0, httpRuntime: HTTPRuntime(transport: transport))

        // URL & explicit prefix handling
        XCTAssertEqual(plugin.canHandle(rawInput: "copy:yaoyeluying"), "yaoyeluying")
        XCTAssertEqual(plugin.canHandle(rawInput: "https://www.2025copy.com/comic/yaoyeluying"), "yaoyeluying")

        // Search
        let searchRes = try await plugin.search(query: "露营", scope: .articleName, page: 1)
        XCTAssertEqual(searchRes.items.count, 1)
        XCTAssertEqual(searchRes.items.first?.id, "yaoyeluying")
        XCTAssertEqual(searchRes.items.first?.sourceId, "copymanga")

        // Detail & WorkGroups (ascending chapter order)
        let detail = try await plugin.fetchBookDetail(bookIdOrURL: "yaoyeluying", onProgress: nil)
        XCTAssertEqual(detail.contentKind, .manga)
        XCTAssertEqual(detail.volumes.count, 2)
        let defaultGroup = try XCTUnwrap(detail.volumes.first(where: { $0.id.contains("default") }))
        XCTAssertEqual(defaultGroup.chapters.map(\.title), ["第1话", "第2话"])
        XCTAssertEqual(defaultGroup.chapters.first?.id, "copy_yaoyeluying_u1")

        // Chapter content: words reordering + HD c1500x upgrade
        let firstChap = try XCTUnwrap(defaultGroup.chapters.first)
        let hdContent = try await plugin.fetchChapterContent(chapter: firstChap, book: detail)
        XCTAssertEqual(hdContent.contentKind, .manga)
        XCTAssertEqual(hdContent.imageURLs, [
            "https://cdn.example/p0.jpg.c1500x.webp",
            "https://cdn.example/p1.jpg.c1500x.webp",
            "https://cdn.example/p2.jpg.c1500x.webp",
        ])

        // CloudShelf with valid Token
        var cfg = SourceRuntimeConfig(sourceId: "copymanga", baseURL: "https://api.2025copy.com")
        cfg.authorizationToken = "valid_copy_tok"
        await plugin.updateConfig(cfg)
        let cloud = try await plugin.fetchAllCloudBookcase(baseURL: "https://api.2025copy.com")
        XCTAssertEqual(cloud.items.count, 1)
        XCTAssertEqual(cloud.items.first?.aid, "yaoyeluying")

        // Mirror 210 error classification
        transport.forceMirror210 = true
        do {
            _ = try await plugin.search(query: "露营", scope: .articleName, page: 1)
            XCTFail("Expected mirrorUnavailable")
        } catch SourceError.mirrorUnavailable(let src, _) {
            XCTAssertEqual(src, "copymanga")
        }
    }

    // MARK: - Seam 6: SourceRegistry 3-Source Default & ContentKind Aggregated Search

    func testSourceRegistryDefaultsAllThreeSourcesRoutesPrefixesAndFiltersByContentKind() async {
        let registry = SourceRegistry.makeDefaultRegistry()
        XCTAssertEqual(registry.allPlugins().map(\.descriptor.id), ["wenku8", "bilinovel", "copymanga"])
        XCTAssertTrue(registry.isEnabled("wenku8"))
        XCTAssertTrue(registry.isEnabled("bilinovel"))
        XCTAssertTrue(registry.isEnabled("copymanga"))

        XCTAssertEqual(registry.routeBookInput("bili:2543")?.plugin.descriptor.id, "bilinovel")
        XCTAssertEqual(registry.routeBookInput("copy:yaoyeluying")?.plugin.descriptor.id, "copymanga")
        XCTAssertEqual(registry.routeBookInput("wenku8:1973")?.plugin.descriptor.id, "wenku8")
        XCTAssertEqual(registry.routeBookInput("2543", preferredSourceId: "wenku8")?.plugin.descriptor.id, "wenku8")

        // Bare numeric ID has cross-source alternative candidate (bilinovel)
        let alts = registry.alternativeRoutes(for: "2543", excludingSourceId: "wenku8")
        XCTAssertEqual(alts.map(\.plugin.descriptor.id), ["bilinovel"])

        // ContentKind filtering on enabledPlugins(matching:)
        XCTAssertEqual(registry.enabledPlugins(matching: .manga).map(\.descriptor.id), ["copymanga"])
        XCTAssertEqual(registry.enabledPlugins(matching: .lightNovel).map(\.descriptor.id), ["wenku8", "bilinovel"])
    }

    // MARK: - Seam 7: LocalShelf Isolated Per-Source CloudShelf Merge

    func testLocalShelfReconcilerMergesPerSourceWithoutCrossSourcePollution() {
        let localWenku = BookmarkEntry(
            id: "1973",
            sourceId: "wenku8",
            title: "实教",
            author: "衣笠彰梧",
            coverURL: "https://w.example/1973.jpg",
            publisher: "MF文库J",
            status: "连载中",
            tags: ["校园"]
        )
        let localBili = BookmarkEntry(
            id: "1973", // Same raw numeric ID on a different source!
            sourceId: "bilinovel",
            title: "哔哩1973",
            author: "作者B",
            coverURL: "https://b.example/1973.jpg",
            publisher: "电击文库",
            status: "连载中",
            tags: ["奇幻"]
        )

        let remoteCopyItems = [
            CloudBookcaseItem(
                aid: "yaoyeluying",
                bid: "rec_copy_1",
                groupId: "copy_collect",
                title: "摇曳露营",
                author: "Afro",
                lastReadChapterId: "",
                lastReadChapterTitle: "第80话",
                coverURL: "https://c.example/camp.jpg"
            )
        ]

        let merged = LocalShelfReconciler.mergeReadOnlyCloudItems(
            localEntries: [localWenku, localBili],
            remoteItems: remoteCopyItems,
            sourceId: "copymanga"
        )

        // Existing Wenku8 & Bilinovel entries remain untouched and distinct despite sharing raw numeric ID "1973"
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains(where: { $0.sourceId == "wenku8" && $0.id == "1973" }))
        XCTAssertTrue(merged.contains(where: { $0.sourceId == "bilinovel" && $0.id == "1973" }))
        let copyEntry = merged.first(where: { $0.sourceId == "copymanga" && $0.id == "yaoyeluying" })
        XCTAssertEqual(copyEntry?.title, "摇曳露营")
        XCTAssertEqual(copyEntry?.cloudRecordId, "rec_copy_1")
        XCTAssertEqual(copyEntry?.cloudGroupId, "copy_collect")
    }

    // MARK: - Seam 8: BoundedReaderImageCache (Sliding Window Prefetch & LRU Eviction)

    func testBoundedReaderImageCacheComputesSlidingWindowAndEvictsLRUAtByteLimit() {
        // Prefetch window: current ± 5 clamped cleanly to [0, totalCount - 1]
        let windowMid = BoundedReaderImageCache.prefetchWindowIndices(currentIndex: 10, totalCount: 50, radius: 5)
        XCTAssertEqual(Set(windowMid), Set(5...15))
        XCTAssertEqual(windowMid.first, 10)

        let windowEdge = BoundedReaderImageCache.prefetchWindowIndices(currentIndex: 1, totalCount: 4, radius: 5)
        XCTAssertEqual(Set(windowEdge), Set(0...3))
        XCTAssertEqual(windowEdge.first, 1)

        // LRU eviction at strict byte budget (limit = 100 bytes)
        let cache = BoundedReaderImageCache(maxMemoryBytes: 100)
        cache.insert(key: "p0", data: Data(repeating: 1, count: 40))
        cache.insert(key: "p1", data: Data(repeating: 2, count: 40))
        XCTAssertEqual(cache.currentCostBytes, 80)

        // Touch p0 so p1 becomes least-recently-used
        XCTAssertNotNil(cache.data(forKey: "p0"))

        // Insert p2 (40 bytes) -> exceeds 100 -> must evict p1 (LRU), keep p0 and p2
        cache.insert(key: "p2", data: Data(repeating: 3, count: 40))
        XCTAssertNil(cache.data(forKey: "p1"))
        XCTAssertNotNil(cache.data(forKey: "p0"))
        XCTAssertNotNil(cache.data(forKey: "p2"))
        XCTAssertEqual(cache.currentCostBytes, 80)

        // Clearing chapter cache resets memory usage to 0
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.currentCostBytes, 0)
    }

    // MARK: - Seam 9: MangaArchiveExporter (Lossless CBZ & WebP->JPG Image EPUB)

    func testMangaArchiveExporterBuildsLosslessCBZAndJPEGTranscodedEPUB() throws {
        // Build a minimal real 2x2 PNG and a minimal real 1x1 lossless WebP (RIFF...WEBP)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        // Valid 1x1 lossless WebP binary literal (VP8L)
        let webpData = Data([
            0x52, 0x49, 0x46, 0x46, 0x1A, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4C,
            0x0D, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x00, 0x00,
            0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE,
            0x07, 0x00
        ])

        let p1 = DownloadedImageAsset(url: "https://cdn.example/1.webp", data: webpData, fileExtension: "webp", mimeType: "image/webp", width: 1, height: 1)
        let p2 = DownloadedImageAsset(url: "https://cdn.example/2.png", data: pngData, fileExtension: "png", mimeType: "image/png", width: 2, height: 2)
        let chapterInput = MangaChapterExportInput(
            chapterTitle: "第1话",
            pages: [p1, p2]
        )
        let detail = BookDetail(
            bookId: "yaoyeluying",
            sourceId: "copymanga",
            contentKind: .manga,
            baseURL: "https://api.2025copy.com",
            title: "摇曳露营",
            author: "Afro",
            publisher: "拷贝漫画",
            status: "连载中",
            lastUpdated: "2026-11-24",
            wordCount: "共 1 话",
            popularity: "",
            latestChapter: "第1话",
            tags: ["日常"],
            description: "露营故事",
            coverURL: "",
            catalogURL: "",
            volumes: [],
            recommendations: []
        )

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("shiori-manga-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. CBZ preserves raw original bytes without transcoding
        let cbzURL = tmpDir.appendingPathComponent("camp.cbz")
        try MangaArchiveExporter.exportCBZ(chapters: [chapterInput], outputURL: cbzURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cbzURL.path))

        let cbzUnzipDir = tmpDir.appendingPathComponent("unzip_cbz")
        try unzipArchive(cbzURL, to: cbzUnzipDir)
        let cbzPage1 = try Data(contentsOf: cbzUnzipDir.appendingPathComponent("001_0001.webp"))
        XCTAssertEqual(cbzPage1, webpData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cbzUnzipDir.appendingPathComponent("001_0002.png").path))

        // 2. Image EPUB transcodes WebP -> JPEG and outputs valid EPUB metadata/TOC/nav
        let epubURL = tmpDir.appendingPathComponent("camp.epub")
        try MangaArchiveExporter.exportImageEPUB(
            detail: detail,
            chapters: [chapterInput],
            coverAsset: p2,
            outputURL: epubURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubURL.path))

        let epubUnzipDir = tmpDir.appendingPathComponent("unzip_epub")
        try unzipArchive(epubURL, to: epubUnzipDir)
        let mimetype = try String(contentsOf: epubUnzipDir.appendingPathComponent("mimetype"), encoding: .utf8)
        XCTAssertEqual(mimetype, "application/epub+zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubUnzipDir.appendingPathComponent("META-INF/container.xml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubUnzipDir.appendingPathComponent("OEBPS/content.opf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubUnzipDir.appendingPathComponent("OEBPS/toc.ncx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: epubUnzipDir.appendingPathComponent("OEBPS/nav.xhtml").path))

        let transcodedImg = try Data(contentsOf: epubUnzipDir.appendingPathComponent("OEBPS/Images/001_0001.jpg"))
        XCTAssertEqual(Array(transcodedImg.prefix(2)), [0xFF, 0xD8]) // JPEG SOI marker
    }

    func testCopymangaAutoFailsOverFromDeadMirrorAndNullResultsAndSupportsChapterV1Endpoint() async throws {
        final class FailoverTransport: HTTPTransport, @unchecked Sendable {
            var attemptedHosts: [String] = []
            func send(_ request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
                let host = request.url.host ?? ""
                attemptedHosts.append(host)
                // Dead domain drops HTTP/2 stream
                if host == "api.2025copy.com" {
                    throw SourceError.networkError("网络连接已中断")
                }
                // Signature-gated domain returns results: null for comic2
                if host == "api.copy2000.online" && request.url.path.contains("/comic2/") {
                    let body = #"{"code":200,"message":"请求成功","results":null}"#
                    return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                }
                // Live partner mirror mapi.hotmangasd.com succeeds on /comic2, /chapters, and /chapter/{uuid}
                if host == "mapi.hotmangasd.com" {
                    if request.url.path == "/api/v3/comic2/modujingbingdenuli" {
                        let body = """
                        {"code":200,"results":{
                          "comic":{"name":"魔都精兵的奴隸","path_word":"modujingbingdenuli","brief":"简介","cover":"https://sm.mangafunb.fun/cover.jpg","author":[{"name":"竹村洋平"}],"theme":[{"name":"冒险"}],"status":{"display":"连载中"}},
                          "groups":{"default":{"path_word":"default","name":"默认","count":1}}
                        }}
                        """
                        return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                    }
                    if request.url.path == "/api/v3/comic/modujingbingdenuli/group/default/chapters" {
                        let body = """
                        {"code":200,"results":{"total":1,"list":[{"uuid":"ch-01","name":"第01话","index":0,"size":2}]}}
                        """
                        return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                    }
                    if request.url.path == "/api/v3/comic/modujingbingdenuli/chapter/ch-01" {
                        let body = """
                        {"code":200,"results":{"chapter":{
                          "uuid":"ch-01","name":"第01话",
                          "contents":[{"url":"https://sm.mangafunb.fun/1.jpg.h1500x.webp"},{"url":"https://sm.mangafunb.fun/2.jpg.h1500x.webp"}]
                        }}}
                        """
                        return HTTPTransportResponse(statusCode: 200, data: Data(body.utf8), finalURL: request.url.absoluteString)
                    }
                }
                return HTTPTransportResponse(statusCode: 404, data: Data(), finalURL: request.url.absoluteString)
            }
        }

        // Deprecated mirror migrates to working default
        XCTAssertEqual(CopymangaPlugin.officialMirrors.first, "https://mapi.hotmangasd.com")
        XCTAssertEqual(CopymangaPlugin.migrateLegacyMirrorIfNeeded("https://api.2025copy.com"), "https://mapi.hotmangasd.com")

        // Runtime auto-failover when explicitly starting on a dead/broken mirror
        let transport = FailoverTransport()
        let plugin = CopymangaPlugin(
            baseURL: "https://api.copy2000.online",
            politeDelaySeconds: 0,
            httpRuntime: HTTPRuntime(transport: transport)
        )
        let detail = try await plugin.fetchBookDetail(bookIdOrURL: "modujingbingdenuli", onProgress: nil)
        XCTAssertEqual(detail.title, "魔都精兵的奴隸")
        let chap = try XCTUnwrap(detail.volumes.first?.chapters.first)
        let content = try await plugin.fetchChapterContent(chapter: chap, book: detail)
        XCTAssertEqual(content.imageURLs.count, 2)
        XCTAssertTrue(transport.attemptedHosts.contains("mapi.hotmangasd.com"))
    }

    private func unzipArchive(_ archiveURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-oq", archiveURL.path, "-d", destination.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }
}
