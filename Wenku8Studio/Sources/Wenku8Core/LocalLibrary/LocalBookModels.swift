import Foundation

public enum LocalBookFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case epub
    case pdf

    public var displayBadge: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        }
    }

    public static func detect(from url: URL) -> LocalBookFormat? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        default: return nil
        }
    }
}

public enum LocalBookOrigin: String, Codable, Hashable, Sendable {
    case localFile
    case appleBooksICloud

    public var displayLabel: String {
        switch self {
        case .localFile: return "本地文件"
        case .appleBooksICloud: return "Apple Books 引用"
        }
    }
}

public enum LocalFileAvailability: Equatable, Sendable {
    case available
    case iCloudNotDownloaded
    case missing
}

public struct LocalBookRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let format: LocalBookFormat
    public var origin: LocalBookOrigin
    public var filePath: String
    public var title: String
    public var author: String
    public var publisher: String
    public var summary: String
    public var tags: [String]
    public var coverCachePath: String
    public var contentKind: ContentKind
    public var pageCount: Int
    public var chapterCount: Int
    public var fileSizeBytes: Int64
    public var addedAt: Date
    public var lastOpenedAt: Date?

    public init(
        id: String,
        format: LocalBookFormat,
        origin: LocalBookOrigin,
        filePath: String,
        title: String,
        author: String,
        publisher: String = "",
        summary: String = "",
        tags: [String] = [],
        coverCachePath: String = "",
        contentKind: ContentKind = .lightNovel,
        pageCount: Int = 0,
        chapterCount: Int = 0,
        fileSizeBytes: Int64 = 0,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.format = format
        self.origin = origin
        self.filePath = filePath
        self.title = title
        self.author = author
        self.publisher = publisher
        self.summary = summary
        self.tags = tags
        self.coverCachePath = coverCachePath
        self.contentKind = contentKind
        self.pageCount = pageCount
        self.chapterCount = chapterCount
        self.fileSizeBytes = fileSizeBytes
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
    }

    public var coverURLString: String {
        guard !coverCachePath.isEmpty else { return "" }
        return URL(fileURLWithPath: coverCachePath).absoluteString
    }

    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    public var formattedFileSize: String {
        guard fileSizeBytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    public var metricsDisplay: String {
        var parts: [String] = []
        switch format {
        case .pdf:
            if pageCount > 0 { parts.append("\(pageCount) 页") }
        case .epub:
            if chapterCount > 0 { parts.append("\(chapterCount) 章") }
        }
        let sizeText = formattedFileSize
        if !sizeText.isEmpty {
            parts.append(sizeText)
        }
        return parts.joined(separator: " · ")
    }

    public func toBookmarkEntry() -> BookmarkEntry {
        BookmarkEntry(
            id: id,
            sourceId: LocalLibraryPlugin.sourceId,
            title: title,
            author: author.isEmpty ? "未知作者" : author,
            coverURL: coverURLString,
            publisher: publisher.isEmpty ? format.displayBadge : publisher,
            status: format.displayBadge,
            wordCount: metricsDisplay,
            lastUpdated: "",
            popularity: "",
            tags: tags.isEmpty ? [format.displayBadge, origin.displayLabel] : tags,
            summary: summary,
            addedAt: addedAt
        )
    }

    public func toAuthorBookItem() -> AuthorBookItem {
        AuthorBookItem(
            id: id,
            sourceId: LocalLibraryPlugin.sourceId,
            title: title,
            author: author.isEmpty ? "未知作者" : author,
            category: publisher.isEmpty ? format.displayBadge : publisher,
            updatedAt: "",
            wordCount: metricsDisplay,
            status: format.displayBadge,
            popularity: "",
            tags: tags.isEmpty ? [format.displayBadge, origin.displayLabel] : tags,
            summary: summary,
            coverURL: coverURLString
        )
    }
}

public struct AppleBooksCandidate: Identifiable, Hashable, Sendable {
    public var id: String { filePath }
    public let filePath: String
    public let displayName: String
    public let format: LocalBookFormat
    public let isPackageDirectory: Bool
    public let isDownloadedLocally: Bool
    public let fileSizeBytes: Int64
    public let modifiedAt: Date?
    public let isAlreadyImported: Bool

    public init(
        filePath: String,
        displayName: String,
        format: LocalBookFormat,
        isPackageDirectory: Bool,
        isDownloadedLocally: Bool,
        fileSizeBytes: Int64,
        modifiedAt: Date?,
        isAlreadyImported: Bool
    ) {
        self.filePath = filePath
        self.displayName = displayName
        self.format = format
        self.isPackageDirectory = isPackageDirectory
        self.isDownloadedLocally = isDownloadedLocally
        self.fileSizeBytes = fileSizeBytes
        self.modifiedAt = modifiedAt
        self.isAlreadyImported = isAlreadyImported
    }

    public var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    public var formattedSize: String {
        guard fileSizeBytes > 0 else { return isDownloadedLocally ? "—" : "云端占位" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

public enum LocalLibraryError: LocalizedError, Sendable {
    case unsupportedFormat(String)
    case fileMissing(bookId: String, filePath: String)
    case iCloudDownloadRequired(bookId: String, filePath: String)
    case iCloudDownloadTimedOut(String)
    case invalidEPUB(String)
    case invalidPDF(String)
    case appleBooksNotInstalled
    case appleBooksOpenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            return "不支持的文件格式（仅支持 EPUB / PDF）：\(name)"
        case .fileMissing(_, let path):
            return "原文件已移动或被删除：\(URL(fileURLWithPath: path).lastPathComponent)"
        case .iCloudDownloadRequired(_, let path):
            return "该书籍目前仅存于 iCloud 云端，尚未下载到本机：\(URL(fileURLWithPath: path).lastPathComponent)"
        case .iCloudDownloadTimedOut(let name):
            return "从 iCloud 下载《\(name)》超时，请在 Finder 或 Apple Books 中确认网络与 iCloud 同步状态。"
        case .invalidEPUB(let detail):
            return "EPUB 解析失败：\(detail)"
        case .invalidPDF(let detail):
            return "PDF 解析失败：\(detail)"
        case .appleBooksNotInstalled:
            return "未在系统中找到 Apple Books（/System/Applications/Books.app）。"
        case .appleBooksOpenFailed(let msg):
            return "发送到 Apple Books 失败：\(msg)"
        }
    }
}
