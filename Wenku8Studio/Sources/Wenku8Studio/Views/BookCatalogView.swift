import SwiftUI
import Wenku8Core

struct BookCatalogView: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var showFullDescription = false

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if vm.isLoadingBook && vm.bookDetail == nil {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在拉取作品详情与章节目录...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let book = vm.bookDetail {
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                bookHeaderCard(book)
                                if !book.recommendations.isEmpty {
                                    recommendationsStrip(book)
                                }
                                catalogControlsBar(book)
                                volumesList(book)
                            }
                            .padding(20)
                            .padding(.bottom, 86)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(book.bookId)
                        .scrollEdgeEffectHidden(true, for: .all)

                        bottomActionBar(book)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 14)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if vm.showReviewsInspector {
                Divider()
                ReviewsInspectorView()
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.showReviewsInspector)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("轻小说文库 · macOS 原生客户端与 EPUB 拼装工坊")
                .font(.title3.weight(.semibold))
            Text("请在顶部搜索栏（⌘K）输入书号或轻小说文库网址，或前往「发现」与「书架与历史」选择作品，即可查看完整简介、勾选分卷章节、在线阅读或拼装定制 EPUB。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack {
                StudioPillButton(title: "前往发现页浏览书库", systemImage: "safari.fill", variant: .primary) {
                    vm.navigateToSection(.discovery)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bookHeaderCard(_ book: BookDetail) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let img = vm.coverPreviewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.15))
                        Image(systemName: "book.closed.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 126, height: 178)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.title2.weight(.bold))
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Button {
                                vm.loadAuthorWorks(author: book.author, sourceId: book.sourceId)
                            } label: {
                                Label(book.author, systemImage: "person.fill")
                            }
                            .buttonStyle(.link)

                            StudioSourceBadge(
                                title: vm.sourceBadgeTitle(for: book.sourceId),
                                sourceId: book.sourceId
                            )

                            if !book.publisher.isEmpty {
                                badge(book.publisher, color: .blue)
                            }
                            if !book.status.isEmpty {
                                badge(book.status, color: book.status.contains("完结") ? .green : .orange)
                            }
                            badge("书号 \(book.bookId)", color: .gray)
                        }
                    }
                    Spacer()
                    let saved = vm.isBookmarked(book.bookId, sourceId: book.sourceId)
                    StudioPillButton(
                        title: saved ? "已在书架" : "加入书架",
                        systemImage: saved ? "bookmark.fill" : "bookmark",
                        variant: saved ? .primary : .secondary,
                        size: .small
                    ) {
                        vm.toggleBookmark(book)
                    }
                    .help(
                        book.sourceId == "wenku8"
                            ? (vm.isCloudSessionAvailable ? "加入/移出书架（已登录，将直接同步到云端书架）" : "加入/移出书架（当前未登录，将暂存本地并在登录后同步）")
                            : "加入/移出本地书架"
                    )
                }

                HStack(spacing: 16) {
                    if !book.wordCount.isEmpty {
                        Label(book.wordCount, systemImage: "character.book.closed")
                    }
                    if !book.lastUpdated.isEmpty {
                        Label("更新 \(book.lastUpdated)", systemImage: "calendar")
                    }
                    if !book.popularity.isEmpty {
                        Label(book.popularity, systemImage: "flame")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !book.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(book.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }

                if !book.description.isEmpty {
                    Text(book.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullDescription ? nil : 3)
                        .onTapGesture { showFullDescription.toggle() }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        StudioFilterChip(title: "开始阅读", systemImage: "book.pages", isSelected: true) {
                            vm.openLastReadOrFirstChapter()
                        }

                        if vm.currentBookSupportsReviews {
                            StudioFilterChip(
                                title: vm.showReviewsInspector ? "收起评论" : "展开评论",
                                systemImage: vm.showReviewsInspector ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right",
                                isSelected: vm.showReviewsInspector
                            ) {
                                vm.toggleReviewsInspectorForCurrentBook()
                            }
                        }

                        if vm.currentBookSupportsCloudActions {
                            StudioFilterChip(
                                title: vm.isVotingBook ? "投票中..." : "推一下",
                                systemImage: "hand.thumbsup",
                                isSelected: false
                            ) {
                                vm.voteCurrentBook()
                            }
                            .disabled(vm.isVotingBook)
                            .help("为本书投推荐票（每日可用账号推荐次数）")
                        }

                        StudioFilterChip(title: "同作者作品", systemImage: "person.2", isSelected: false) {
                            vm.loadAuthorWorks(author: book.author, sourceId: book.sourceId)
                        }

                        StudioFilterChip(title: "拼装设置", systemImage: "slider.horizontal.3", isSelected: false) {
                            vm.scrollToAssemblyToken = UUID()
                            vm.navigateToSettingsCategory(.assembly)
                        }

                        Spacer(minLength: 12)
                        Text("来源：\(book.baseURL.replacingOccurrences(of: "https://", with: ""))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .studioCard(cornerRadius: StudioTokens.cardRadiusLarge, padding: 16)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func recommendationsStrip(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同分类推荐")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(book.recommendations, id: \.scopedId) { rec in
                        RecommendationBookChip(rec: rec) {
                            vm.loadBook(inputOverride: rec.id, sourceIdOverride: rec.sourceId)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollEdgeEffectHidden(true, for: .all)
        }
    }

    private func catalogControlsBar(_ book: BookDetail) -> some View {
        let isManga = book.contentKind == .manga
        let quickActionButtons = HStack(spacing: 8) {
            StudioPillButton(
                title: vm.areAllChaptersSelected ? "已全选" : (isManga ? "全选全组" : "全选整本"),
                systemImage: vm.areAllChaptersSelected ? "checkmark.circle.fill" : "checklist.checked",
                variant: vm.areAllChaptersSelected ? .primary : .secondary,
                size: .small
            ) {
                vm.selectAllChapters()
            }
            StudioPillButton(title: isManga ? "仅主连载组" : "仅首卷", size: .small) { vm.selectFirstVolumeOnly() }
            StudioPillButton(title: "清空", size: .small) { vm.clearSelection() }
            StudioPillButton(title: "反选", size: .small) { vm.invertSelection() }
            if isManga {
                StudioPillButton(
                    title: vm.mangaCatalogReversed ? "倒序（最新在前）" : "正序（第1话在前）",
                    systemImage: "arrow.up.arrow.down",
                    size: .small
                ) {
                    vm.mangaCatalogReversed.toggle()
                }
            } else {
                StudioPillButton(title: "仅含插图卷", size: .small) { vm.selectIllustratedVolumesOnly() }
            }
        }
        .fixedSize(horizontal: true, vertical: false)

        let filterInputs = HStack(spacing: 10) {
            StudioSearchField(
                icon: "magnifyingglass",
                placeholder: isManga ? "按话数名称过滤..." : "按章节名过滤...",
                text: $vm.chapterSearchQuery
            )
            .frame(minWidth: 150, maxWidth: 230)

            StudioSearchField(
                icon: "number",
                placeholder: isManga ? "按分组号勾选（1-2）" : "按卷号勾选（1-3）",
                text: $vm.volumeRangeInput,
                onSubmit: { vm.applyVolumeRangeSelection() }
            )
            .frame(minWidth: 160, maxWidth: 230)

            StudioPillButton(title: isManga ? "应用分组" : "应用卷号", size: .small) {
                vm.applyVolumeRangeSelection()
            }
            .fixedSize()
        }

        let exportModeTabs = Group {
            if isManga {
                HStack(spacing: 8) {
                    StudioSegmentedTabs(selection: $vm.mangaExportFormat, items: MangaExportFormat.allCases)
                        .frame(width: 210)
                    StudioFilterChip(
                        title: vm.mangaMergeSelectedChapters ? "合并为单本" : "每话独立文件",
                        systemImage: vm.mangaMergeSelectedChapters ? "doc.on.doc.fill" : "square.stack.fill",
                        isSelected: vm.mangaMergeSelectedChapters
                    ) {
                        vm.mangaMergeSelectedChapters.toggle()
                    }
                }
            } else {
                StudioSegmentedTabs(selection: $vm.assemblyConfig.exportMode, items: ExportMode.allCases)
                    .frame(width: 280)
            }
        }

        let headerTitle = isManga
            ? "漫画分组与话数目录（共 \(book.volumes.count) 组）"
            : "分卷与章节目录（共 \(book.volumes.count) 卷）"

        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(headerTitle)
                        .font(.headline)
                        .fixedSize()
                    Spacer(minLength: 12)
                    quickActionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(headerTitle)
                        .font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        quickActionButtons
                    }
                    .scrollEdgeEffectHidden(true, for: .all)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filterInputs
                    Spacer(minLength: 8)
                    exportModeTabs
                }

                VStack(alignment: .leading, spacing: 8) {
                    filterInputs
                    HStack {
                        exportModeTabs
                        Spacer()
                    }
                }
            }
        }
    }

    private func volumesList(_ book: BookDetail) -> some View {
        let isManga = book.contentKind == .manga
        return LazyVStack(spacing: 10) {
            ForEach(book.volumes) { vol in
                let rawFiltered = filteredChapters(for: vol)
                let orderedChaps = (isManga && vm.mangaCatalogReversed) ? Array(rawFiltered.reversed()) : rawFiltered
                if !orderedChaps.isEmpty || vm.chapterSearchQuery.isEmpty {
                    VolumeSectionCard(
                        volume: vol,
                        chapters: orderedChaps,
                        selectionState: vm.volumeSelectionState(vol),
                        isExpanded: Binding(
                            get: { vm.expandedVolumeIds.contains(vol.id) || !vm.chapterSearchQuery.isEmpty },
                            set: { expand in
                                if expand { vm.expandedVolumeIds.insert(vol.id) }
                                else { vm.expandedVolumeIds.remove(vol.id) }
                            }
                        ),
                        selectedChapterIds: vm.selectedChapterIds,
                        onToggleVolume: { vm.toggleVolume(vol) },
                        onToggleChapter: { vm.toggleChapter($0) },
                        onPreviewChapter: { vm.openChapterInReader($0) }
                    )
                }
            }
        }
    }

    private func filteredChapters(for vol: VolumeItem) -> [ChapterItem] {
        let q = vm.chapterSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vol.chapters }
        return vol.chapters.filter { $0.title.lowercased().contains(q) }
    }

    private func bottomActionBar(_ book: BookDetail) -> some View {
        let isManga = book.contentKind == .manga
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if isManga {
                    Text("已选 \(vm.selectedVolumesCount) 组 · \(vm.selectedBodyChaptersCount) 话")
                        .font(.callout.weight(.medium))
                        .contentTransition(.numericText())
                    Text("输出至：\(vm.outputDirectoryPath)（\(vm.mangaExportFormat.rawValue) · \(vm.mangaMergeSelectedChapters ? "合并单本" : "每话独立")）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("已选 \(vm.selectedVolumesCount) 卷 · \(vm.selectedBodyChaptersCount) 个正文章节")
                        .font(.callout.weight(.medium))
                        .contentTransition(.numericText())
                    Text("输出至：\(vm.outputDirectoryPath)（\(vm.assemblyConfig.exportMode.rawValue)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if vm.isDownloading {
                ProgressView(value: vm.progressFraction)
                    .frame(width: 140)
                StudioPillButton(title: "取消下载", systemImage: "stop.fill", variant: .destructive) {
                    vm.cancelDownload()
                }
            } else {
                StudioPillButton(
                    title: isManga ? "整本导出 \(vm.mangaExportFormat.fileExtension.uppercased())" : "整本一键转 EPUB",
                    systemImage: "books.vertical.fill",
                    size: .large,
                    isDisabled: book.volumes.isEmpty
                ) {
                    vm.downloadFullBookAsSingleEPUB()
                }
                .help(isManga ? "自动全选并合并导出为单个完整漫画包" : "自动全选所有分卷与章节，并合并导出为单个完整 EPUB")

                StudioPillButton(
                    title: isManga ? "下载选中 \(vm.mangaExportFormat.fileExtension.uppercased())" : "下载选中 EPUB",
                    systemImage: "arrow.down.doc.fill",
                    variant: .primary,
                    size: .large,
                    isDisabled: vm.selectedChapterIds.isEmpty
                ) {
                    vm.startDownloadSelected()
                }
            }
        }
        .studioCard(cornerRadius: StudioTokens.cardRadiusLarge, padding: 14)
    }
}

