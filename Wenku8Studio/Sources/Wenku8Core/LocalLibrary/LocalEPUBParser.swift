import AppKit
import Foundation
import ImageIO

public struct ParsedEPUBMetadata: Sendable {
    public let title: String
    public let author: String
    public let publisher: String
    public let summary: String
    public let tags: [String]
    public let coverRelativePath: String?
    public let contentKind: ContentKind
    public let volumes: [VolumeItem]
    public let totalChapters: Int
}

/// Reference-only EPUB parser supporting both standard zipped `.epub` archives and
/// Apple Books unpacked `.epub/` bundle directories without duplicating book files.
public enum LocalEPUBParser {
    // MARK: - Archive Reader Abstraction

    struct ArchiveReader {
        enum Kind {
            case directory(URL)
            case zip(URL)
        }

        let kind: Kind

        init(url: URL) throws {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw LocalLibraryError.fileMissing(bookId: "", filePath: url.path)
            }
            if isDir.boolValue {
                self.kind = .directory(url)
            } else {
                self.kind = .zip(url)
            }
        }

        func readData(relativePath: String) throws -> Data {
            let cleaned = LocalEPUBParser.normalizeArchivePath(relativePath)
            guard !cleaned.isEmpty else {
                throw LocalLibraryError.invalidEPUB("空的内部资源路径")
            }
            switch kind {
            case .directory(let root):
                let target = root.appendingPathComponent(cleaned)
                if FileManager.default.fileExists(atPath: target.path) {
                    return try Data(contentsOf: target)
                }
                // Case-insensitive fallback inside unpacked directory
                if let resolved = Self.findCaseInsensitive(relativePath: cleaned, in: root) {
                    return try Data(contentsOf: resolved)
                }
                throw LocalLibraryError.invalidEPUB("找不到内部文件：\(cleaned)")

            case .zip(let archiveURL):
                return try Self.extractZipEntry(archiveURL: archiveURL, entryPath: cleaned)
            }
        }

