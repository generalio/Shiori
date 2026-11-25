import Foundation

/// Reconciles remote `CloudShelf` entries into `LocalShelf` strictly within the owning `BookSource`
/// boundary (`ScopedBookID`), guaranteeing zero cross-source pollution or unintended deletions.
public enum LocalShelfReconciler {
    public static func mergeReadOnlyCloudItems(
        localEntries: [BookmarkEntry],
        remoteItems: [CloudBookcaseItem],
        sourceId: String,
        publisherFallback: String = ""
    ) -> [BookmarkEntry] {
        var result = localEntries
        var indexByScopedId: [String: Int] = [:]
        for (idx, entry) in result.enumerated() {
            indexByScopedId[entry.scopedId] = idx
        }

        for remote in remoteItems {
            let scopedKey = "\(sourceId):\(remote.aid)"
            if let existingIdx = indexByScopedId[scopedKey] {
                var existing = result[existingIdx]
                if !remote.title.isEmpty { existing.title = remote.title }
                if !remote.author.isEmpty { existing.author = remote.author }
                if !remote.coverURL.isEmpty { existing.coverURL = remote.coverURL }
                existing.cloudRecordId = remote.bid
                existing.cloudGroupId = remote.groupId
                if !remote.lastReadChapterId.isEmpty { existing.cloudChapterId = remote.lastReadChapterId }
                if !remote.lastReadChapterTitle.isEmpty { existing.cloudChapterTitle = remote.lastReadChapterTitle }
                existing.hasSyncedToCloud = true
                result[existingIdx] = existing
            } else {
                let entry = BookmarkEntry(
                    id: remote.aid,
                    sourceId: sourceId,
                    title: remote.title,
                    author: remote.author,
                    coverURL: remote.coverURL,
                    publisher: publisherFallback,
                    status: "",
                    cloudRecordId: remote.bid,
                    cloudGroupId: remote.groupId,
                    cloudChapterId: remote.lastReadChapterId,
                    cloudChapterTitle: remote.lastReadChapterTitle,
                    hasSyncedToCloud: true
                )
                indexByScopedId[scopedKey] = result.count
                result.append(entry)
            }
        }
        return result
    }
}