private struct VolumeSectionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let volume: VolumeItem
    let chapters: [ChapterItem]
    let selectionState: Int
    @Binding var isExpanded: Bool
    let selectedChapterIds: Set<String>
    let onToggleVolume: () -> Void
    let onToggleChapter: (ChapterItem) -> Void
    let onPreviewChapter: (ChapterItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onToggleVolume) {
                    Image(systemName: selectionIcon)
                        .font(.title3)
                        .foregroundStyle(selectionState == 0 ? Color.secondary : Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text("[\(volume.index)] \(volume.title)")
                            .font(.headline)
                        if volume.hasIllustrationChapter {
                            Text("含彩插")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .foregroundStyle(.purple)
                                .background(Color.purple.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        Text("\(volume.chapters.count) 章")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(chapters) { chap in
                        HStack(spacing: 10) {
                            Button {
                                onToggleChapter(chap)
                            } label: {
                                Image(systemName: selectedChapterIds.contains(chap.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedChapterIds.contains(chap.id) ? Color.accentColor : Color.secondary)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .buttonStyle(.plain)

                            Text(chap.title)
                                .font(.callout)
                                .foregroundStyle(chap.isIllustrationChapter ? .purple : .primary)

                            if chap.isIllustrationChapter {
                                Text("插图页")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }

                            Spacer()

                            Button {
                                onPreviewChapter(chap)
                            } label: {
                                Label("阅读", systemImage: "eye")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)

                        if chap.id != chapters.last?.id {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectionIcon: String {
        switch selectionState {
        case 2: return "checkmark.square.fill"
        case 1: return "minus.square.fill"
        default: return "square"
        }
    }
}

private struct RecommendationBookChip: View {
    let rec: RecommendedBook
    let action: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: rec.isCompleted ? "checkmark.seal.fill" : "book.fill")
                    .foregroundStyle(rec.isCompleted ? .green : studioAccent)
                Text(rec.title)
                    .foregroundStyle(isHovered ? studioAccent : Color.primary)
                    .lineLimit(1)
            }
            .font(.caption.weight(isHovered ? .medium : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isHovered
                            ? studioAccent.opacity(0.11)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                    .shadow(
                        color: isHovered ? studioAccent.opacity(0.14) : StudioTokens.cardShadowColor,
                        radius: 3,
                        y: 1.5
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered ? studioAccent.opacity(0.45) : StudioTokens.hairlineStroke,
                        lineWidth: isHovered ? 1.1 : 0.8
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(StudioPressScaleStyle(pressedScale: 0.96))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .help("点击打开《\(rec.title)》目录")
    }
}
