import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MangaExportFormat: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case cbz = "CBZ 漫画包"
    case epub = "图版 EPUB"

    public var id: String { rawValue }
    public var fileExtension: String {
        switch self {
        case .cbz: return "cbz"
        case .epub: return "epub"
        }
    }
}

public struct MangaChapterExportInput: Sendable {
    public let chapterTitle: String
    public let pages: [DownloadedImageAsset]

    public init(chapterTitle: String, pages: [DownloadedImageAsset]) {
        self.chapterTitle = chapterTitle
        self.pages = pages
    }
}

public enum MangaArchiveExporterError: LocalizedError, Sendable {
    case noPagesToExport
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPagesToExport: return "没有可导出的漫画页面"
        case .zipFailed(let msg): return "漫画归档打包失败：\(msg)"
        }
    }
}

/// Exports manga chapters as lossless `.cbz` archives (zero re-encoding) or
/// widely compatible image-based `.epub` packages (auto-transcoding `.webp` to JPEG).
public enum MangaArchiveExporter {
    public static func exportCBZ(
        chapters: [MangaChapterExportInput],
        outputURL: URL
    ) throws {
        let nonEmpty = chapters.filter { !$0.pages.isEmpty }
        guard !nonEmpty.isEmpty else {
            throw MangaArchiveExporterError.noPagesToExport
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("shiori-cbz-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        var writtenFiles: [String] = []
        for (cIdx, chap) in nonEmpty.enumerated() {
            for (pIdx, page) in chap.pages.enumerated() {
                let ext = page.fileExtension.isEmpty ? "jpg" : page.fileExtension.lowercased()
                let fileName = String(format: "%03d_%04d.%@", cIdx + 1, pIdx + 1, ext)
                try page.data.write(to: tempRoot.appendingPathComponent(fileName), options: .atomic)
                writtenFiles.append(fileName)
            }
        }

        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try runZip(args: ["-0", "-q", outputURL.path] + writtenFiles, cwd: tempRoot)
    }

    public static func exportImageEPUB(
        detail: BookDetail,
        chapters: [MangaChapterExportInput],
        coverAsset: DownloadedImageAsset?,
        outputURL: URL
    ) throws {
        let nonEmpty = chapters.filter { !$0.pages.isEmpty }
        guard !nonEmpty.isEmpty else {
            throw MangaArchiveExporterError.noPagesToExport
        }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("shiori-manga-epub-\(UUID().uuidString)")
        let metaInfDir = tempRoot.appendingPathComponent("META-INF")
        let oebpsDir = tempRoot.appendingPathComponent("OEBPS")
        let imagesDir = oebpsDir.appendingPathComponent("Images")
        let textDir = oebpsDir.appendingPathComponent("Text")

        try fm.createDirectory(at: metaInfDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: textDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // 1. mimetype
        try "application/epub+zip".write(
            to: tempRoot.appendingPathComponent("mimetype"),
            atomically: true,
            encoding: .utf8
        )

        // 2. META-INF/container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInfDir.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        // 3. Cover image & cover.xhtml
        let chosenCover = coverAsset ?? nonEmpty.first?.pages.first
        var coverFileName: String?
        var coverMime = "image/jpeg"
        if let chosenCover {
            let normalized = normalizeForEPUB(chosenCover)
            let name = "000_cover.\(normalized.ext)"
            try normalized.data.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            coverFileName = name
            coverMime = normalized.mime

            let coverHTML = """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head>
              <title>Cover</title>
              <style>html,body{margin:0;padding:0;height:100%;background:#000;text-align:center;}img{max-width:100%;max-height:100%;object-fit:contain;}</style>
            </head>
            <body><img src="../Images/\(name)" alt="Cover"/></body>
            </html>
            """
            try coverHTML.write(to: textDir.appendingPathComponent("cover.xhtml"), atomically: true, encoding: .utf8)
        }

        // 4. Write all pages & XHTML wrappers
        struct PageManifestEntry {
            let idBase: String
            let imageFileName: String
            let imageMime: String
            let xhtmlFileName: String
        }
        struct ChapterTOCEntry {
            let title: String
            let firstXHTML: String
        }

        var pageEntries: [PageManifestEntry] = []
        var tocEntries: [ChapterTOCEntry] = []

        for (cIdx, chap) in nonEmpty.enumerated() {
            var firstXHTMLForChapter: String?
            for (pIdx, page) in chap.pages.enumerated() {
                let normalized = normalizeForEPUB(page)
                let base = String(format: "%03d_%04d", cIdx + 1, pIdx + 1)
                let imgName = "\(base).\(normalized.ext)"
                let xhtmlName = "\(base).xhtml"

                try normalized.data.write(to: imagesDir.appendingPathComponent(imgName), options: .atomic)

                let xhtml = """
                <?xml version="1.0" encoding="utf-8"?>
                <!DOCTYPE html>
                <html xmlns="http://www.w3.org/1999/xhtml">
                <head>
                  <title>\(xmlEscape(chap.chapterTitle))</title>
                  <style>html,body{margin:0;padding:0;text-align:center;background:#000;}img{width:100%;height:auto;display:block;margin:0 auto;}</style>
                </head>
                <body><img src="../Images/\(imgName)" alt="\(base)"/></body>
                </html>
                """
                try xhtml.write(to: textDir.appendingPathComponent(xhtmlName), atomically: true, encoding: .utf8)

                if firstXHTMLForChapter == nil {
                    firstXHTMLForChapter = xhtmlName
                }
                pageEntries.append(PageManifestEntry(
                    idBase: base,
                    imageFileName: imgName,
                    imageMime: normalized.mime,
                    xhtmlFileName: xhtmlName
                ))
            }
            if let firstXHTMLForChapter {
                tocEntries.append(ChapterTOCEntry(title: chap.chapterTitle, firstXHTML: firstXHTMLForChapter))
            }
        }

        // 5. OEBPS/nav.xhtml (EPUB 3)
        let navItems = tocEntries.map { entry in
            "      <li><a href=\"Text/\(entry.firstXHTML)\">\(xmlEscape(entry.title))</a></li>"
        }.joined(separator: "\n")
        let navXHTML = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(xmlEscape(detail.title))</title></head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>目录</h1>
            <ol>
        \(navItems)
            </ol>
          </nav>
        </body>
        </html>
        """
        try navXHTML.write(to: oebpsDir.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        // 6. OEBPS/toc.ncx (EPUB 2 compatibility)
        let navPoints = tocEntries.enumerated().map { idx, entry in
            """
                <navPoint id="navPoint-\(idx + 1)" playOrder="\(idx + 1)">
                  <navLabel><text>\(xmlEscape(entry.title))</text></navLabel>
                  <content src="Text/\(entry.firstXHTML)"/>
                </navPoint>
            """
        }.joined(separator: "\n")
        let tocNCX = """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="shiori-manga-\(xmlEscape(detail.bookId))"/>
            <meta name="dtb:depth" content="1"/>
          </head>
          <docTitle><text>\(xmlEscape(detail.title))</text></docTitle>
          <navMap>
        \(navPoints)
          </navMap>
        </ncx>
        """
        try tocNCX.write(to: oebpsDir.appendingPathComponent("toc.ncx"), atomically: true, encoding: .utf8)

        // 7. OEBPS/content.opf
        let isoNow = ISO8601DateFormatter().string(from: Date())
        let subjects = detail.tags.map { "    <dc:subject>\(xmlEscape($0))</dc:subject>" }.joined(separator: "\n")
        var manifestLines: [String] = [
            #"    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#,
            #"    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
        ]
        var spineLines: [String] = []
        if let coverFileName {
            manifestLines.append(#"    <item id="cover-image" href="Images/\#(coverFileName)" media-type="\#(coverMime)" properties="cover-image"/>"#)
            manifestLines.append(#"    <item id="cover-page" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>"#)
            spineLines.append(#"    <itemref idref="cover-page"/>"#)
        }
        for p in pageEntries {
            manifestLines.append(#"    <item id="img_\#(p.idBase)" href="Images/\#(p.imageFileName)" media-type="\#(p.imageMime)"/>"#)
            manifestLines.append(#"    <item id="page_\#(p.idBase)" href="Text/\#(p.xhtmlFileName)" media-type="application/xhtml+xml"/>"#)
            spineLines.append(#"    <itemref idref="page_\#(p.idBase)"/>"#)
        }

        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package version="3.0" unique-identifier="BookId" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="BookId">shiori-manga-\(xmlEscape(detail.bookId))</dc:identifier>
            <dc:title>\(xmlEscape(detail.title))</dc:title>
            <dc:creator>\(xmlEscape(detail.author))</dc:creator>
            <dc:language>zh-CN</dc:language>
            <dc:description>\(xmlEscape(detail.description))</dc:description>
        \(subjects)
            <meta property="dcterms:modified">\(isoNow)</meta>
            <meta property="rendition:layout">pre-paginated</meta>
            \(coverFileName != nil ? #"<meta name="cover" content="cover-image"/>"# : "")
          </metadata>
          <manifest>
        \(manifestLines.joined(separator: "\n"))
          </manifest>
          <spine toc="ncx">
        \(spineLines.joined(separator: "\n"))
          </spine>
        </package>
        """
        try opf.write(to: oebpsDir.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        // 8. Package ZIP according to EPUB spec (uncompressed mimetype first)
        try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try runZip(args: ["-0", "-X", "-q", outputURL.path, "mimetype"], cwd: tempRoot)
        try runZip(args: ["-rq", outputURL.path, "META-INF", "OEBPS"], cwd: tempRoot)
    }

    // MARK: - Helpers

    private static func normalizeForEPUB(_ asset: DownloadedImageAsset) -> (data: Data, ext: String, mime: String) {
        let lowerExt = asset.fileExtension.lowercased()
        if lowerExt == "jpg" || lowerExt == "jpeg" {
            return (asset.data, "jpg", "image/jpeg")
        }
        if lowerExt == "png" {
            return (asset.data, "png", "image/png")
        }
        // Transcode WebP / other formats to high-quality JPEG via ImageIO for Apple Books / Kindle compatibility
        if let src = CGImageSourceCreateWithData(asset.data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let outData = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(outData, UTType.jpeg.identifier as CFString, 1, nil) {
                let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.90]
                CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
                if CGImageDestinationFinalize(dest), outData.length > 0 {
                    return (outData as Data, "jpg", "image/jpeg")
                }
            }
        }
        // Fallback: NSImage -> JPEG
        if let nsImg = NSImage(data: asset.data),
           let tiff = nsImg.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.90]) {
            return (jpg, "jpg", "image/jpeg")
        }
        return (asset.data, lowerExt.isEmpty ? "jpg" : lowerExt, asset.mimeType)
    }

    private static func xmlEscape(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func runZip(args: [String], cwd: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = cwd
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "zip exit \(proc.terminationStatus)"
            throw MangaArchiveExporterError.zipFailed(msg)
        }
    }
}
