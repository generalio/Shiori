import SwiftUI
import Wenku8Core

struct DiscoveryView: View {
    @EnvironmentObject var vm: StudioViewModel

    private var activeSourceTitle: String {
        if let filter = vm.selectedDiscoverySourceFilter,
           let plugin = vm.sourceRegistry.plugin(for: filter) {
            return plugin.descriptor.displayName
        }
        return vm.sourceRegistry.plugin(for: vm.activeDiscoverySourceId)?.descriptor.displayName ?? "轻小说文库"
    }

    private var currentChannelSourceId: String {
        vm.selectedDiscoverySourceFilter ?? vm.activeDiscoverySourceId
    }

    var body: some View {
        VStack(spacing: 0) {
            discoveryHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if vm.showTagBrowser {
                        tagBrowserCard
                    }

                    if let notice = vm.discoveryNotice {
                        noticeCard(notice)
                    }

                    if !vm.discoveryBooks.isEmpty {
                        sectionHeader(vm.discoveryTitle, count: vm.discoveryBooks.count)
                        discoveryGrid(vm.discoveryBooks)
                        if vm.discoveryTotalPages > 1 {
                            paginationBar
                        }
                    } else if let current = vm.bookDetail, !current.recommendations.isEmpty {
                        sectionHeader("关联推荐 · 来自《\(current.title)》", count: current.recommendations.count)
                        recommendationsGrid(current.recommendations)
                    } else {
                        emptyDiscoveryPrompt
                    }
                }
                .padding(20)
            }
            .scrollEdgeEffectHidden(true, for: .all)
        }
        .onAppear {
            if vm.discoveryBooks.isEmpty && vm.activeDiscoverySort.isEmpty && !vm.isLoadingDiscovery,
               let path = vm.defaultDiscoveryChannel.path {
                vm.loadDiscoveryList(title: vm.defaultDiscoveryChannel.rawValue, path: path, sourceId: "wenku8")
            }
        }
    }

    private var discoveryHeader: some View {
        let enabledPlugins = vm.sourceRegistry.enabledPlugins()
        let channels = vm.activeDiscoveryChannels()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StudioSearchField(
                    icon: "magnifyingglass",
                    placeholder: "搜索轻小说书名、作者名、书号或链接...",
                    text: $vm.searchQuery,
                    onSubmit: { vm.performDiscoverySearch() }
                )

                StudioSegmentedTabs(selection: $vm.searchScope, items: SearchScope.allCases)
                    .frame(width: 224)

                StudioPillButton(
                    title: "搜索",
                    systemImage: "magnifyingglass",
                    variant: .primary,
                    isLoading: vm.isLoadingDiscovery,
                    isDisabled: vm.isLoadingDiscovery || vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
                ) {
                    vm.performDiscoverySearch()
                }
            }

            if enabledPlugins.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        StudioFilterChip(
                            title: "全部渠道",
                            systemImage: "square.stack.3d.up.fill",
                            isSelected: vm.selectedDiscoverySourceFilter == nil
                        ) {
                            vm.setDiscoverySourceFilter(nil)
                        }

                        ForEach(enabledPlugins, id: \.descriptor.id) { plugin in
                            let sid = plugin.descriptor.id
                            StudioFilterChip(
                                title: plugin.descriptor.displayName,
                                systemImage: sid == "bilinovel" ? "sparkles.rectangle.stack" : "books.vertical",
                                isSelected: vm.selectedDiscoverySourceFilter == sid
                            ) {
                                vm.setDiscoverySourceFilter(sid)
                                vm.showTagBrowser = false
                                if let disc = plugin as? any DiscoveryCapableSource,
                                   let firstChannel = disc.discoveryChannels().first {
                                    vm.loadDiscoveryList(title: firstChannel.title, path: firstChannel.path, sourceId: sid)
                                }
                            }
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if currentChannelSourceId == "wenku8" {
                        StudioFilterChip(
                            title: "Tags 标签云",
                            systemImage: "tag.fill",
                            isSelected: vm.showTagBrowser || vm.selectedTag != nil
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                vm.showTagBrowser.toggle()
                            }
                            if vm.showTagBrowser && vm.tagGroups.isEmpty {
                                vm.loadTagGroups()
                            }
                        }
                    }

                    ForEach(channels) { channel in
                        StudioFilterChip(
                            title: channel.title,
                            systemImage: channel.icon,
                            isSelected: vm.activeDiscoverySort == channel.path && vm.activeDiscoverySourceId == channel.sourceId
                        ) {
                            vm.loadDiscoveryList(title: channel.title, path: channel.path, sourceId: channel.sourceId)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func noticeCard(_ notice: String) -> some View {
        let challengeSourceId = vm.discoveryChallengeSourceId ?? "wenku8"
        let isChallenge = vm.discoveryRequiresCookie
        let titleText: String = {
            if !isChallenge { return "提示" }
            return challengeSourceId == "bilinovel"
                ? "需要人机验证或登录会话"
                : "需要登录账号以访问全站搜索与榜单"
        }()

        return HStack(spacing: 12) {
            Image(systemName: isChallenge ? "person.badge.key.fill" : "info.circle.fill")
                .font(.title3)
                .foregroundStyle(isChallenge ? .orange : .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.headline)
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isChallenge {
                StudioPillButton(title: "前往配置", systemImage: "gearshape", variant: .primary, size: .small) {
                    if challengeSourceId == "wenku8" {
                        vm.navigateToSettingsCategory(.account)
                    } else {
                        vm.navigateToSettingsCategory(.source(challengeSourceId))
                    }
                }
                StudioPillButton(title: "网页登录 / 验证", systemImage: "safari", size: .small) {
                    vm.openWebLogin(for: challengeSourceId)
                }
            }
        }
        .studioCard(cornerRadius: StudioTokens.cardRadius, padding: 14, tint: isChallenge ? .orange : .blue)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Text("\(count) 本")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
            if vm.discoveryTotalPages > 1 {
                Text("第 \(vm.discoveryPage) / \(vm.discoveryTotalPages) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Spacer()
            StudioPillButton(
                title: "上一页",
                systemImage: "chevron.left",
                size: .small,
                isDisabled: vm.discoveryPage <= 1 || vm.isLoadingDiscovery
            ) {
                vm.loadDiscoveryPage(vm.discoveryPage - 1)
            }

            Text("第 \(vm.discoveryPage) / \(vm.discoveryTotalPages) 页")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            StudioPillButton(
                title: "下一页",
                systemImage: "chevron.right",
                size: .small,
                isDisabled: vm.discoveryPage >= vm.discoveryTotalPages || vm.isLoadingDiscovery
            ) {
                vm.loadDiscoveryPage(vm.discoveryPage + 1)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var tagBrowserCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("官方 Tags 云集", systemImage: "tag.circle.fill")
                    .font(.headline)
                Spacer()
                StudioSegmentedTabs(selection: $vm.tagSortOption, items: TagSortOption.allCases) { $0.displayName }
                    .frame(maxWidth: 320)
                    .onChange(of: vm.tagSortOption) { _, newSort in
                        if let tag = vm.selectedTag {
                            vm.loadBooksByTag(tag, sort: newSort, page: 1)
                        }
                    }

                StudioCircleButton(systemImage: "arrow.clockwise", size: .small, accessibilityLabel: "刷新标签云") {
                    vm.loadTagGroups()
                }
                .help("刷新标签云")
            }

            if vm.isLoadingTags {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在拉取标签云...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if vm.tagGroups.isEmpty {
                Text("暂无标签数据（需要登录后从 wenku8 拉取 Tags 分类）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(vm.tagGroups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(group.tags, id: \.self) { tag in
                                        let active = vm.selectedTag == tag
                                        Button {
                                            vm.loadBooksByTag(tag, sort: vm.tagSortOption, page: 1)
                                        } label: {
                                            Text(tag)
                                                .font(.caption)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(active ? Color.white : Color.primary)
                                        .background(
                                            active ? Color.accentColor : Color.secondary.opacity(0.12),
                                            in: Capsule()
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func discoveryGrid(_ items: [AuthorBookItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 500), spacing: 14)], spacing: 14) {
            ForEach(items, id: \.scopedId) { item in
                BookItemCard(
                    item: BookCardItem(authorItem: item),
                    sourceBadgeTitle: vm.sourceBadgeTitle(for: item.sourceId),
                    isBookmarked: vm.isBookmarked(item.id, sourceId: item.sourceId),
                    showBookmarkButton: true,
                    showSummary: vm.showCardSummary,
                    isCompact: vm.compactBookCards,
                    onOpen: {
                        vm.loadBook(inputOverride: item.id, sourceIdOverride: item.sourceId)
                    },
                    onOpenAuthor: { author in
                        vm.loadAuthorWorks(author: author, sourceId: item.sourceId)
                    },
                    onToggleBookmark: {
                        vm.toggleBookmarkFromAuthorItem(item)
                    }
                )
            }
        }
    }

    private func recommendationsGrid(_ items: [RecommendedBook]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)], spacing: 14) {
            ForEach(items, id: \.scopedId) { rec in
                RecommendedBookCard(rec: rec)
            }
        }
    }

    private var emptyDiscoveryPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("探索轻小说书库 · \(activeSourceTitle)")
                .font(.title3.weight(.semibold))
            Text("可直接搜索作者名、书名或书号，也可切换上方渠道或点击榜单发现热门与完结好书。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                if let firstChannel = vm.activeDiscoveryChannels().first {
                    StudioPillButton(title: "浏览\(firstChannel.title)", systemImage: firstChannel.icon, variant: .primary) {
                        vm.loadDiscoveryList(title: firstChannel.title, path: firstChannel.path, sourceId: firstChannel.sourceId)
                    }
                }

                StudioPillButton(title: "搜索作者「猫玄」", systemImage: "person.fill") {
                    vm.loadAuthorWorks(author: "猫玄", sourceId: currentChannelSourceId)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct RecommendedBookCard: View {
    @EnvironmentObject var vm: StudioViewModel
    let rec: RecommendedBook
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AsyncCoverThumbnail(
                    urlString: rec.coverURL,
                    sourceId: rec.sourceId,
                    maxPixelSize: 320
                )
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                if rec.isCompleted {
                    Text("已完结")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.9), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }

            Text(rec.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)

            Text("书号 \(rec.id)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : StudioTokens.hairlineStroke, lineWidth: isHovered ? 1.4 : 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            vm.loadBook(inputOverride: rec.id, sourceIdOverride: rec.sourceId)
        }
    }
}
