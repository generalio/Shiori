import SwiftUI
import Wenku8Core

struct BookCatalogView: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var showFullDescription = false

    var body: some View {
        Group {
            if vm.isLoadingBook && vm.bookDetail == nil {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在从 \(vm.baseURL) 拉取书籍信息与目录...")
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
                        .padding(.bottom, 76)
                    }
                    .id(book.bookId)
                    .scrollEdgeEffectHidden(true, for: .all)

                    bottomActionBar(book)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                }
                .clipped()
            } else {
                emptyStateView
            }
        }
        .inspector(isPresented: $vm.showReviewsInspector) {
            ReviewsInspectorView()
                .inspectorColumnWidth(min: 340, ideal: 410, max: 520)
        }
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
                                vm.loadAuthorWorks(author: book.author)
                            } label: {
                                Label(book.author, systemImage: "person.fill")
                            }
                            .buttonStyle(.link)

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
                    let saved = vm.isBookmarked(book.bookId)
                    StudioPillButton(
                        title: saved ? "已在书架" : "加入书架",
                        systemImage: saved ? "bookmark.fill" : "bookmark",
                        variant: saved ? .primary : .secondary,
                        size: .small
                    ) {
                        vm.toggleBookmark(book)
                    }
                    .help(vm.isCloudSessionAvailable ? "加入/移出书架（已登录，将直接同步到云端书架）" : "加入/移出书架（当前未登录，将暂存本地并在登录后同步）")
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

                        StudioFilterChip(
                            title: vm.showReviewsInspector ? "收起/查看书评" : "查看书评",
                            systemImage: "bubble.left.and.bubble.right",
                            isSelected: vm.showReviewsInspector
                        ) {
                            vm.openReviewsInspectorForCurrentBook()
                        }

                        StudioFilterChip(
                            title: vm.isVotingBook ? "投票中..." : "推一下",
                            systemImage: "hand.thumbsup",
                            isSelected: false
                        ) {
                            vm.voteCurrentBook()
                        }
                        .disabled(vm.isVotingBook)
                        .help("为本书投推荐票（每日可用账号推荐次数）")

                        StudioFilterChip(title: "同作者作品", systemImage: "person.2", isSelected: false) {
                            vm.loadAuthorWorks(author: book.author)
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
                    ForEach(book.recommendations) { rec in
                        RecommendationBookChip(rec: rec) {
                            vm.loadBook(inputOverride: rec.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollEdgeEffectHidden(true, for: .all)
        }
    }

    private func catalogControlsBar(_ book: BookDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分卷与章节目录（共 \(book.volumes.count) 卷）")
                    .font(.headline)
                Spacer()
                HStack(spacing: 8) {
                    StudioPillButton(
                        title: vm.areAllChaptersSelected ? "已全选整本" : "全选整本",
                        systemImage: vm.areAllChaptersSelected ? "checkmark.circle.fill" : "checklist.checked",
                        variant: vm.areAllChaptersSelected ? .primary : .secondary,
                        size: .small
                    ) {
                        vm.selectAllChapters()
                    }
                    StudioPillButton(title: "仅首卷", size: .small) { vm.selectFirstVolumeOnly() }
                    StudioPillButton(title: "清空", size: .small) { vm.clearSelection() }
                    StudioPillButton(title: "反选", size: .small) { vm.invertSelection() }
                    StudioPillButton(title: "仅含插图卷", size: .small) { vm.selectIllustratedVolumesOnly() }
                }
            }

            HStack(spacing: 10) {
                StudioSearchField(
                    icon: "magnifyingglass",
                    placeholder: "按章节名过滤...",
                    text: $vm.chapterSearchQuery
                )
                .frame(maxWidth: 230)

                StudioSearchField(
                    icon: "number",
                    placeholder: "按卷号勾选（如 1-3 或 1,2,4）",
                    text: $vm.volumeRangeInput,
                    onSubmit: { vm.applyVolumeRangeSelection() }
                )
                .frame(maxWidth: 250)

                StudioPillButton(title: "应用卷号", size: .small) {
                    vm.applyVolumeRangeSelection()
                }

                Spacer()

                StudioSegmentedTabs(selection: $vm.assemblyConfig.exportMode, items: ExportMode.allCases)
                    .frame(maxWidth: 300)
            }
        }
    }

    private func volumesList(_ book: BookDetail) -> some View {
        LazyVStack(spacing: 10) {
            ForEach(book.volumes) { vol in
                let filteredChaps = filteredChapters(for: vol)
                if !filteredChaps.isEmpty || vm.chapterSearchQuery.isEmpty {
                    VolumeSectionCard(
                        volume: vol,
                        chapters: filteredChaps,
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(vm.selectedVolumesCount) 卷 · \(vm.selectedBodyChaptersCount) 个正文章节")
                    .font(.callout.weight(.medium))
                    .contentTransition(.numericText())
                Text("输出至：\(vm.outputDirectoryPath)（\(vm.assemblyConfig.exportMode.rawValue)）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                    title: "整本一键转 EPUB",
                    systemImage: "books.vertical.fill",
                    size: .large,
                    isDisabled: book.volumes.isEmpty
                ) {
                    vm.downloadFullBookAsSingleEPUB()
                }
                .help("自动全选所有分卷与章节，并合并导出为单个完整 EPUB")

                StudioPillButton(
                    title: "下载选中 EPUB",
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
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
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
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(chapters) { chap in
                        HStack(spacing: 10) {
                            Button {
                                onToggleChapter(chap)
                            } label: {
                                Image(systemName: selectedChapterIds.contains(chap.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedChapterIds.contains(chap.id) ? Color.accentColor : Color.secondary)
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
    @State private var isPressed = false

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
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered ? studioAccent.opacity(0.45) : StudioTokens.hairlineStroke,
                        lineWidth: isHovered ? 1.1 : 0.8
                    )
            }
            .shadow(
                color: isHovered ? studioAccent.opacity(0.14) : StudioTokens.cardShadowColor,
                radius: isHovered ? 5 : 2,
                y: isHovered ? 2 : 1
            )
            .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                    }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.14)) { isPressed = false }
                }
        )
        .help("点击打开《\(rec.title)》目录")
    }
}
