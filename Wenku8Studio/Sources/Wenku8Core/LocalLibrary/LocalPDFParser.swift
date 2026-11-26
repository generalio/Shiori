import AppKit
import Foundation
import PDFKit

public struct ParsedPDFMetadata: Sendable {
    public let title: String
    public let author: String
    public let publisher: String
    public let summary: String
    public let tags: [String]
    public let pageCount: Int
    public let volumes: [VolumeItem]
}

/// Reference-only native PDFKit parser for metadata, first-page cover thumbnail rendering,
/// and outline/page-section TOC extraction.
public enum LocalPDFParser {
    public static func parseBook(
        at url: URL,
        bookId: String,
        coverCacheOutputURL: URL? = nil
    ) throws -> ParsedPDFMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalLibraryError.fileMissing(bookId: bookId, filePath: url.path)
        }
        guard let document = PDFDocument(url: url) else {
            throw LocalLibraryError.invalidPDF("无法打开 PDF 文件或文件已损坏：\(url.lastPathComponent)")
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw LocalLibraryError.invalidPDF("PDF 文件不含任何页面：\(url.lastPathComponent)")
        }

        let attrs = document.documentAttributes ?? [:]
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let rawTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = rawTitle.isEmpty ? fallbackTitle : rawTitle
        let rawAuthor = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = rawAuthor.isEmpty ? "未知作者" : rawAuthor
        let publisher = (attrs[PDFDocumentAttribute.creatorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = (attrs[PDFDocumentAttribute.subjectAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var tags: [String] = []
        if let kwArray = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            tags = kwArray.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let kwStr = attrs[PDFDocumentAttribute.keywordsAttribute] as? String {
            tags = kwStr
                .components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        // Render first page as cover thumbnail
        if let coverCacheOutputURL, let firstPage = document.page(at: 0) {
            renderCoverThumbnail(page: firstPage, to: coverCacheOutputURL)
        }

        let volumes = buildVolumes(from: document, bookId: bookId)

        return ParsedPDFMetadata(
            title: title,
            author: author,
            publisher: publisher,
            summary: summary,
            tags: tags,
            pageCount: pageCount,
            volumes: volumes
        )
    }

    public static func makeLocalPDFURL(bookId: String, pageIndex: Int) -> String {
        "local-pdf://\(bookId)?page=\(max(0, pageIndex))"
    }

    public static func parseLocalPDFURL(_ rawURL: String) -> (bookId: String, pageIndex: Int)? {
        guard rawURL.hasPrefix("local-pdf://") else { return nil }
        let body = String(rawURL.dropFirst("local-pdf://".count))
        let parts = body.components(separatedBy: "?")
        let bookId = parts[0]
        guard !bookId.isEmpty else { return nil }
        var pageIndex = 0
        if parts.count > 1 {
            for pair in parts[1].components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 && kv[0] == "page", let idx = Int(kv[1]) {
                    pageIndex = max(0, idx)
                }
            }
        }
        return (bookId, pageIndex)
    }

    private static func buildVolumes(from document: PDFDocument, bookId: String) -> [VolumeItem] {
        let pageCount = document.pageCount
        if let root = document.outlineRoot, root.numberOfChildren > 0 {
            var topLevel: [PDFOutline] = []
            for i in 0..<root.numberOfChildren {
                if let child = root.child(at: i) {
                    topLevel.append(child)
                }
            }

            let hasNested = topLevel.contains { $0.numberOfChildren > 0 }
            if hasNested {
                var volumes: [VolumeItem] = []
                var volIdx = 1
                for item in topLevel {
                    let groupTitle = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let leaves = collectOutlineEntries(from: item, in: document)
                    var chapters: [ChapterItem] = []
                    for (cIdx, entry) in leaves.enumerated() {
                        chapters.append(
                            ChapterItem(
                                id: "\(bookId)_pdf_v\(volIdx)_c\(cIdx + 1)",
                                sourceId: LocalLibraryPlugin.sourceId,
                                title: "\(entry.title)（P.\(entry.pageIndex + 1)）",
                                url: makeLocalPDFURL(bookId: bookId, pageIndex: entry.pageIndex),
                                volumeIndex: volIdx,
                                chapterIndex: cIdx + 1,
                                isIllustrationChapter: false
                            )
                        )
                    }
                    if !chapters.isEmpty {
                        volumes.append(
                            VolumeItem(
                                id: "\(bookId)_pdf_vol_\(volIdx)",
                                index: volIdx,
                                title: groupTitle.isEmpty ? "第 \(volIdx) 部分" : groupTitle,
                                chapters: chapters
                            )
                        )
                        volIdx += 1
                    }
                }
                if !volumes.isEmpty { return volumes }
            } else {
                var chapters: [ChapterItem] = []
                for (idx, item) in topLevel.enumerated() {
                    let label = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let pageIdx = resolvePageIndex(for: item, in: document) ?? 0
                    let displayTitle = label.isEmpty ? "第 \(pageIdx + 1) 页" : "\(label)（P.\(pageIdx + 1)）"
                    chapters.append(
                        ChapterItem(
                            id: "\(bookId)_pdf_v1_c\(idx + 1)",
                            sourceId: LocalLibraryPlugin.sourceId,
                            title: displayTitle,
                            url: makeLocalPDFURL(bookId: bookId, pageIndex: pageIdx),
                            volumeIndex: 1,
                            chapterIndex: idx + 1,
                            isIllustrationChapter: false
                        )
                    )
                }
                if !chapters.isEmpty {
                    return [VolumeItem(id: "\(bookId)_pdf_vol_1", index: 1, title: "PDF 书签目录", chapters: chapters)]
                }
            }
        }

        // Fallback when PDF has no embedded outline
        if pageCount <= 30 {
            let chap = ChapterItem(
                id: "\(bookId)_pdf_v1_c1",
                sourceId: LocalLibraryPlugin.sourceId,
                title: "全书正文（共 \(pageCount) 页）",
                url: makeLocalPDFURL(bookId: bookId, pageIndex: 0),
                volumeIndex: 1,
                chapterIndex: 1,
                isIllustrationChapter: false
            )
            return [VolumeItem(id: "\(bookId)_pdf_vol_1", index: 1, title: "PDF 页面", chapters: [chap])]
        }

        let step = 25
        var chapters: [ChapterItem] = []
        var start = 0
        var cIdx = 1
        while start < pageCount {
            let end = min(pageCount - 1, start + step - 1)
            chapters.append(
                ChapterItem(
                    id: "\(bookId)_pdf_v1_c\(cIdx)",
                    sourceId: LocalLibraryPlugin.sourceId,
                    title: "第 \(start + 1) – \(end + 1) 页",
                    url: makeLocalPDFURL(bookId: bookId, pageIndex: start),
                    volumeIndex: 1,
                    chapterIndex: cIdx,
                    isIllustrationChapter: false
                )
            )
            start += step
            cIdx += 1
        }
        return [VolumeItem(id: "\(bookId)_pdf_vol_1", index: 1, title: "PDF 页面分段（共 \(pageCount) 页）", chapters: chapters)]
    }

    private static func collectOutlineEntries(
        from outline: PDFOutline,
        in document: PDFDocument
    ) -> [(title: String, pageIndex: Int)] {
        var result: [(String, Int)] = []
        let label = (outline.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = resolvePageIndex(for: outline, in: document), !label.isEmpty {
            result.append((label, idx))
        }
        for i in 0..<outline.numberOfChildren {
            if let child = outline.child(at: i) {
                result.append(contentsOf: collectOutlineEntries(from: child, in: document))
            }
        }
        return result
    }

    private static func resolvePageIndex(for outline: PDFOutline, in document: PDFDocument) -> Int? {
        if let page = outline.destination?.page {
            return document.index(for: page)
        }
        if let goTo = outline.action as? PDFActionGoTo, let page = goTo.destination.page {
            return document.index(for: page)
        }
        return nil
    }

    private static func renderCoverThumbnail(page: PDFPage, to outputURL: URL) {
        let dir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bounds = page.bounds(for: .mediaBox)
        let aspect = (bounds.width > 0 && bounds.height > 0) ? (bounds.width / bounds.height) : 0.7
        let targetHeight: CGFloat = 510
        let targetWidth = max(240, min(480, targetHeight * aspect))
        let thumb = page.thumbnail(of: NSSize(width: targetWidth, height: targetHeight), for: .mediaBox)
        guard let tiff = thumb.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.84]) else {
            return
        }
        try? jpeg.write(to: outputURL, options: .atomic)
    }
}
