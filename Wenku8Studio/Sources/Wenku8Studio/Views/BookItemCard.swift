import SwiftUI
import Wenku8Core

struct BookCardItem: Identifiable, Hashable {
    let sourceId: String
    let id: String
    let title: String
    let author: String
    let coverURL: String
    let publisher: String
    let status: String
    let wordCount: String
    let lastUpdated: String
    let tags: [String]
    let summary: String
    let cloudChapterTitle: String
    let hasSyncedToCloud: Bool
    let cloudRecordId: String
    let cloudGroupId: String

    var scopedId: String { "\(sourceId):\(id)" }

    init(entry: BookmarkEntry, liveDetail: BookDetail? = nil) {
        self.sourceId = entry.sourceId
        self.id = entry.id
        self.title = entry.title
        self.author = entry.author
        self.coverURL = entry.coverURL
        self.publisher = entry.publisher.isEmpty ? (liveDetail?.publisher ?? "") : entry.publisher
        self.status = entry.status.isEmpty ? (liveDetail?.status ?? "") : entry.status
        self.wordCount = entry.wordCount.isEmpty ? (liveDetail?.wordCount ?? "") : entry.wordCount
        self.lastUpdated = entry.lastUpdated.isEmpty ? (liveDetail?.lastUpdated ?? "") : entry.lastUpdated
        self.tags = entry.tags.isEmpty ? (liveDetail?.tags ?? []) : entry.tags
        self.summary = entry.summary.isEmpty ? (liveDetail?.description ?? "") : entry.summary
        self.cloudChapterTitle = entry.cloudChapterTitle
        self.hasSyncedToCloud = entry.hasSyncedToCloud
        self.cloudRecordId = entry.cloudRecordId
        self.cloudGroupId = entry.cloudGroupId
    }

    init(authorItem: AuthorBookItem) {
        self.sourceId = authorItem.sourceId
        self.id = authorItem.id
        self.title = authorItem.title
        self.author = authorItem.author
        self.coverURL = authorItem.coverURL
        self.publisher = authorItem.category
        self.status = authorItem.status
        self.wordCount = authorItem.wordCount
        self.lastUpdated = authorItem.updatedAt
        self.tags = authorItem.tags
        self.summary = authorItem.summary
        self.cloudChapterTitle = ""
        self.hasSyncedToCloud = false
        self.cloudRecordId = ""
        self.cloudGroupId = "0"
    }
}

struct BookItemCard: View {
    @Environment(\.studioAccentColor) private var studioAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: BookCardItem
    let sourceBadgeTitle: String
    var isBookmarked: Bool = false
    var showBookmarkButton: Bool = true
    var showSyncBadge: Bool = false
    var showSummary: Bool = true
    var isCompact: Bool = false
    var deleteTooltip: String? = nil
    var onOpen: () -> Void
    var onOpenAuthor: ((String) -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onToggleBookmark: (() -> Void)? = nil
    var onResumeChapter: (() -> Void)? = nil
    var cloudGroups: [CloudBookcaseGroup] = []
    var onMoveCloudGroup: ((String) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            coverView

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)

                    Spacer(minLength: 4)

                    HStack(spacing: 6) {
                        if showBookmarkButton, let onToggleBookmark {
                            StudioCircleButton(
                                systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                                variant: isBookmarked ? .primary : .secondary,
                                size: .small,
                                bounceTrigger: isBookmarked,
                                accessibilityLabel: isBookmarked ? "移出书架" : "加入书架",
                                action: onToggleBookmark
                            )
                            .help(isBookmarked ? "移出书架" : "加入书架")
                        }

                        if cloudGroups.count > 1, !item.cloudRecordId.isEmpty, let onMoveCloudGroup {
                            let groupOptions = cloudGroups.map { group in
                                let isCurrent = (group.id == item.cloudGroupId)
                                return StudioMenuOption(
                                    id: group.id,
                                    title: isCurrent ? "\(group.title)（当前）" : "移至 \(group.title)",
                                    isSelected: isCurrent,
                                    isDisabled: isCurrent
                                ) {
                                    onMoveCloudGroup(group.id)
                                }
                            }
                            StudioCircleMenu(
                                systemImage: "chevron.down",
                                variant: .secondary,
                                size: .small,
                                header: "移动到云端分组",
                                accessibilityLabel: "移动到其他云端书架分组",
                                options: groupOptions
                            )
                            .help("移动到其他云端书架分组")
                        }

                        if let onDelete {
                            StudioCircleButton(
                                systemImage: "trash",
                                variant: .destructive,
                                size: .small,
                                accessibilityLabel: deleteTooltip ?? "删除",
                                action: onDelete
                            )
                            .help(deleteTooltip ?? "删除")
                        }
                    }
                }

                HStack(spacing: 6) {
                    if !item.author.isEmpty {
                        Button(item.author) {
                            onOpenAuthor?(item.author)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .lineLimit(1)
                    }
                    if !item.publisher.isEmpty {
                        pill(item.publisher, color: .blue)
                    }
                    if !item.status.isEmpty {
                        pill(item.status, color: item.status.contains("完结") ? .green : .orange)
                    }
                }

                if !item.wordCount.isEmpty || !item.lastUpdated.isEmpty {
                    HStack(spacing: 10) {
                        if !item.wordCount.isEmpty {
                            Label(item.wordCount, systemImage: "character.book.closed")
                                .lineLimit(1)
                        }
                        if !item.lastUpdated.isEmpty {
                            Label("更新 \(item.lastUpdated)", systemImage: "calendar")
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if !isCompact && !item.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.tags.prefix(4), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    .clipped()
                }

                if showSummary && !isCompact && !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !item.cloudChapterTitle.isEmpty, let onResumeChapter {
                    Button(action: onResumeChapter) {
                        Label("云端续读：\(item.cloudChapterTitle)", systemImage: "book.pages")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(studioAccent)
                    .background(studioAccent.opacity(0.12), in: Capsule())
                }

                Spacer(minLength: 2)

                HStack(spacing: 8) {
                    StudioSourceBadge(
                        title: sourceBadgeTitle,
                        sourceId: item.sourceId
                    )
                    Text("#\(item.id)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if showSyncBadge {
                        let supportsCloud = item.sourceId == "wenku8"
                        Label(
                            supportsCloud ? (item.hasSyncedToCloud ? "云端同步" : "仅本地") : "本地收藏",
                            systemImage: supportsCloud ? (item.hasSyncedToCloud ? "icloud.fill" : "internaldrive") : "bookmark.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(supportsCloud && item.hasSyncedToCloud ? studioAccent : Color.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        // Hardware shadowPath on background RoundedRectangle avoids offscreen alpha-mask re-rasterization of text & cover on hover/scroll
        .background {
            RoundedRectangle(cornerRadius: StudioTokens.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(
                    color: isHovered ? studioAccent.opacity(0.14) : Color.black.opacity(0.045),
                    radius: 4,
                    y: 1.5
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: StudioTokens.cardRadius, style: .continuous)
                .strokeBorder(
                    isHovered ? studioAccent.opacity(0.55) : StudioTokens.hairlineStroke,
                    lineWidth: isHovered ? 1.4 : 0.9
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: StudioTokens.cardRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onOpen()
        }
    }

    private var coverView: some View {
        AsyncCoverThumbnail(
            urlString: item.coverURL,
            sourceId: item.sourceId,
            maxPixelSize: 280
        )
        .frame(width: 76, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
