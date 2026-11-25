import SwiftUI
import Wenku8Core

struct BookshelfHistoryView: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var filterScope: ShelfScope = .all
    @State private var filterText: String = ""
    @State private var selectedSourceFilter: String? = nil
    @State private var selectedMediaFilter: ContentKind? = nil

    enum ShelfScope: String, CaseIterable, Identifiable {
        case all = "全部"
        case bookshelf = "书架"
        case history = "最近浏览"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if filterScope == .all || filterScope == .bookshelf {
                        unifiedBookshelfSection
                    }

                    if filterScope == .all || filterScope == .history {
                        historySection
                    }
                }
                .padding(20)
            }
            .scrollEdgeEffectHidden(true, for: .all)
        }
        .onAppear {
            if vm.isCloudSessionAvailable && !vm.isSyncingBookshelf {
                vm.syncBookshelfBidirectionally(silent: true)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            StudioSegmentedTabs(selection: $filterScope, items: ShelfScope.allCases)
                .frame(maxWidth: 300)

            StudioSearchField(
                icon: "line.3.horizontal.decrease.circle",
                placeholder: "筛选书名或作者...",
                text: $filterText
            )
            .frame(maxWidth: 240)

            Spacer()

            StudioPillButton(
                title: "云书架同步",
                systemImage: "arrow.triangle.2.circlepath.icloud",
                size: .small,
                isLoading: vm.isSyncingBookshelf,
                isDisabled: vm.isSyncingBookshelf
            ) {
                vm.syncAllCloudShelves(silent: false)
            }
            .help("按书源分别同步已登录的云端书架并合并到本地馆藏")

            if !vm.history.isEmpty {
                StudioPillButton(title: "清空浏览", systemImage: "trash", variant: .destructive, size: .small) {
                    withAnimation {
                        vm.clearHistory()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func filteredBookmarks() -> [BookmarkEntry] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return vm.bookmarks.filter { entry in
            if let sid = selectedSourceFilter, entry.sourceId != sid {
                return false
            }
            if let media = selectedMediaFilter {
                let entryKind = vm.contentKind(for: entry.sourceId)
                if entryKind != media && entryKind != .mixed {
                    return false
                }
            }
            let matchesGroup: Bool
            if vm.activeCloudGroupFilter == "all" || vm.cloudBookcaseGroups.count <= 1 || entry.sourceId != "wenku8" {
                matchesGroup = true
            } else {
                matchesGroup = entry.cloudGroupId == vm.activeCloudGroupFilter
            }
            guard matchesGroup else { return false }
            guard !q.isEmpty else { return true }
            return entry.title.lowercased().contains(q) || entry.author.lowercased().contains(q) || entry.id.contains(q)
        }
    }

    private func filteredHistory() -> [BookmarkEntry] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return vm.history.filter { entry in
            if let sid = selectedSourceFilter, entry.sourceId != sid {
                return false
            }
            if let media = selectedMediaFilter {
                let entryKind = vm.contentKind(for: entry.sourceId)
                if entryKind != media && entryKind != .mixed {
                    return false
                }
            }
            guard !q.isEmpty else { return true }
            return entry.title.lowercased().contains(q) || entry.author.lowercased().contains(q) || entry.id.contains(q)
        }
    }

    private var unifiedBookshelfSection: some View {
        let items = filteredBookmarks()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("书架", systemImage: "books.vertical.fill")
                    .font(.title3.weight(.bold))
                Text("\(items.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())

                if vm.isCloudSessionAvailable {
                    Label("云端双向同步", systemImage: "icloud.fill")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.green)
                        .background(Color.green.opacity(0.14), in: Capsule())
                } else {
                    Label("离线本地模式", systemImage: "internaldrive")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .foregroundStyle(.orange)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }

                if !vm.cloudCapacityTip.isEmpty {
                    Text(vm.cloudCapacityTip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let lastSync = vm.lastBookshelfSyncAt {
                    Text("同步于 \(lastSync.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    StudioFilterChip(title: "全部媒介", isSelected: selectedMediaFilter == nil) {
                        selectedMediaFilter = nil
                    }
                    StudioFilterChip(title: "轻小说", systemImage: "book.fill", isSelected: selectedMediaFilter == .lightNovel) {
                        selectedMediaFilter = .lightNovel
                    }
                    StudioFilterChip(title: "漫画", systemImage: "photo.stack.fill", isSelected: selectedMediaFilter == .manga) {
                        selectedMediaFilter = .manga
                    }
                    Divider().frame(height: 16)
                    StudioFilterChip(title: "全部书源", isSelected: selectedSourceFilter == nil) {
                        selectedSourceFilter = nil
                    }
                    ForEach(vm.sourceRegistry.allPlugins(), id: \.descriptor.id) { plugin in
                        let sid = plugin.descriptor.id
                        StudioFilterChip(title: plugin.descriptor.displayName, isSelected: selectedSourceFilter == sid) {
                            selectedSourceFilter = sid
                        }
                    }
                }
            }

            if !vm.isCloudSessionAvailable {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(vm.bookshelfSyncNotice ?? "当前未登录，新增收藏将暂存本地；登录后会自动推送到 wenku8 云端并双向同步。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    StudioPillButton(title: "网页登录", systemImage: "safari", variant: .primary, size: .small) {
                        vm.openWebLogin(for: "wenku8")
                    }
                }
                .studioCard(cornerRadius: 12, padding: 12, tint: .orange)
            }

            if vm.cloudBookcaseGroups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        groupChip(id: "all", title: "全部分组")
                        ForEach(vm.cloudBookcaseGroups) { group in
                            groupChip(id: group.id, title: group.title)
                        }
                    }
                }
            }

            if items.isEmpty {
                Text("书架暂无藏书，可在书籍详情页或发现页点击「加入书架」（轻小说文库已登录时直推云端）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 14)], spacing: 14) {
                    ForEach(items, id: \.scopedId) { entry in
                        let live = (vm.bookDetail?.bookId == entry.id && vm.bookDetail?.sourceId == entry.sourceId) ? vm.bookDetail : nil
                        BookItemCard(
                            item: BookCardItem(entry: entry, liveDetail: live),
                            sourceBadgeTitle: vm.sourceBadgeTitle(for: entry.sourceId),
                            isBookmarked: true,
                            showBookmarkButton: false,
                            showSyncBadge: true,
                            showSummary: vm.showCardSummary,
                            isCompact: vm.compactBookCards,
                            deleteTooltip: (entry.sourceId == "wenku8" && vm.isCloudSessionAvailable) ? "移出书架（同步从云端删除）" : "移出本地书架",
                            onOpen: {
                                vm.loadBook(inputOverride: entry.id, sourceIdOverride: entry.sourceId)
                            },
                            onOpenAuthor: { author in
                                vm.loadAuthorWorks(author: author, sourceId: entry.sourceId)
                            },
                            onDelete: {
                                withAnimation {
                                    vm.removeBookmark(id: entry.id, sourceId: entry.sourceId)
                                }
                            },
                            onResumeChapter: entry.cloudChapterId.isEmpty ? nil : {
                                vm.openBookmarkChapter(entry)
                            },
                            cloudGroups: (entry.sourceId == "wenku8" && vm.isCloudSessionAvailable) ? vm.cloudBookcaseGroups : [],
                            onMoveCloudGroup: { targetGroupId in
                                vm.moveBookmarkToCloudGroup(entry, toClassId: targetGroupId)
                            }
                        )
                    }
                }
            }
        }
    }

    private func groupChip(id: String, title: String) -> some View {
        StudioFilterChip(title: title, isSelected: vm.activeCloudGroupFilter == id) {
            vm.activeCloudGroupFilter = id
        }
    }

    private var historySection: some View {
        let items = filteredHistory()
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近浏览", systemImage: "clock.fill")
                    .font(.title3.weight(.bold))
                Text("\(items.count)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                Spacer()
            }

            if items.isEmpty {
                Text("暂无最近浏览记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 14)], spacing: 14) {
                    ForEach(items, id: \.scopedId) { entry in
                        let live = (vm.bookDetail?.bookId == entry.id && vm.bookDetail?.sourceId == entry.sourceId) ? vm.bookDetail : nil
                        BookItemCard(
                            item: BookCardItem(entry: entry, liveDetail: live),
                            sourceBadgeTitle: vm.sourceBadgeTitle(for: entry.sourceId),
                            isBookmarked: vm.isBookmarked(entry.id, sourceId: entry.sourceId),
                            showBookmarkButton: true,
                            showSummary: vm.showCardSummary,
                            isCompact: vm.compactBookCards,
                            deleteTooltip: "删除此条浏览记录",
                            onOpen: {
                                vm.loadBook(inputOverride: entry.id, sourceIdOverride: entry.sourceId)
                            },
                            onOpenAuthor: { author in
                                vm.loadAuthorWorks(author: author, sourceId: entry.sourceId)
                            },
                            onDelete: {
                                withAnimation {
                                    vm.removeHistoryItem(id: entry.id, sourceId: entry.sourceId)
                                }
                            },
                            onToggleBookmark: {
                                vm.toggleBookmarkFromEntry(entry)
                            }
                        )
                    }
                }
            }
        }
    }
}
