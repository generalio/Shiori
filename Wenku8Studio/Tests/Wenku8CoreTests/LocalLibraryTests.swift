import AppKit
import PDFKit
import XCTest
@testable import Wenku8Core

final class LocalLibraryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShioriLocalLibTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Helpers

    private func makeMinimalPNGData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 48,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 48).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func createUnpackedEPUBPackage(named name: String) throws -> URL {
        let pkg = tempRoot.appendingPathComponent(name, isDirectory: true)
        let metaInf = pkg.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = pkg.appendingPathComponent("OEBPS", isDirectory: true)
        let textDir = oebps.appendingPathComponent("Text", isDirectory: true)
        let imgDir = oebps.appendingPathComponent("Images", isDirectory: true)

        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: pkg.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)

        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try containerXML.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)

        let pngData = makeMinimalPNGData()
        try pngData.write(to: imgDir.appendingPathComponent("cover.png"))
        try pngData.write(to: imgDir.appendingPathComponent("illus1.png"))

        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>栞之本地测试轻小说</dc:title>
            <dc:creator>测试作者</dc:creator>
            <dc:publisher>Shiori Press</dc:publisher>
            <dc:description>用于验证解包目录型与压缩包型 EPUB 解析。</dc:description>
            <dc:subject>校园</dc:subject>
            <dc:subject>恋爱</dc:subject>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="cover-img" href="Images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="img1" href="Images/illus1.png" media-type="image/png"/>
            <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """
        try opfXML.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)

        let navXHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="toc">
            <ol>
              <li>
                <span>第一卷 序幕</span>
                <ol>
                  <li><a href="Text/ch1.xhtml">第一章 初遇</a></li>
                  <li><a href="Text/ch2.xhtml">第二章 重逢</a></li>
                </ol>
              </li>
            </ol>
          </nav>
        </body>
        </html>
        """
        try navXHTML.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)

        let ch1XHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <h1>第一章 初遇</h1>
          <p>这是第一段正文内容 &amp; 实体测试。</p>
          <div><img src="../Images/illus1.png" alt="插图"/></div>
          <p>这是插图后的第二段。</p>
        </body>
        </html>
        """
        try ch1XHTML.write(to: textDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)

        let ch2XHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <body>
          <p>第二章正文。</p>
        </body>
        </html>
        """
        try ch2XHTML.write(to: textDir.appendingPathComponent("ch2.xhtml"), atomically: true, encoding: .utf8)

        return pkg
    }

    private func zipDirectory(_ dirURL: URL, to outputURL: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = dirURL
        proc.arguments = ["-q", "-r", outputURL.path, "."]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    private func createSamplePDF(named name: String, pageCount: Int = 3) throws -> URL {
        let pdfURL = tempRoot.appendingPathComponent(name)
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 595)
        let auxInfo: [CFString: Any] = [
            kCGPDFContextTitle: "本地测试 PDF 指南",
            kCGPDFContextAuthor: "Shiori PDF 作者",
            kCGPDFContextSubject: "用于测试 PDFKit 解析与封面渲染",
        ]
        guard let ctx = CGContext(pdfURL as CFURL, mediaBox: &mediaBox, auxInfo as CFDictionary) else {
            XCTFail("Failed to create CGContext PDF")
            return pdfURL
        }
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)
            ctx.setFillColor(NSColor.systemBlue.cgColor)
            ctx.fill(CGRect(x: 40, y: 460 - CGFloat(i * 40), width: 180, height: 40))
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return pdfURL
    }

    // MARK: - Tests

    func testUnpackedAppleBooksEPUBParsingAndImageExtraction() throws {
        let pkgURL = try createUnpackedEPUBPackage(named: "AppleBooksUnpacked.epub")
        let coverOut = tempRoot.appendingPathComponent("cover_unpacked.jpg")

        let parsed = try LocalEPUBParser.parseBook(at: pkgURL, bookId: "loc_unpacked", coverCacheOutputURL: coverOut)
        XCTAssertEqual(parsed.title, "栞之本地测试轻小说")
        XCTAssertEqual(parsed.author, "测试作者")
        XCTAssertEqual(parsed.publisher, "Shiori Press")
        XCTAssertEqual(parsed.tags, ["校园", "恋爱"])
        XCTAssertEqual(parsed.volumes.count, 1)
        XCTAssertEqual(parsed.volumes[0].title, "第一卷 序幕")
        XCTAssertEqual(parsed.volumes[0].chapters.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverOut.path))

        let ch1 = parsed.volumes[0].chapters[0]
        let content = try LocalEPUBParser.readChapterContent(
            at: pkgURL,
            bookId: "loc_unpacked",
            chapter: ch1,
            contentKind: parsed.contentKind
        )
        XCTAssertEqual(content.imageURLs.count, 1)
        XCTAssertTrue(content.tokens.contains(.paragraph("这是第一段正文内容 & 实体测试。")))
        XCTAssertTrue(content.tokens.contains(.paragraph("这是插图后的第二段。")))
        XCTAssertTrue(content.tokens.contains(.image("local-epub://loc_unpacked/OEBPS/Images/illus1.png")))

        let relPath = try XCTUnwrap(LocalEPUBParser.extractRelativePath(fromLocalEPUBURL: content.imageURLs[0]))
        let imgAsset = try LocalEPUBParser.readImageData(at: pkgURL, relativePath: relPath)
        XCTAssertEqual(imgAsset.mimeType, "image/png")
        XCTAssertFalse(imgAsset.data.isEmpty)
    }

    func testZippedEPUBParsingAndImageExtraction() throws {
        let pkgURL = try createUnpackedEPUBPackage(named: "SourceUnpacked.epub")
        let zipEPUB = tempRoot.appendingPathComponent("ZippedNovel.epub")
        try zipDirectory(pkgURL, to: zipEPUB)

        let coverOut = tempRoot.appendingPathComponent("cover_zipped.jpg")
        let parsed = try LocalEPUBParser.parseBook(at: zipEPUB, bookId: "loc_zipped", coverCacheOutputURL: coverOut)
        XCTAssertEqual(parsed.title, "栞之本地测试轻小说")
        XCTAssertEqual(parsed.volumes[0].chapters.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverOut.path))

        let ch1 = parsed.volumes[0].chapters[0]
        let content = try LocalEPUBParser.readChapterContent(
            at: zipEPUB,
            bookId: "loc_zipped",
            chapter: ch1,
            contentKind: parsed.contentKind
        )
        XCTAssertEqual(content.imageURLs.count, 1)
        let rel = try XCTUnwrap(LocalEPUBParser.extractRelativePath(fromLocalEPUBURL: content.imageURLs[0]))
        let asset = try LocalEPUBParser.readImageData(at: zipEPUB, relativePath: rel)
        XCTAssertFalse(asset.data.isEmpty)
    }

    func testPDFParsingAndCoverGeneration() throws {
        let pdfURL = try createSamplePDF(named: "SampleGuide.pdf", pageCount: 3)
        let coverOut = tempRoot.appendingPathComponent("cover_pdf.jpg")

        let parsed = try LocalPDFParser.parseBook(at: pdfURL, bookId: "loc_pdf", coverCacheOutputURL: coverOut)
        XCTAssertEqual(parsed.title, "本地测试 PDF 指南")
        XCTAssertEqual(parsed.author, "Shiori PDF 作者")
        XCTAssertEqual(parsed.pageCount, 3)
        XCTAssertEqual(parsed.volumes.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverOut.path))

        let chapterURL = try XCTUnwrap(parsed.volumes.first?.chapters.first?.url)
        let decoded = try XCTUnwrap(LocalPDFParser.parseLocalPDFURL(chapterURL))
        XCTAssertEqual(decoded.bookId, "loc_pdf")
        XCTAssertEqual(decoded.pageIndex, 0)
    }

    func testLocalLibraryStoreReferenceOnlyLifecycleAndPluginSearch() async throws {
        let storeDir = tempRoot.appendingPathComponent("StoreIndex", isDirectory: true)
        let store = LocalLibraryStore(storageDirectory: storeDir)
        let plugin = LocalLibraryPlugin(store: store)

        let epubDir = try createUnpackedEPUBPackage(named: "UnpackedBook.epub")
        let pdfFile = try createSamplePDF(named: "ReferenceBook.pdf", pageCount: 2)

        // Import once
        let firstImport = await store.importBooks(urls: [epubDir, pdfFile], origin: .localFile)
        XCTAssertEqual(firstImport.imported.count, 2)
        XCTAssertEqual(firstImport.skippedDuplicates, 0)
        XCTAssertTrue(firstImport.failed.isEmpty)

        // Verify reference-only: original files are NOT copied into StoreIndex
        let storeContents = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
        XCTAssertFalse(storeContents.contains("ReferenceBook.pdf"))
        XCTAssertFalse(storeContents.contains("UnpackedBook.epub"))

        // Duplicate import should skip
        let secondImport = await store.importBooks(urls: [pdfFile], origin: .localFile)
        XCTAssertEqual(secondImport.imported.count, 0)
        XCTAssertEqual(secondImport.skippedDuplicates, 1)

        // Plugin search & detail fetch
        let searchRes = try await plugin.search(query: "PDF 指南", scope: .articleName, page: 1)
        XCTAssertEqual(searchRes.items.count, 1)
        let pdfId = searchRes.items[0].id
        let detail = try await plugin.fetchBookDetail(bookIdOrURL: pdfId, onProgress: nil)
        XCTAssertEqual(detail.sourceId, LocalLibraryPlugin.sourceId)
        XCTAssertEqual(detail.title, "本地测试 PDF 指南")

        // Relink to a moved PDF file while keeping same bookId
        let movedPDF = tempRoot.appendingPathComponent("MovedReferenceBook.pdf")
        try FileManager.default.moveItem(at: pdfFile, to: movedPDF)
        let relinked = try await store.relinkBook(id: pdfId, newURL: movedPDF)
        XCTAssertEqual(relinked.id, pdfId)
        XCTAssertEqual(relinked.filePath, movedPDF.standardizedFileURL.path)

        // Removing from store must NOT delete original file on disk
        await store.removeBook(id: pdfId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedPDF.path))
        let remaining = await store.allRecords()
        XCTAssertEqual(remaining.count, 1)
    }

    func testAppleBooksBridgeScanDetectsEPUBAndPDFOnly() throws {
        let mockICloud = tempRoot.appendingPathComponent("MockICloudBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: mockICloud, withIntermediateDirectories: true)

        let epubPkg = try createUnpackedEPUBPackage(named: "MockBook.epub")
        let movedEPUB = mockICloud.appendingPathComponent("MockBook.epub")
        try FileManager.default.moveItem(at: epubPkg, to: movedEPUB)

        let pdf = try createSamplePDF(named: "MockDoc.pdf", pageCount: 1)
        let movedPDF = mockICloud.appendingPathComponent("MockDoc.pdf")
        try FileManager.default.moveItem(at: pdf, to: movedPDF)

        try "ignore me".write(to: mockICloud.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let candidates = AppleBooksBridge.scanICloudBooks(
            directory: mockICloud,
            importedCanonicalPaths: [movedEPUB.standardizedFileURL.path]
        )
        XCTAssertEqual(candidates.count, 2)
        let epubCand = try XCTUnwrap(candidates.first { $0.format == .epub })
        let pdfCand = try XCTUnwrap(candidates.first { $0.format == .pdf })
        XCTAssertTrue(epubCand.isPackageDirectory)
        XCTAssertTrue(epubCand.isDownloadedLocally)
        XCTAssertTrue(epubCand.isAlreadyImported)
        XCTAssertFalse(pdfCand.isAlreadyImported)
    }
}