        func listEntries() -> [String] {
            switch kind {
            case .directory(let root):
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                let rootPath = root.standardizedFileURL.path
                var results: [String] = []
                for case let url as URL in enumerator {
                    let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    guard isFile else { continue }
                    let full = url.standardizedFileURL.path
                    if full.hasPrefix(rootPath + "/") {
                        results.append(String(full.dropFirst(rootPath.count + 1)))
                    }
                }
                return results

            case .zip(let archiveURL):
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-Z1", archiveURL.path]
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    guard proc.terminationStatus == 0,
                          let text = String(data: data, encoding: .utf8) else { return [] }
                    return text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.hasSuffix("/") }
                } catch {
                    return []
                }
            }
        }

        private static func findCaseInsensitive(relativePath: String, in root: URL) -> URL? {
            let parts = relativePath.split(separator: "/").map(String.init)
            var current = root
            for part in parts {
                let exact = current.appendingPathComponent(part)
                if FileManager.default.fileExists(atPath: exact.path) {
                    current = exact
                    continue
                }
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                      let matched = children.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else {
                    return nil
                }
                current = current.appendingPathComponent(matched)
            }
            return current
        }

        static func escapeUnzipGlob(_ entryPath: String) -> String {
            var out = ""
            out.reserveCapacity(entryPath.count + 4)
            for ch in entryPath {
                switch ch {
                case "[", "]", "*", "?", "\\":
                    out.append("\\")
                    out.append(ch)
                default:
                    out.append(ch)
                }
            }
            return out
        }

        private static func extractZipEntry(archiveURL: URL, entryPath: String) throws -> Data {
            let escaped = escapeUnzipGlob(entryPath)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-qq", "-p", archiveURL.path, escaped]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 && !data.isEmpty {
                return data
            }
            // Retry case-insensitively with `-C`
            let retry = Process()
            retry.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            retry.arguments = ["-qq", "-C", "-p", archiveURL.path, escaped]
            let out2 = Pipe()
            retry.standardOutput = out2
            retry.standardError = Pipe()
            try retry.run()
            let data2 = out2.fileHandleForReading.readDataToEndOfFile()
            retry.waitUntilExit()
            if retry.terminationStatus == 0 && !data2.isEmpty {
                return data2
            }
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LocalLibraryError.invalidEPUB(errMsg.isEmpty ? "无法读取压缩包条目：\(entryPath)" : errMsg)
        }
    }

    // MARK: - Public Parsing API

    public static func parseBook(
        at url: URL,
        bookId: String,
        coverCacheOutputURL: URL? = nil
    ) throws -> ParsedEPUBMetadata {
        let reader = try ArchiveReader(url: url)

        // 1. Locate OPF path from META-INF/container.xml (or fallback scan)
        let opfPath: String
        if let containerData = try? reader.readData(relativePath: "META-INF/container.xml"),
           let parsedOPF = parseContainerXML(containerData) {
            opfPath = normalizeArchivePath(parsedOPF)
        } else if let fallbackOPF = reader.listEntries().first(where: { $0.lowercased().hasSuffix(".opf") }) {
            opfPath = normalizeArchivePath(fallbackOPF)
        } else {
            throw LocalLibraryError.invalidEPUB("未找到 META-INF/container.xml 或 .opf 索引文件")
        }

        let opfData = try reader.readData(relativePath: opfPath)
        let opfDir = parentDirectory(of: opfPath)
        let opf = parseOPF(opfData, opfDir: opfDir)

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let title = opf.title.isEmpty ? fallbackTitle : opf.title
        let author = opf.author.isEmpty ? "未知作者" : opf.author

        // 2. Cover image resolution & optional thumbnail caching
        let coverPath = resolveCoverPath(opf: opf, reader: reader)
        if let coverPath, let coverCacheOutputURL,
           let rawCover = try? reader.readData(relativePath: coverPath) {
            saveDownsampledCover(data: rawCover, to: coverCacheOutputURL, maxPixelSize: 480)
        }

        // 3. Build TOC volumes & chapters (EPUB 3 nav -> EPUB 2 ncx -> OPF spine)
        var volumes: [VolumeItem] = []

        if let navItem = opf.navManifestItem,
           let navData = try? reader.readData(relativePath: navItem.resolvedPath) {
            let navDir = parentDirectory(of: navItem.resolvedPath)
            volumes = parseNavXHTML(navData, navDir: navDir, bookId: bookId)
        }

        if volumes.isEmpty,
           let ncxItem = opf.ncxManifestItem,
           let ncxData = try? reader.readData(relativePath: ncxItem.resolvedPath) {
            let ncxDir = parentDirectory(of: ncxItem.resolvedPath)
            volumes = parseNCX(ncxData, ncxDir: ncxDir, bookId: bookId)
        }

        if volumes.isEmpty {
            volumes = buildSpineFallbackVolumes(opf: opf, reader: reader, bookId: bookId)
        }

        if volumes.isEmpty {
            throw LocalLibraryError.invalidEPUB("未在 EPUB 中解析到任何可读章节")
        }

        // 4. Detect fixed-layout / image-heavy manga EPUB
        let contentKind = detectContentKind(opf: opf, volumes: volumes, reader: reader)
        let totalChapters = volumes.reduce(0) { $0 + $1.chapters.count }

        return ParsedEPUBMetadata(
            title: title,
            author: author,
            publisher: opf.publisher,
            summary: opf.summary,
            tags: opf.subjects,
            coverRelativePath: coverPath,
            contentKind: contentKind,
            volumes: volumes,
            totalChapters: totalChapters
        )
    }

    public static func readChapterContent(
        at url: URL,
        bookId: String,
        chapter: ChapterItem,
        contentKind: ContentKind
    ) throws -> ChapterContent {
        let reader = try ArchiveReader(url: url)
        guard let relPath = extractRelativePath(fromLocalEPUBURL: chapter.url) else {
            throw LocalLibraryError.invalidEPUB("无效的本地章节地址：\(chapter.url)")
        }

        let xhtmlData = try reader.readData(relativePath: relPath)
        let html = decodeTextData(xhtmlData)
        let chapterDir = parentDirectory(of: relPath)
        let extracted = parseXHTMLToTokens(html: html, chapterDir: chapterDir, bookId: bookId)

        let effectiveKind: ContentKind
        if contentKind == .manga {
            effectiveKind = .manga
        } else {
            let textChars = extracted.tokens.reduce(0) { acc, token in
                if case .paragraph(let p) = token { return acc + p.count }
                return acc
            }
            effectiveKind = (extracted.imageURLs.count >= 4 && textChars < 40) ? .manga : .lightNovel
        }

        return ChapterContent(
            chapter: chapter,
            tokens: extracted.tokens,
            imageURLs: extracted.imageURLs,
            contentKind: effectiveKind
        )
    }

    public static func readImageData(at url: URL, relativePath: String) throws -> DownloadedImageAsset {
        let reader = try ArchiveReader(url: url)
        let data = try reader.readData(relativePath: relativePath)
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        let mime: String
        let normalizedExt: String
        switch ext {
        case "png":
            mime = "image/png"
            normalizedExt = "png"
        case "webp":
            mime = "image/webp"
            normalizedExt = "webp"
        case "gif":
            mime = "image/gif"
            normalizedExt = "gif"
        case "svg":
            mime = "image/svg+xml"
            normalizedExt = "svg"
        default:
            mime = "image/jpeg"
            normalizedExt = "jpg"
        }
        return DownloadedImageAsset(
            url: relativePath,
            data: data,
            fileExtension: normalizedExt,
            mimeType: mime,
            width: 0,
            height: 0
        )
    }

    public static func makeLocalEPUBURL(bookId: String, relativePath: String) -> String {
        let cleaned = normalizeArchivePath(relativePath)
        let encoded = cleaned
            .split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return "local-epub://\(bookId)/\(encoded)"
    }

    public static func extractRelativePath(fromLocalEPUBURL rawURL: String) -> String? {
        guard rawURL.hasPrefix("local-epub://") else { return nil }
        let body = String(rawURL.dropFirst("local-epub://".count))
        guard let slash = body.firstIndex(of: "/") else { return nil }
        var pathPart = String(body[body.index(after: slash)...])
        if let hash = pathPart.firstIndex(of: "#") {
            pathPart = String(pathPart[..<hash])
        }
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        return normalizeArchivePath(decoded)
    }

    public static func extractBookId(fromLocalEPUBURL rawURL: String) -> String? {
        guard rawURL.hasPrefix("local-epub://") else { return nil }
        let body = String(rawURL.dropFirst("local-epub://".count))
        guard let slash = body.firstIndex(of: "/") else { return nil }
        return String(body[..<slash])
    }

    // MARK: - Path Utilities

    static func normalizeArchivePath(_ raw: String) -> String {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        let noFragment = trimmed.components(separatedBy: "#").first ?? trimmed
        let decoded = noFragment.removingPercentEncoding ?? noFragment
        var stack: [String] = []
        for segment in decoded.split(separator: "/") {
            let s = String(segment)
            if s.isEmpty || s == "." { continue }
            if s == ".." {
                if !stack.isEmpty { stack.removeLast() }
            } else {
                stack.append(s)
            }
        }
        return stack.joined(separator: "/")
    }

    static func parentDirectory(of archivePath: String) -> String {
        let parts = archivePath.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    static func resolveRelativePath(_ href: String, relativeTo baseDir: String) -> String {
        let noFrag = href.components(separatedBy: "#").first ?? href
        let decoded = noFrag.removingPercentEncoding ?? noFrag
        if decoded.hasPrefix("/") {
            return normalizeArchivePath(decoded)
        }
        if baseDir.isEmpty {
            return normalizeArchivePath(decoded)
        }
        return normalizeArchivePath("\(baseDir)/\(decoded)")
    }

    // MARK: - XML Parsers (container.xml, OPF, NAV, NCX)

    private static func parseContainerXML(_ data: Data) -> String? {
        final class Delegate: NSObject, XMLParserDelegate {
            var fullPath: String?
            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                let local = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
                if local == "rootfile", let fp = attributeDict["full-path"], !fp.isEmpty, fullPath == nil {
                    fullPath = fp
                }
            }
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.fullPath
    }

    private struct OPFManifestItem {
        let id: String
        let href: String
        let resolvedPath: String
        let mediaType: String
        let properties: String
    }

    private struct ParsedOPF {
        var title: String = ""
        var author: String = ""
        var publisher: String = ""
        var summary: String = ""
        var subjects: [String] = []
        var coverMetaId: String? = nil
        var isPrePaginated: Bool = false
        var spineTocId: String? = nil
        var manifestById: [String: OPFManifestItem] = [:]
        var manifestOrder: [OPFManifestItem] = []
        var spineItemIds: [String] = []

        var navManifestItem: OPFManifestItem? {
            manifestOrder.first { $0.properties.split(separator: " ").contains("nav") }
        }

        var ncxManifestItem: OPFManifestItem? {
            if let tocId = spineTocId, let item = manifestById[tocId] {
                return item
            }
            return manifestOrder.first {
                $0.mediaType.lowercased().contains("dtbncx") || $0.href.lowercased().hasSuffix(".ncx")
            }
        }
    }

    private static func parseOPF(_ data: Data, opfDir: String) -> ParsedOPF {
        final class Delegate: NSObject, XMLParserDelegate {
            let opfDir: String
            var result = ParsedOPF()
            var currentElement: String = ""
            var currentProperty: String = ""
            var buffer: String = ""

            init(opfDir: String) {
                self.opfDir = opfDir
            }

            private func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                let local = localName(elementName)
                currentElement = local
                currentProperty = (attributeDict["property"] ?? "").lowercased()
                buffer = ""

                switch local {
                case "meta":
                    if (attributeDict["name"] ?? "").lowercased() == "cover",
                       let content = attributeDict["content"], !content.isEmpty {
                        result.coverMetaId = content
                    }
                case "item":
                    guard let id = attributeDict["id"], let href = attributeDict["href"], !href.isEmpty else { return }
                    let resolved = LocalEPUBParser.resolveRelativePath(href, relativeTo: opfDir)
                    let item = OPFManifestItem(
                        id: id,
                        href: href,
                        resolvedPath: resolved,
                        mediaType: (attributeDict["media-type"] ?? "").lowercased(),
                        properties: (attributeDict["properties"] ?? "").lowercased()
                    )
                    result.manifestById[id] = item
                    result.manifestOrder.append(item)
                case "spine":
                    if let toc = attributeDict["toc"], !toc.isEmpty {
                        result.spineTocId = toc
                    }
                case "itemref":
                    if let idref = attributeDict["idref"], !idref.isEmpty {
                        result.spineItemIds.append(idref)
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                buffer.append(string)
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                let local = localName(elementName)
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    switch local {
                    case "title":
                        if result.title.isEmpty { result.title = text }
                    case "creator":
                        if result.author.isEmpty { result.author = text }
                    case "publisher":
                        if result.publisher.isEmpty { result.publisher = text }
                    case "description":
                        if result.summary.isEmpty {
                            result.summary = LocalEPUBParser.stripHTMLTags(text)
                        }
                    case "subject":
                        if !result.subjects.contains(text) {
                            result.subjects.append(text)
                        }
                    case "meta":
                        if currentProperty == "rendition:layout" && text.lowercased() == "pre-paginated" {
                            result.isPrePaginated = true
                        }
                    default:
                        break
                    }
                }
                currentElement = ""
                currentProperty = ""
                buffer = ""
            }
        }

        let delegate = Delegate(opfDir: opfDir)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    private struct TOCNode {
        var title: String
        var href: String
        var children: [TOCNode]
    }

    private static func parseNCX(_ data: Data, ncxDir: String, bookId: String) -> [VolumeItem] {
        final class Delegate: NSObject, XMLParserDelegate {
            var rootNodes: [TOCNode] = []
            var stack: [TOCNode] = []
            var inNavLabel = false
            var inText = false
            var textBuffer = ""

            private func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                let local = localName(elementName)
                switch local {
                case "navpoint":
                    stack.append(TOCNode(title: "", href: "", children: []))
                case "navlabel":
                    inNavLabel = true
                case "text":
                    if inNavLabel {
                        inText = true
                        textBuffer = ""
                    }
                case "content":
                    if !stack.isEmpty, let src = attributeDict["src"], !src.isEmpty {
                        stack[stack.count - 1].href = src
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inText { textBuffer.append(string) }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                let local = localName(elementName)
                switch local {
                case "text":
                    if inText && !stack.isEmpty {
                        let cleaned = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty && stack[stack.count - 1].title.isEmpty {
                            stack[stack.count - 1].title = cleaned
                        }
                    }
                    inText = false
                    textBuffer = ""
                case "navlabel":
                    inNavLabel = false
                case "navpoint":
                    guard let finished = stack.popLast() else { return }
                    if stack.isEmpty {
                        rootNodes.append(finished)
                    } else {
                        stack[stack.count - 1].children.append(finished)
                    }
                default:
                    break
                }
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return convertTOCNodesToVolumes(delegate.rootNodes, baseDir: ncxDir, bookId: bookId)
    }

    private static func parseNavXHTML(_ data: Data, navDir: String, bookId: String) -> [VolumeItem] {
        final class Delegate: NSObject, XMLParserDelegate {
            var rootNodes: [TOCNode] = []
            var inTOCNav = false
            var navDepth = 0
            var liStack: [TOCNode] = []
            var capturingAnchor = false
            var anchorText = ""

            private func localName(_ name: String) -> String {
                name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
            }

            func parser(
                _ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]
            ) {
                let local = localName(elementName)
                if local == "nav" {
                    let epubType = (attributeDict["epub:type"] ?? attributeDict["type"] ?? "").lowercased()
                    let role = (attributeDict["role"] ?? "").lowercased()
                    if !inTOCNav && (epubType.contains("toc") || role == "doc-toc" || rootNodes.isEmpty) {
                        inTOCNav = true
                        navDepth = 1
                    } else if inTOCNav {
                        navDepth += 1
                    }
                    return
                }
                guard inTOCNav else { return }
                switch local {
                case "li":
                    liStack.append(TOCNode(title: "", href: "", children: []))
                case "a", "span":
                    if !liStack.isEmpty && liStack[liStack.count - 1].title.isEmpty {
                        capturingAnchor = true
                        anchorText = ""
                        if local == "a", let href = attributeDict["href"], !href.isEmpty {
                            liStack[liStack.count - 1].href = href
                        }
                    }
                default:
                    break
                }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if capturingAnchor { anchorText.append(string) }
            }

            func parser(
                _ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?
            ) {
                let local = localName(elementName)
                if local == "nav" && inTOCNav {
                    navDepth -= 1
                    if navDepth <= 0 { inTOCNav = false }
                    return
                }
                guard inTOCNav else { return }
                switch local {
                case "a", "span":
                    if capturingAnchor && !liStack.isEmpty {
                        let cleaned = anchorText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cleaned.isEmpty {
                            liStack[liStack.count - 1].title = cleaned
                        }
                        capturingAnchor = false
                        anchorText = ""
                    }
                case "li":
                    guard let finished = liStack.popLast() else { return }
                    if liStack.isEmpty {
                        rootNodes.append(finished)
                    } else {
                        liStack[liStack.count - 1].children.append(finished)
                    }
                default:
                    break
                }
            }
        }

        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return convertTOCNodesToVolumes(delegate.rootNodes, baseDir: navDir, bookId: bookId)
    }

    private static func convertTOCNodesToVolumes(_ nodes: [TOCNode], baseDir: String, bookId: String) -> [VolumeItem] {
        guard !nodes.isEmpty else { return [] }
        let hasNestedGroups = nodes.contains { !$0.children.isEmpty }
        var volumes: [VolumeItem] = []

        if hasNestedGroups {
            var volIdx = 1
            for node in nodes {
                let flattened = flattenTOCLeaves(node.children.isEmpty ? [node] : node.children)
                var chapters: [ChapterItem] = []
                for (cIdx, leaf) in flattened.enumerated() {
                    guard !leaf.href.isEmpty else { continue }
                    let resolved = resolveRelativePath(leaf.href, relativeTo: baseDir)
                    let chapTitle = leaf.title.isEmpty ? "第 \(cIdx + 1) 章" : leaf.title
                    let isIllus = chapTitle.contains("插图") || chapTitle.contains("彩插") || chapTitle.lowercased().contains("illustration")
                    chapters.append(
                        ChapterItem(
                            id: "\(bookId)_v\(volIdx)_c\(cIdx + 1)",
                            sourceId: LocalLibraryPlugin.sourceId,
                            title: chapTitle,
                            url: makeLocalEPUBURL(bookId: bookId, relativePath: resolved),
                            volumeIndex: volIdx,
                            chapterIndex: cIdx + 1,
                            isIllustrationChapter: isIllus
                        )
                    )
                }
                if !chapters.isEmpty {
                    let vTitle = node.title.isEmpty ? "第 \(volIdx) 卷" : node.title
                    volumes.append(VolumeItem(id: "\(bookId)_vol_\(volIdx)", index: volIdx, title: vTitle, chapters: chapters))
                    volIdx += 1
                }
            }
        } else {
            var chapters: [ChapterItem] = []
            for (idx, node) in nodes.enumerated() {
                guard !node.href.isEmpty else { continue }
                let resolved = resolveRelativePath(node.href, relativeTo: baseDir)
                let chapTitle = node.title.isEmpty ? "第 \(idx + 1) 章" : node.title
                let isIllus = chapTitle.contains("插图") || chapTitle.contains("彩插") || chapTitle.lowercased().contains("illustration")
                chapters.append(
                    ChapterItem(
                        id: "\(bookId)_v1_c\(idx + 1)",
                        sourceId: LocalLibraryPlugin.sourceId,
                        title: chapTitle,
                        url: makeLocalEPUBURL(bookId: bookId, relativePath: resolved),
                        volumeIndex: 1,
                        chapterIndex: idx + 1,
                        isIllustrationChapter: isIllus
                    )
                )
            }
            if !chapters.isEmpty {
                volumes.append(VolumeItem(id: "\(bookId)_vol_1", index: 1, title: "全书目录", chapters: chapters))
            }
        }
        return volumes
    }

    private static func flattenTOCLeaves(_ nodes: [TOCNode]) -> [TOCNode] {
        var result: [TOCNode] = []
        for node in nodes {
            if !node.href.isEmpty {
                result.append(TOCNode(title: node.title, href: node.href, children: []))
            }
            if !node.children.isEmpty {
                result.append(contentsOf: flattenTOCLeaves(node.children))
            }
        }
        return result
    }

    private static func buildSpineFallbackVolumes(opf: ParsedOPF, reader: ArchiveReader, bookId: String) -> [VolumeItem] {
        var chapters: [ChapterItem] = []
        var idx = 1
        for idref in opf.spineItemIds {
            guard let item = opf.manifestById[idref] else { continue }
            var title = URL(fileURLWithPath: item.resolvedPath).deletingPathExtension().lastPathComponent
            if let raw = try? reader.readData(relativePath: item.resolvedPath) {
                let html = decodeTextData(raw)
                if let extracted = extractFirstHeadingOrTitle(from: html), !extracted.isEmpty {
                    title = extracted
                }
            }
            chapters.append(
                ChapterItem(
                    id: "\(bookId)_v1_c\(idx)",
                    sourceId: LocalLibraryPlugin.sourceId,
                    title: title.isEmpty ? "第 \(idx) 章" : title,
                    url: makeLocalEPUBURL(bookId: bookId, relativePath: item.resolvedPath),
                    volumeIndex: 1,
                    chapterIndex: idx,
                    isIllustrationChapter: title.contains("插图") || title.contains("彩插")
                )
            )
            idx += 1
        }
        guard !chapters.isEmpty else { return [] }
        return [VolumeItem(id: "\(bookId)_vol_1", index: 1, title: "正文目录", chapters: chapters)]
    }

    private static func resolveCoverPath(opf: ParsedOPF, reader: ArchiveReader) -> String? {
        if let item = opf.manifestOrder.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
            return item.resolvedPath
        }
        if let coverId = opf.coverMetaId, let item = opf.manifestById[coverId], item.mediaType.hasPrefix("image/") {
            return item.resolvedPath
        }
        if let item = opf.manifestOrder.first(where: {
            $0.mediaType.hasPrefix("image/") &&
            ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
        }) {
            return item.resolvedPath
        }
        // Inspect first spine document for a cover image
        if let firstId = opf.spineItemIds.first,
           let firstDoc = opf.manifestById[firstId],
           let raw = try? reader.readData(relativePath: firstDoc.resolvedPath) {
            let html = decodeTextData(raw)
            let dir = parentDirectory(of: firstDoc.resolvedPath)
            if let firstImg = extractImageSources(from: html).first {
                return resolveRelativePath(firstImg, relativeTo: dir)
            }
        }
        return opf.manifestOrder.first(where: { $0.mediaType.hasPrefix("image/") })?.resolvedPath
    }

    private static func detectContentKind(opf: ParsedOPF, volumes: [VolumeItem], reader: ArchiveReader) -> ContentKind {
        if opf.isPrePaginated {
            return .manga
        }
        let sampleChapters = volumes.flatMap(\.chapters).prefix(5)
        guard !sampleChapters.isEmpty else { return .lightNovel }
        var imageOnlyCount = 0
        var checked = 0
        for chap in sampleChapters {
            guard let rel = extractRelativePath(fromLocalEPUBURL: chap.url),
                  let data = try? reader.readData(relativePath: rel) else { continue }
            checked += 1
            let html = decodeTextData(data)
            let imgs = extractImageSources(from: html)
            let textLen = stripHTMLTags(extractBody(from: html)).count
            if !imgs.isEmpty && textLen < 30 {
                imageOnlyCount += 1
            }
        }
        if checked >= 3 && Double(imageOnlyCount) / Double(checked) >= 0.8 {
            return .manga
        }
        return .lightNovel
    }

    // MARK: - XHTML Content Extraction

    private static func parseXHTMLToTokens(
        html: String,
        chapterDir: String,
        bookId: String
    ) -> (tokens: [ChapterToken], imageURLs: [String]) {
        var body = extractBody(from: html)
        // Strip script/style/head blocks
        body = body.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)

        // Replace <img> and SVG <image> tags with unique markers so reading order is preserved
        var markerToImageURL: [String: String] = [:]
        var imageURLs: [String] = []
        var markerIndex = 0

        let imgPattern = #"(?is)<(?:img|image)\b[^>]*(?:src|xlink:href|href)\s*=\s*["']([^"']+)["'][^>]*>"#
        if let regex = try? NSRegularExpression(pattern: imgPattern) {
            let ns = body as NSString
            let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                var rebuilt = ""
                var cursor = 0
                for match in matches {
                    let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
                    rebuilt += ns.substring(with: prefixRange)
                    let rawSrc = ns.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rawSrc.isEmpty && !rawSrc.lowercased().hasPrefix("data:") && !rawSrc.lowercased().hasPrefix("http") {
                        let resolved = resolveRelativePath(rawSrc, relativeTo: chapterDir)
                        let localURL = makeLocalEPUBURL(bookId: bookId, relativePath: resolved)
                        let marker = "___SHIORI_IMG_\(markerIndex)___"
                        markerIndex += 1
                        markerToImageURL[marker] = localURL
                        if !imageURLs.contains(localURL) {
                            imageURLs.append(localURL)
                        }
                        rebuilt += "\n\(marker)\n"
                    }
                    cursor = match.range.location + match.range.length
                }
                if cursor < ns.length {
                    rebuilt += ns.substring(from: cursor)
                }
                body = rebuilt
            }
        }

        // Convert block-level separators into line breaks
        body = body.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?i)</(p|div|h[1-6]|li|blockquote|section|article|tr|hr)>", with: "\n", options: .regularExpression)
        body = body.replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
        body = decodeHTMLEntities(body)

        var tokens: [ChapterToken] = []
        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let imgURL = markerToImageURL[line] {
                tokens.append(.image(imgURL))
            } else {
                // In case marker appeared inline with text, split cleanly
                if line.contains("___SHIORI_IMG_") {
                    let parts = line.components(separatedBy: " ")
                    var textAcc: [String] = []
                    for part in parts {
                        if let imgURL = markerToImageURL[part] {
                            if !textAcc.isEmpty {
                                tokens.append(.paragraph(textAcc.joined(separator: " ")))
                                textAcc = []
                            }
                            tokens.append(.image(imgURL))
                        } else {
                            textAcc.append(part)
                        }
                    }
                    if !textAcc.isEmpty {
                        tokens.append(.paragraph(textAcc.joined(separator: " ")))
                    }
                } else {
                    tokens.append(.paragraph(line))
                }
            }
        }

        return (tokens, imageURLs)
    }

    private static func extractBody(from html: String) -> String {
        if let regex = try? NSRegularExpression(pattern: "(?is)<body[^>]*>(.*?)</body>"),
           let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
            return (html as NSString).substring(with: match.range(at: 1))
        }
        return html
    }

    private static func extractFirstHeadingOrTitle(from html: String) -> String? {
        for pattern in ["(?is)<h1[^>]*>(.*?)</h1>", "(?is)<h2[^>]*>(.*?)</h2>", "(?is)<title[^>]*>(.*?)</title>"] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) {
                let raw = (html as NSString).substring(with: match.range(at: 1))
                let cleaned = stripHTMLTags(raw)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func extractImageSources(from html: String) -> [String] {
        let pattern = #"(?is)<(?:img|image)\b[^>]*(?:src|xlink:href|href)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let s = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
    }

    private static func decodeTextData(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let gb = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return gb }
        return String(decoding: data, as: UTF8.self)
    }

    static func stripHTMLTags(_ raw: String) -> String {
        let noTags = raw.replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
        return decodeHTMLEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&ldquo;", with: "“")
            .replacingOccurrences(of: "&rdquo;", with: "”")

        // Numeric entities &#1234; and &#x1F600;
        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let codeStr = ns.substring(with: match.range(at: 1))
                let value: UInt32?
                if codeStr.lowercased().hasPrefix("x") {
                    value = UInt32(codeStr.dropFirst(), radix: 16)
                } else {
                    value = UInt32(codeStr, radix: 10)
                }
                if let value, let scalar = UnicodeScalar(value) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }
        return result
    }

    static func saveDownsampledCover(data: Data, to outputURL: URL, maxPixelSize: CGFloat) {
        let dir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let src = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) {
                let bitmap = NSBitmapImageRep(cgImage: cgImg)
                if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
                    try? jpeg.write(to: outputURL, options: .atomic)
                    return
                }
            }
        }
        try? data.write(to: outputURL, options: .atomic)
    }
}
