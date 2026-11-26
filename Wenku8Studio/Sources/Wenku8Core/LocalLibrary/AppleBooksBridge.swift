import AppKit
import Foundation

/// Provides independent, one-way-at-a-time Apple Books interoperability:
/// 1. Direction A (Apple Books -> Shiori): non-destructive scan of Apple Books iCloud Drive
///    directory with dataless status inspection and on-demand iCloud download trigger.
/// 2. Direction B (Shiori -> Apple Books): send any local `.epub` or `.pdf` file to `/System/Applications/Books.app`.
public enum AppleBooksBridge {
    public static let booksAppURL = URL(fileURLWithPath: "/System/Applications/Books.app")

    public static var isAppleBooksInstalled: Bool {
        FileManager.default.fileExists(atPath: booksAppURL.path)
    }

    public static var defaultICloudBooksDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents", isDirectory: true)
    }

    /// Scans the Apple Books iCloud Drive directory without triggering mass cloud downloads.
    public static func scanICloudBooks(
        directory: URL = defaultICloudBooksDirectory,
        importedCanonicalPaths: Set<String> = []
    ) -> [AppleBooksCandidate] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [AppleBooksCandidate] = []
        for url in entries {
            guard let format = LocalBookFormat.detect(from: url) else { continue }
            let canonical = url.standardizedFileURL.path
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let downloaded = isFileDownloadedLocally(url: url, resourceValues: values)
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate
            let displayName = url.deletingPathExtension().lastPathComponent

            results.append(
                AppleBooksCandidate(
                    filePath: canonical,
                    displayName: displayName,
                    format: format,
                    isPackageDirectory: isDir,
                    isDownloadedLocally: downloaded,
                    fileSizeBytes: size,
                    modifiedAt: modified,
                    isAlreadyImported: importedCanonicalPaths.contains(canonical)
                )
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.isDownloadedLocally != rhs.isDownloadedLocally {
                return lhs.isDownloadedLocally && !rhs.isDownloadedLocally
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Checks whether a local or iCloud ubiquitous file/package is actually materialized on disk
    /// without blocking or triggering an implicit iCloud download.
    public static func isFileDownloadedLocally(
        url: URL,
        resourceValues: URLResourceValues? = nil
    ) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }

        // Check macOS SF_DATALESS flag (0x40000000) via lstat — never triggers materialization
        var st = stat()
        if lstat(url.path, &st) == 0 {
            let sfDataless: UInt32 = 0x40000000
            if (st.st_flags & sfDataless) != 0 {
                return false
            }
        }

        let values = resourceValues ?? (try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]))
        if values?.isUbiquitousItem == true,
           let status = values?.ubiquitousItemDownloadingStatus {
            return status == .current || status == .downloaded
        }

        return true
    }

    public static func fileAvailability(at url: URL) -> LocalFileAvailability {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        if !isFileDownloadedLocally(url: url) {
            return .iCloudNotDownloaded
        }
        return .available
    }

    /// Requests iCloud Drive to materialize a dataless Apple Books item and waits until ready.
    public static func ensureICloudItemDownloaded(
        at url: URL,
        timeoutSeconds: TimeInterval = 35
    ) async throws {
        if isFileDownloadedLocally(url: url) { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LocalLibraryError.fileMissing(bookId: "", filePath: url.path)
        }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if isFileDownloadedLocally(url: url) {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw LocalLibraryError.iCloudDownloadTimedOut(url.deletingPathExtension().lastPathComponent)
    }

    /// Independent Direction B: sends a local `.epub` or `.pdf` file to Apple Books.
    @MainActor
    public static func sendToAppleBooks(fileURL: URL) async throws {
        guard isAppleBooksInstalled else {
            throw LocalLibraryError.appleBooksNotInstalled
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LocalLibraryError.fileMissing(bookId: "", filePath: fileURL.path)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: booksAppURL, configuration: config)
        } catch {
            throw LocalLibraryError.appleBooksOpenFailed(error.localizedDescription)
        }
    }
}
