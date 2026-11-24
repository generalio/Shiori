import SwiftUI
import Wenku8Core

struct ContentView: View {
    @EnvironmentObject var vm: StudioViewModel
    @State private var focusTopSearch: Bool = false

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
                    Divider().opacity(0.65)
                }
                topStatusBanners
                detailWorkspace
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $vm.showWebLoginSheet) {
            WebLoginSheet()
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
                    Text(vm.baseURL.replacingOccurrences(of: "https://", with: ""))
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
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.8)
                    }
                    .shadow(color: StudioTokens.cardShadowColor, radius: 4, y: 1.5)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .help("当前打开的书籍，点击返回目录")
            }
        }
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
        Button {
            if vm.isCloudSessionAvailable {
                vm.navigateToSettingsCategory(.account)
            } else {
                vm.openWebLogin(for: "wenku8")
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(vm.isCloudSessionAvailable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                if let profile = vm.userProfile, !profile.username.isEmpty {
                    Text(profile.nickname.isEmpty ? profile.username : profile.nickname)
                        .font(.caption.weight(.semibold))
                    if !profile.level.isEmpty {
                        Text(profile.level)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(vm.isCloudSessionAvailable ? "已登录" : "未登录 · 点击登录")
                        .font(.caption.weight(.medium))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.86), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.9)
            }
            .shadow(color: StudioTokens.cardShadowColor, radius: 4, y: 1.5)
        }
        .buttonStyle(.plain)
        .help(vm.isCloudSessionAvailable ? "点击查看账号与保活设置" : "点击网页登录 wenku8 账号")
    }

    // MARK: - Status Banners

    @ViewBuilder
    private var topStatusBanners: some View {
        if vm.errorBanner != nil || vm.statusBanner != nil {
            VStack(spacing: 8) {
                if let err = vm.errorBanner {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.callout)
                            .lineLimit(2)
                        Spacer()
                        StudioPillButton(title: "关闭", variant: .subtle, size: .small) {
                            vm.errorBanner = nil
                        }
                    }
                    .studioCard(cornerRadius: 12, padding: 10, tint: .orange)
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
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
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
