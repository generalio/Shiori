import Foundation

public struct SourceSearchNotice: Identifiable, Hashable, Sendable {
    public var id: String { sourceId }
    public let sourceId: String
    public let sourceName: String
    public let message: String
    public let requiresChallenge: Bool

    public init(sourceId: String, sourceName: String, message: String, requiresChallenge: Bool) {
        self.sourceId = sourceId
        self.sourceName = sourceName
        self.message = message
        self.requiresChallenge = requiresChallenge
    }
}

public struct AggregatedSearchResult: Sendable {
    public let items: [AuthorBookItem]
    public let totalPages: Int
    public let notices: [SourceSearchNotice]

    public init(items: [AuthorBookItem], totalPages: Int, notices: [SourceSearchNotice]) {
        self.items = items
        self.totalPages = totalPages
        self.notices = notices
    }
}

public struct AggregatedSearchEngine: Sendable {
    public let registry: SourceRegistry

    public init(registry: SourceRegistry) {
        self.registry = registry
    }

    /// Searches either a single specific plugin (`sourceId != nil`) or concurrently across all enabled plugins (`sourceId == nil`).
    public func search(
        query: String,
        scope: SearchScope,
        page: Int = 1,
        sourceId: String? = nil,
        contentKindFilter: ContentKind? = nil
    ) async -> AggregatedSearchResult {
        let targets: [any BookSourcePlugin]
        if let sourceId, let single = registry.plugin(for: sourceId) {
            targets = [single]
        } else {
            targets = registry.enabledPlugins(matching: contentKindFilter)
        }

        guard !targets.isEmpty else {
            return AggregatedSearchResult(items: [], totalPages: 1, notices: [])
        }

        // Single-source shortcut preserves exact pagination without interleaving
        if targets.count == 1, let plugin = targets.first {
            do {
                let res = try await plugin.search(query: query, scope: scope, page: page)
                return AggregatedSearchResult(items: res.items, totalPages: res.totalPages, notices: [])
            } catch let err as SourceError {
                let needsChallenge: Bool
                switch err {
                case .challengeRequired, .loginRequired: needsChallenge = true
                default: needsChallenge = false
                }
                return AggregatedSearchResult(
                    items: [],
                    totalPages: 1,
                    notices: [
                        SourceSearchNotice(
                            sourceId: plugin.descriptor.id,
                            sourceName: plugin.descriptor.displayName,
                            message: err.localizedDescription,
                            requiresChallenge: needsChallenge
                        )
                    ]
                )
            } catch {
                return AggregatedSearchResult(
                    items: [],
                    totalPages: 1,
                    notices: [
                        SourceSearchNotice(
                            sourceId: plugin.descriptor.id,
                            sourceName: plugin.descriptor.displayName,
                            message: error.localizedDescription,
                            requiresChallenge: false
                        )
                    ]
                )
            }
        }

        // Concurrent multi-source fan-out via TaskGroup
        var perSourceResults: [(index: Int, items: [AuthorBookItem], pages: Int, notice: SourceSearchNotice?)] = []

        await withTaskGroup(of: (Int, [AuthorBookItem], Int, SourceSearchNotice?).self) { group in
            for (idx, plugin) in targets.enumerated() {
                group.addTask {
                    do {
                        let res = try await plugin.search(query: query, scope: scope, page: page)
                        return (idx, res.items, res.totalPages, nil)
                    } catch let err as SourceError {
                        let needsChallenge: Bool
                        switch err {
                        case .challengeRequired, .loginRequired: needsChallenge = true
                        default: needsChallenge = false
                        }
                        let notice = SourceSearchNotice(
                            sourceId: plugin.descriptor.id,
                            sourceName: plugin.descriptor.displayName,
                            message: err.localizedDescription,
                            requiresChallenge: needsChallenge
                        )
                        return (idx, [], 1, notice)
                    } catch {
                        let notice = SourceSearchNotice(
                            sourceId: plugin.descriptor.id,
                            sourceName: plugin.descriptor.displayName,
                            message: error.localizedDescription,
                            requiresChallenge: false
                        )
                        return (idx, [], 1, notice)
                    }
                }
            }

            for await entry in group {
                perSourceResults.append(entry)
            }
        }

        perSourceResults.sort { $0.index < $1.index }

        // Interleave results round-robin across sources so top hits from each channel surface first
        var interleaved: [AuthorBookItem] = []
        let maxCount = perSourceResults.map(\.items.count).max() ?? 0
        for row in 0..<maxCount {
            for bucket in perSourceResults where row < bucket.items.count {
                interleaved.append(bucket.items[row])
            }
        }

        let maxPages = perSourceResults.map(\.pages).max() ?? 1
        let notices = perSourceResults.compactMap(\.notice)
        return AggregatedSearchResult(items: interleaved, totalPages: maxPages, notices: notices)
    }
}
