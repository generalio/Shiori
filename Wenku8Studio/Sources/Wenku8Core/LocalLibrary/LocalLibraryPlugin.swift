import Foundation

/// Built-in local library source (`sourceId = "local"`) exposing reference-only local EPUB/PDF
/// and Apple Books iCloud books through Shiori's unified `BookSourcePlugin` contract.
public final class LocalLibraryPlugin: BookSourcePlugin, @unchecked Sendable {
    public static let sourceId = "local"

    public let store: LocalLibraryStore

    public let descriptor = BookSourceDescriptor(
        id: LocalLibraryPlugin.sourceId,
        displayName: "本地书库",
        shortBadge: "本地",
        subtitle: "本地 EPUB / PDF 与 Apple Books 引用书库",
        defaultMirrors: ["file://local"],
        supportedSearchScopes: [.articleName, .author],
        requiresBrowserRuntime: false,
        contentKind: .mixed,
        isLocalSource: true
    )

    public init(store: LocalLibraryStore = LocalLibraryStore()) {
        self.store = store
    }

    public func canHandle(rawInput: String) -> String? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("local:") {
            let id = String(trimmed.dropFirst("local:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        if trimmed.hasPrefix("loc_") {
            return trimmed
        }
        if trimmed.hasPrefix("/") {
            let url = URL(fileURLWithPath: trimmed)
            if LocalBookFormat.detect(from: url) != nil, FileManager.default.fileExists(atPath: url.path) {
                return trimmed
            }
        }
        return nil
    }

    public func updateConfig(_ config: SourceRuntimeConfig) async {}
    public func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async {}

    public func search(query: String, scope: SearchScope, page: Int) async throws -> PagedBookResult {
        guard page <= 1 else {
            return PagedBookResult(items: [], currentPage: page, totalPages: 1)
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = await store.allRecords()
        let matched = records.filter { rec in
            guard !q.isEmpty else { return true }
            switch scope {
            case .author:
                return rec.author.lowercased().contains(q)
            case .bookId:
                return rec.id.lowercased().contains(q)
            case .articleName:
                return rec.title.lowercased().contains(q)
                    || rec.author.lowercased().contains(q)
                    || rec.summary.lowercased().contains(q)
                    || rec.tags.contains { $0.lowercased().contains(q) }
            }
        }
        return PagedBookResult(
            items: matched.map { $0.toAuthorBookItem() },
            currentPage: 1,
            totalPages: 1
        )
    }

    public func fetchBookDetail(
        bookIdOrURL: String,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> BookDetail {
        let cleaned = bookIdOrURL.hasPrefix("local:")
            ? String(bookIdOrURL.dropFirst("local:".count))
            : bookIdOrURL

        let record: LocalBookRecord
        if let existing = await store.record(for: cleaned) {
            record = existing
        } else if cleaned.hasPrefix("/") {
            let url = URL(fileURLWithPath: cleaned)
            let summary = await store.importBooks(urls: [url], origin: .localFile, onProgress: onProgress)
            if let imported = summary.imported.first {
                record = imported
            } else if let existing = await store.record(forFilePath: cleaned) {
                record = existing
            } else {
                throw LocalLibraryError.invalidEPUB(summary.failed.first?.reason ?? "导入失败")
            }
        } else {
            throw SourceError.notFound("未在本地书库中找到该书籍：\(cleaned)")
        }

        let availability = await store.fileAvailability(for: record.id)
        switch availability {
        case .missing:
            throw LocalLibraryError.fileMissing(bookId: record.id, filePath: record.filePath)
        case .iCloudNotDownloaded:
            throw LocalLibraryError.iCloudDownloadRequired(bookId: record.id, filePath: record.filePath)
        case .available:
            break
        }

        await store.markOpened(id: record.id)
        onProgress?("正在解析本地 \(record.format.displayBadge) 目录：《\(record.title)》…")

        switch record.format {
        case .epub:
            let parsed = try LocalEPUBParser.parseBook(at: record.fileURL, bookId: record.id)
            return BookDetail(
                bookId: record.id,
                sourceId: Self.sourceId,
                contentKind: parsed.contentKind,
                baseURL: record.fileURL.absoluteString,
                title: parsed.title,
                author: parsed.author,
                publisher: parsed.publisher.isEmpty ? record.origin.displayLabel : parsed.publisher,
                status: record.format.displayBadge,
                lastUpdated: "",
                wordCount: record.metricsDisplay,
                popularity: "",
                latestChapter: parsed.volumes.last?.chapters.last?.title ?? "",
                tags: parsed.tags.isEmpty ? [record.format.displayBadge, record.origin.displayLabel] : parsed.tags,
                description: parsed.summary,
                coverURL: record.coverURLString,
                catalogURL: record.filePath,
                volumes: parsed.volumes,
                recommendations: []
            )

        case .pdf:
            let parsed = try LocalPDFParser.parseBook(at: record.fileURL, bookId: record.id)
            return BookDetail(
                bookId: record.id,
                sourceId: Self.sourceId,
                contentKind: .lightNovel,
                baseURL: record.fileURL.absoluteString,
                title: parsed.title,
                author: parsed.author,
                publisher: parsed.publisher.isEmpty ? record.origin.displayLabel : parsed.publisher,
                status: record.format.displayBadge,
                lastUpdated: "",
                wordCount: record.metricsDisplay,
                popularity: "",
                latestChapter: "共 \(parsed.pageCount) 页",
                tags: parsed.tags.isEmpty ? [record.format.displayBadge, record.origin.displayLabel] : parsed.tags,
                description: parsed.summary,
                coverURL: record.coverURLString,
                catalogURL: record.filePath,
                volumes: parsed.volumes,
                recommendations: []
            )
        }
    }

    public func fetchChapterContent(chapter: ChapterItem, book: BookDetail) async throws -> ChapterContent {
        let bookId: String
        if !book.bookId.isEmpty {
            bookId = book.bookId
        } else if let extracted = LocalEPUBParser.extractBookId(fromLocalEPUBURL: chapter.url) {
            bookId = extracted
        } else if let parsedPDF = LocalPDFParser.parseLocalPDFURL(chapter.url) {
            bookId = parsedPDF.bookId
        } else {
            throw SourceError.invalidInput("无法识别本地章节所属书籍：\(chapter.url)")
        }

        guard let record = await store.record(for: bookId) else {
            throw SourceError.notFound("本地书库中已不存在该书籍记录：\(bookId)")
        }

        let availability = await store.fileAvailability(for: record.id)
        switch availability {
        case .missing:
            throw LocalLibraryError.fileMissing(bookId: record.id, filePath: record.filePath)
        case .iCloudNotDownloaded:
            throw LocalLibraryError.iCloudDownloadRequired(bookId: record.id, filePath: record.filePath)
        case .available:
            break
        }

        switch record.format {
        case .epub:
            return try LocalEPUBParser.readChapterContent(
                at: record.fileURL,
                bookId: record.id,
                chapter: chapter,
                contentKind: record.contentKind
            )

        case .pdf:
            return ChapterContent(
                chapter: chapter,
                tokens: [],
                imageURLs: [],
                contentKind: .lightNovel
            )
        }
    }

    public func downloadImage(url: String, referer: String?) async throws -> DownloadedImageAsset {
        if url.hasPrefix("file://"), let fileURL = URL(string: url) {
            let data = try Data(contentsOf: fileURL)
            let ext = fileURL.pathExtension.lowercased()
            let normalizedExt = ext.isEmpty ? "jpg" : ext
            let mime = normalizedExt == "png" ? "image/png" : "image/jpeg"
            return DownloadedImageAsset(
                url: url,
                data: data,
                fileExtension: normalizedExt,
                mimeType: mime,
                width: 0,
                height: 0
            )
        }

        if url.hasPrefix("local-epub://"),
           let bookId = LocalEPUBParser.extractBookId(fromLocalEPUBURL: url),
           let relPath = LocalEPUBParser.extractRelativePath(fromLocalEPUBURL: url),
           let record = await store.record(for: bookId) {
            return try LocalEPUBParser.readImageData(at: record.fileURL, relativePath: relPath)
        }

        throw SourceError.notFound("无法加载本地图片资源：\(url)")
    }

    public func downloadImages(
        urls: [String],
        referer: String?,
        maxConcurrency: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [String: DownloadedImageAsset] {
        var result: [String: DownloadedImageAsset] = [:]
        let total = urls.count
        for (idx, u) in urls.enumerated() {
            if let asset = try? await downloadImage(url: u, referer: referer) {
                result[u] = asset
            }
            onProgress?(idx + 1, total)
        }
        return result
    }
}
