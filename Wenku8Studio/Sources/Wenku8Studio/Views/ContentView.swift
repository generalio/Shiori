import SwiftUI
import Wenku8Core

struct ContentView: View {
    @EnvironmentObject var vm: StudioViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var sidebarNamespace
    @State private var focusTopSearch: Bool = false
    @State private var showAccountPopover: Bool = false

    private var hideGlobalChrome: Bool {
        vm.selectedSection == .reader && vm.isFocusReadingMode
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 218, ideal: 238, max: 276)
        } detail: {
            VStack(spacing: 0) {
                if !hideGlobalChrome {
                    topNavigationBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider().opacity(0.65)
                }
                topStatusBanners
                detailWorkspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: hideGlobalChrome)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $vm.showWebLoginSheet) {
            WebLoginSheet()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.showAppleBooksImportSheet) {
            AppleBooksImportSheet()
                .environmentObject(vm)
        }
        .preferredColorScheme(vm.appColorScheme.colorScheme)
        .tint(vm.appAccentTheme == .system ? nil : vm.appAccentTheme.color)
        .environment(\.studioAccentColor, vm.appAccentTheme.color)
        .background {
            Group {
                Button("") { vm.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { vm.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { focusTopSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0.001)
        }
    }

    // MARK: - Left Floating-Style Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Group {
                    if let nsIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                        Image(nsImage: nsIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(vm.appAccentTheme.color.gradient)
                            .overlay {
                                Image(systemName: "books.vertical.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: StudioTokens.cardShadowColor, radius: 3, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Shiori")
                        .font(.headline.weight(.bold))
                    let activeCount = vm.sourceRegistry.enabledOnlinePlugins().count
                    Text(activeCount > 0 ? "栞 · \(activeCount) 个在线书源 + 本地书库" : "栞 · 多源与本地阅读工坊")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SidebarSection.allCases.filter { vm.isSidebarSectionVisible($0) }) { section in
                        StudioNavTabRow(
                            section: section,
                            isSelected: vm.selectedSection == section,
                            badgeCount: badgeCount(for: section),
                            isBusy: section == .tasks && vm.isDownloading,
                            selectionNamespace: sidebarNamespace,
                            onSelect: {
                                vm.navigateToSection(section)
                            }
                        )
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            if vm.showSidebarQuickBookCard, let detail = vm.bookDetail {
                Button {
                    vm.navigateToSection(.catalog)
                } label: {
                    HStack(spacing: 9) {
                        AsyncCoverThumbnail(
                            urlString: detail.coverURL,
                            sourceId: detail.sourceId,
                            maxPixelSize: 160
                        )
                        .frame(width: 30, height: 42)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(detail.author)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                            .shadow(color: StudioTokens.cardShadowColor, radius: 4, y: 1.5)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.8)
                    }
                }
                .buttonStyle(StudioPressScaleStyle(pressedScale: 0.97))
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .help("当前打开的书籍，点击返回目录")
            }
        }
        .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: vm.bookDetail?.scopedId)
        .background(.ultraThinMaterial)
    }

    private func badgeCount(for section: SidebarSection) -> Int {
        switch section {
        case .catalog: return vm.selectedBodyChaptersCount
        case .bookshelf: return vm.bookmarks.count
        default: return 0
        }
    }

    // MARK: - Top Navigation Bar (Back/Forward + Search + Account)

    private var topNavigationBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                StudioCircleButton(
                    systemImage: "chevron.left",
                    variant: .secondary,
                    size: .regular,
                    isDisabled: !vm.canGoBack,
                    accessibilityLabel: "返回上一页"
                ) {
                    vm.goBack()
                }
                .help("返回上一次页面 (⌘[)")

                StudioCircleButton(
                    systemImage: "chevron.right",
                    variant: .secondary,
                    size: .regular,
                    isDisabled: !vm.canGoForward,
                    accessibilityLabel: "前进"
                ) {
                    vm.goForward()
                }
                .help("前进 (⌘])")

                StudioCircleButton(
                    systemImage: "arrow.clockwise",
                    variant: .secondary,
                    size: .regular,
                    isLoading: vm.isLoadingBook || vm.isLoadingDiscovery || vm.isSyncingBookshelf,
                    spinIconWhenLoading: true,
                    accessibilityLabel: "刷新当前页面"
                ) {
                    vm.refreshCurrentView()
                }
                .help("刷新当前页面")
            }

            HStack(spacing: 8) {
                StudioSearchField(
                    icon: "magnifyingglass",
                    placeholder: "输入书号（如 3115）、网址或书名关键词...",
                    text: $vm.bookInput,
                    shortcutHint: "⌘K",
                    focusTrigger: $focusTopSearch,
                    onSubmit: { vm.handleQuickTopBarSubmit() }
                )
                .frame(maxWidth: 400)

                StudioCircleButton(
                    systemImage: "arrow.right",
                    variant: .primary,
                    size: .regular,
                    isLoading: vm.isLoadingBook,
                    isDisabled: vm.bookInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    accessibilityLabel: "直达或搜索"
                ) {
                    vm.handleQuickTopBarSubmit()
                }
                .help("输入数字/链接直达目录，输入文字搜索轻小说")
            }

            Spacer()

            accountPillButton

            StudioCircleButton(
                systemImage: "gearshape",
                variant: vm.selectedSection == .settings ? .primary : .secondary,
                size: .regular,
                accessibilityLabel: "设置与 EPUB 拼装"
            ) {
                vm.navigateToSection(.settings)
            }
            .help("设置与 EPUB 拼装")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar, ignoresSafeAreaEdges: [])
    }

    private var accountPillButton: some View {
        let enabledPlugins = vm.sourceRegistry.enabledOnlinePlugins()
        let verifiedCount = enabledPlugins.filter { plugin in
            vm.sourceAuthState(for: plugin.descriptor.id).isVerified
        }.count

        return Button {
            showAccountPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(verifiedCount > 0 ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                if let profile = vm.userProfile, !profile.username.isEmpty {
                    Text(profile.nickname.isEmpty ? profile.username : profile.nickname)
                        .font(.caption.weight(.semibold))
                    if enabledPlugins.count > 1 {
                        Text("\(verifiedCount)/\(enabledPlugins.count) 源")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !profile.level.isEmpty {
                        Text(profile.level)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(verifiedCount > 0 ? "已认证 \(verifiedCount)/\(enabledPlugins.count) 源" : "书源账号 · 点击管理")
                        .font(.caption.weight(.medium))
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.86))
                    .shadow(color: StudioTokens.cardShadowColor, radius: 4, y: 1.5)
            }
            .overlay {
                Capsule()
                    .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.9)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAccountPopover, arrowEdge: .bottom) {
            multiSourceAccountPopover
        }
        .help("管理各已启用书源的登录会话与导入凭证")
    }

    private var multiSourceAccountPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("多书源会话管理")
                    .font(.headline)
                Spacer()
                StudioPillButton(title: "书源设置", systemImage: "slider.horizontal.3", variant: .subtle, size: .small) {
                    showAccountPopover = false
                    vm.navigateToSettingsCategory(.account)
                }
            }

            Divider()

            ForEach(vm.sourceRegistry.allOnlinePlugins(), id: \.descriptor.id) { plugin in
                let sid = plugin.descriptor.id
                let enabled = vm.sourceRegistry.isEnabled(sid)
                let auth = vm.sourceAuthState(for: sid)

                HStack(spacing: 10) {
                    Circle()
                        .fill(!enabled ? Color.secondary.opacity(0.35) : (auth.isVerified ? Color.green : (auth.hasCredentials ? Color.orange : Color.secondary.opacity(0.5))))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(plugin.descriptor.displayName)
                                .font(.callout.weight(.semibold))
                            StudioSourceBadge(title: plugin.descriptor.shortBadge, sourceId: sid)
                            if !enabled {
                                Text("已停用")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(authStatusSummary(for: sid, auth: auth, enabled: enabled))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if enabled {
                        HStack(spacing: 6) {
                            StudioPillButton(
                                title: sid == "wenku8" ? "登录" : "导入 / 登录",
                                systemImage: sid == "wenku8" ? "person.crop.circle" : "key.fill",
                                variant: auth.isVerified ? .secondary : .primary,
                                size: .small
                            ) {
                                showAccountPopover = false
                                vm.openWebLogin(for: sid)
                            }
                            if auth.hasCredentials {
                                StudioCircleButton(systemImage: "arrow.clockwise", size: .small, accessibilityLabel: "验证 \(plugin.descriptor.displayName)") {
                                    vm.testSourceSession(sourceId: sid)
                                }
                                .help("验证当前凭证")
                                StudioCircleButton(systemImage: "trash", variant: .destructive, size: .small, accessibilityLabel: "清除 \(plugin.descriptor.displayName) 凭证") {
                                    vm.clearSavedCookie(for: sid)
                                }
                                .help("清除保存的凭证")
                            }
                        }
                    } else {
                        StudioPillButton(title: "去启用", variant: .subtle, size: .small) {
                            showAccountPopover = false
                            vm.navigateToSettingsCategory(.source(sid))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(width: 410)
    }

    private func authStatusSummary(for sourceId: String, auth: SourceAuthState, enabled: Bool) -> String {
        guard enabled else { return "插件当前已停用" }
        if sourceId == "wenku8", let profile = vm.userProfile, !profile.username.isEmpty {
            return "\(profile.nickname.isEmpty ? profile.username : profile.nickname) · \(profile.level)"
        }
        if auth.isVerified {
            return auth.accountLabel.isEmpty ? "会话已验证" : auth.accountLabel
        }
        if let err = auth.lastErrorMessage, !err.isEmpty {
            return err
        }
        if sourceId == "copymanga" {
            return auth.hasCredentials ? "已保存 Token，待验证" : "匿名可看漫 · 可选导入 Token 同步云书架"
        }
        return auth.hasCredentials ? "已保存凭证，待验证" : "未登录 / 待验证"
    }

    // MARK: - Status Banners

    @ViewBuilder
    private var topStatusBanners: some View {
        VStack(spacing: 8) {
            if !vm.crossSourceAlternativeRoutes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(.secondary)
                    Text("此编号也可在其他已启用书源打开：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(vm.crossSourceAlternativeRoutes, id: \.sourceId) { alt in
                        StudioPillButton(
                            title: "在\(alt.displayName)查看 #\(alt.bookId)",
                            size: .small
                        ) {
                            vm.loadBook(inputOverride: alt.bookId, sourceIdOverride: alt.sourceId)
                        }
                    }
                    Spacer()
                    StudioCircleButton(systemImage: "xmark", variant: .subtle, size: .small, accessibilityLabel: "关闭跨源提示") {
                        vm.crossSourceAlternativeRoutes = []
                    }
                }
                .studioCard(cornerRadius: 12, padding: 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let progress = vm.localImportProgressText, vm.isImportingLocalBooks, !vm.showAppleBooksImportSheet {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                }
                .studioCard(cornerRadius: 12, padding: 10, tint: .indigo)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let err = vm.errorBanner {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                    if let missingId = vm.missingLocalBookId {
                        if vm.missingLocalBookNeedsICloud {
                            StudioPillButton(
                                title: "从 iCloud 下载",
                                systemImage: "icloud.and.arrow.down",
                                variant: .primary,
                                size: .small,
                                isLoading: vm.isImportingLocalBooks
                            ) {
                                vm.downloadICloudLocalBookAndReload(bookId: missingId)
                            }
                        } else {
                            StudioPillButton(
                                title: "重新定位文件…",
                                systemImage: "folder.badge.questionmark",
                                variant: .primary,
                                size: .small
                            ) {
                                vm.relinkLocalBook(bookId: missingId)
                            }
                        }
                    }
                    StudioPillButton(title: "关闭", variant: .subtle, size: .small) {
                        vm.errorBanner = nil
                        vm.missingLocalBookId = nil
                        vm.missingLocalBookPath = nil
                        vm.missingLocalBookNeedsICloud = false
                    }
                }
                .studioCard(cornerRadius: 12, padding: 10, tint: .orange)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let ok = vm.statusBanner {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(ok)
                        .font(.callout)
                    Spacer()
                    StudioPillButton(title: "打开目录", variant: .secondary, size: .small) {
                        vm.openOutputFolder()
                    }
                    StudioPillButton(title: "关闭", variant: .subtle, size: .small) {
                        vm.statusBanner = nil
                    }
                }
                .studioCard(cornerRadius: 12, padding: 10, tint: .green)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, (vm.errorBanner != nil || vm.statusBanner != nil || !vm.crossSourceAlternativeRoutes.isEmpty) ? 18 : 0)
        .padding(.top, (vm.errorBanner != nil || vm.statusBanner != nil || !vm.crossSourceAlternativeRoutes.isEmpty) ? 10 : 0)
        .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: vm.errorBanner)
        .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: vm.statusBanner)
        .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: vm.crossSourceAlternativeRoutes.count)
    }

    @ViewBuilder
    private var detailWorkspace: some View {
        switch vm.selectedSection {
        case .discovery:
            DiscoveryView()
        case .bookshelf:
            BookshelfHistoryView()
        case .catalog:
            BookCatalogView()
        case .reader:
            ReaderPreviewView()
        case .tasks:
            TasksAndLogsView()
        case .settings:
            SettingsAndAssemblyView()
        }
    }
}
