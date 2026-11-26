import CryptoKit
import Foundation

public struct LocalImportSummary: Sendable {
    public let imported: [LocalBookRecord]
    public let skippedDuplicates: Int
    public let failed: [(path: String, reason: String)]

    public init(
        imported: [LocalBookRecord],
        skippedDuplicates: Int,
        failed: [(path: String, reason: String)]
    ) {
        self.imported = imported
        self.skippedDuplicates = skippedDuplicates
        self.failed = failed
    }
}

/// Reference-only local library index persisted under `~/Library/Application Support/Shiori/LocalLibrary/`.
/// Never copies book files — stores only canonical file paths, parsed metadata, and small cover thumbnails.
public actor LocalLibraryStore {
    public let storageDirectory: URL
    private let indexFileURL: URL
    private let coversDirectory: URL
    private var recordsById: [String: LocalBookRecord] = [:]
    private var orderedIds: [String] = []

    public init(storageDirectory: URL? = nil) {
        let baseDir: URL
        if let storageDirectory {
            baseDir = storageDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            baseDir = appSupport
                .appendingPathComponent("Shiori", isDirectory: true)
                .appendingPathComponent("LocalLibrary", isDirectory: true)
        }
        self.storageDirectory = baseDir
        self.indexFileURL = baseDir.appendingPathComponent("index.json")
        self.coversDirectory = baseDir.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
        let loaded = Self.loadRecordsFromDisk(indexFileURL: indexFileURL)
        for rec in loaded {
            self.recordsById[rec.id] = rec
            self.orderedIds.append(rec.id)
        }
    }

    public func allRecords() -> [LocalBookRecord] {
        orderedIds.compactMap { recordsById[$0] }
    }

    public func record(for id: String) -> LocalBookRecord? {
        recordsById[id]
    }

    public func record(forFilePath path: String) -> LocalBookRecord? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        return recordsById.values.first {
            URL(fileURLWithPath: $0.filePath).standardizedFileURL.path == canonical
        }
    }

    public func importedCanonicalPaths() -> Set<String> {
        Set(recordsById.values.map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path })
    }

    public func fileAvailability(for id: String) -> LocalFileAvailability {
        guard let rec = recordsById[id] else { return .missing }
        return AppleBooksBridge.fileAvailability(at: rec.fileURL)
    }

    /// Expands selected URLs (including folders containing `.epub`/`.pdf`, while treating `.epub/` Apple Books packages as single books).
    public static func expandImportableBookURLs(from urls: [URL]) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func appendIfValid(_ candidate: URL) {
            let canonical = candidate.standardizedFileURL.path
            guard !seen.contains(canonical) else { return }
            seen.insert(canonical)
            results.append(candidate.standardizedFileURL)
        }

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            if LocalBookFormat.detect(from: url) != nil {
                appendIfValid(url)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let child as URL in enumerator {
                if LocalBookFormat.detect(from: child) != nil {
                    appendIfValid(child)
                    // Do not descend into unpacked `.epub/` package directories
                    enumerator.skipDescendants()
                }
            }
        }
        return results
    }

    /// Imports one or more `.epub` / `.pdf` file references, parsing metadata and generating a small cover thumbnail.
    public func importBooks(
        urls: [URL],
        origin: LocalBookOrigin,
        downloadICloudIfNeeded: Bool = true,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> LocalImportSummary {
        let expanded = Self.expandImportableBookURLs(from: urls)
        var imported: [LocalBookRecord] = []
        var skipped = 0
        var failed: [(String, String)] = []

        for url in expanded {
            let canonical = url.standardizedFileURL.path
            if let existing = record(forFilePath: canonical) {
                skipped += 1
                // Ensure cover exists if it was somehow removed
                if existing.coverCachePath.isEmpty || !FileManager.default.fileExists(atPath: existing.coverCachePath) {
                    if let refreshed = try? parseAndBuildRecord(url: url, id: existing.id, origin: existing.origin, existingAddedAt: existing.addedAt) {
                        recordsById[refreshed.id] = refreshed
                        persistIndex()
                    }
                }
                continue
            }

            let displayName = url.deletingPathExtension().lastPathComponent
            let availability = AppleBooksBridge.fileAvailability(at: url)
            if availability == .missing {
                failed.append((canonical, LocalLibraryError.fileMissing(bookId: "", filePath: canonical).localizedDescription))
                continue
            }
            if availability == .iCloudNotDownloaded {
                if downloadICloudIfNeeded {
                    onProgress?("正在从 iCloud 下载《\(displayName)》…")
                    do {
                        try await AppleBooksBridge.ensureICloudItemDownloaded(at: url)
                    } catch {
                        failed.append((canonical, error.localizedDescription))
                        continue
                    }
                } else {
                    failed.append((canonical, LocalLibraryError.iCloudDownloadRequired(bookId: "", filePath: canonical).localizedDescription))
                    continue
                }
            }

            onProgress?("正在解析《\(displayName)》…")
            let bookId = Self.makeStableBookId(forCanonicalPath: canonical)
            do {
                let rec = try parseAndBuildRecord(url: url, id: bookId, origin: origin, existingAddedAt: Date())
                recordsById[rec.id] = rec
                if !orderedIds.contains(rec.id) {
                    orderedIds.insert(rec.id, at: 0)
                }
                imported.append(rec)
            } catch {
                failed.append((canonical, error.localizedDescription))
            }
        }

        if !imported.isEmpty {
            persistIndex()
        }
        return LocalImportSummary(imported: imported, skippedDuplicates: skipped, failed: failed)
    }

    /// Relinks a missing local book record to a newly chosen file URL while preserving its `bookId` and reading progress.
    public func relinkBook(id: String, newURL: URL) throws -> LocalBookRecord {
        guard let existing = recordsById[id] else {
            throw SourceError.notFound("未找到本地书籍记录：\(id)")
        }
        let canonical = newURL.standardizedFileURL
        guard let fmt = LocalBookFormat.detect(from: canonical), fmt == existing.format else {
            throw LocalLibraryError.unsupportedFormat("请选择与原书相同格式（\(existing.format.displayBadge)）的文件")
        }
        let updated = try parseAndBuildRecord(
            url: canonical,
            id: existing.id,
            origin: existing.origin,
            existingAddedAt: existing.addedAt
        )
        recordsById[id] = updated
        persistIndex()
        return updated
    }

    public func markOpened(id: String) {
        guard var rec = recordsById[id] else { return }
        rec.lastOpenedAt = Date()
        recordsById[id] = rec
        persistIndex()
    }

    public func removeBook(id: String) {
        if let rec = recordsById.removeValue(forKey: id) {
            if !rec.coverCachePath.isEmpty {
                try? FileManager.default.removeItem(atPath: rec.coverCachePath)
            }
        }
        orderedIds.removeAll { $0 == id }
        persistIndex()
    }

    // MARK: - Helpers

    private func parseAndBuildRecord(
        url: URL,
        id: String,
        origin: LocalBookOrigin,
        existingAddedAt: Date
    ) throws -> LocalBookRecord {
        guard let format = LocalBookFormat.detect(from: url) else {
            throw LocalLibraryError.unsupportedFormat(url.lastPathComponent)
        }
        let coverOutput = coversDirectory.appendingPathComponent("\(id).jpg")
        let sizeBytes = Self.computeItemSize(at: url)

        switch format {
        case .epub:
            let parsed = try LocalEPUBParser.parseBook(at: url, bookId: id, coverCacheOutputURL: coverOutput)
            let coverPath = FileManager.default.fileExists(atPath: coverOutput.path) ? coverOutput.path : ""
            return LocalBookRecord(
                id: id,
                format: .epub,
                origin: origin,
                filePath: url.standardizedFileURL.path,
                title: parsed.title,
                author: parsed.author,
                publisher: parsed.publisher,
                summary: parsed.summary,
                tags: parsed.tags,
                coverCachePath: coverPath,
                contentKind: parsed.contentKind,
                pageCount: 0,
                chapterCount: parsed.totalChapters,
                fileSizeBytes: sizeBytes,
                addedAt: existingAddedAt
            )

        case .pdf:
            let parsed = try LocalPDFParser.parseBook(at: url, bookId: id, coverCacheOutputURL: coverOutput)
            let coverPath = FileManager.default.fileExists(atPath: coverOutput.path) ? coverOutput.path : ""
            return LocalBookRecord(
                id: id,
                format: .pdf,
                origin: origin,
                filePath: url.standardizedFileURL.path,
                title: parsed.title,
                author: parsed.author,
                publisher: parsed.publisher,
                summary: parsed.summary,
                tags: parsed.tags,
                coverCachePath: coverPath,
                contentKind: .lightNovel,
                pageCount: parsed.pageCount,
                chapterCount: parsed.volumes.reduce(0) { $0 + $1.chapters.count },
                fileSizeBytes: sizeBytes,
                addedAt: existingAddedAt
            )
        }
    }

    private func persistIndex() {
        let ordered = allRecords()
        if let data = try? JSONEncoder().encode(ordered) {
            try? SecureStateFileWriter.write(data, to: indexFileURL)
        }
    }

    private static func loadRecordsFromDisk(indexFileURL: URL) -> [LocalBookRecord] {
        guard let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([LocalBookRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func makeStableBookId(forCanonicalPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "loc_\(hex)"
    }

    private static func computeItemSize(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
