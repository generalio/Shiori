import AppKit
import SwiftUI
import Wenku8Core

struct SettingsAndAssemblyView: View {
    @EnvironmentObject var vm: StudioViewModel
    @Environment(\.studioAccentColor) private var studioAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText: String = ""
    private let builder = EPUBBuilder()

    private var primaryCategories: [SettingsCategory] {
        [.general, .appearance, .reader, .account]
    }

    private var secondaryCategories: [SettingsCategory] {
        [.assembly]
    }

    private var infoCategories: [SettingsCategory] {
        [.about]
    }

    private var sourceCategories: [SettingsCategory] {
        vm.sourceRegistry.allPlugins().map { .source($0.descriptor.id) }
    }

    private func matchesSearch(_ category: SettingsCategory) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let keywords: [SettingsCategory: String] = [
            .general: "通用 站点 镜像 wenku8 下载 目录 并发 延迟 网络",
            .appearance: "外观 主题 浅色 深色 配色 强调色 自定义 页面 启动 侧边栏 卡片",
            .reader: "阅读器 字体 纸张 仿真 翻页 滚动 繁简 字号 行高 语音",
            .account: "账号 云端 cookie 登录 刷新 保活 书架 积分",
            .assembly: "epub 拼装 封面 彩插 排版 清洗 缩进 模板 文件名",
            .about: "关于 版本 更新 github 重置 恢复默认"
        ]
        let pluginExtra: String = {
            if case .source(let sid) = category,
               let desc = vm.sourceRegistry.plugin(for: sid)?.descriptor {
                return "\(desc.displayName) \(desc.subtitle) \(desc.id) 书源 插件"
            }
            return ""
        }()
        let corpus = "\(category.title) \(category.subtitle) \(keywords[category] ?? "") \(pluginExtra)".lowercased()
        return corpus.contains(q)
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: 222)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))

            Divider().opacity(0.7)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    categoryHeader(vm.activeSettingsCategory)

                    switch vm.activeSettingsCategory {
                    case .general:
                        generalSettingsContent
                    case .appearance:
                        appearanceSettingsContent
                    case .reader:
                        readerSettingsContent
                    case .account:
                        accountSettingsContent
                    case .assembly:
                        assemblySettingsContent
                    case .about:
                        aboutSettingsContent
                    case .source(let sourceId):
                        sourceSettingsContent(sourceId: sourceId)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollEdgeEffectHidden(true, for: .all)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: vm.scrollToAssemblyToken) { _, token in
            if token != nil {
                vm.activeSettingsCategory = .assembly
            }
        }
        .onChange(of: vm.baseURL) { _, _ in
            Task { await vm.syncClientSettings() }
        }
        .onChange(of: vm.maxConcurrency) { _, _ in
            vm.savePersistedState()
        }
        .onChange(of: vm.politeDelaySeconds) { _, _ in
            Task { await vm.syncClientSettings() }
        }
        .onChange(of: vm.assemblyConfig) { _, _ in
            vm.savePersistedState()
        }
    }

    // MARK: - Left Category Sidebar

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioSearchField(
                icon: "magnifyingglass",
                placeholder: "搜索设置",
                text: $searchText
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    categoryListGroup(title: nil, items: primaryCategories.filter(matchesSearch))
                    categoryListGroup(title: "书源平台", items: sourceCategories.filter(matchesSearch))
                    categoryListGroup(title: "内容与构建", items: secondaryCategories.filter(matchesSearch))
                    categoryListGroup(title: nil, items: infoCategories.filter(matchesSearch))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.callout)
                        .foregroundStyle(studioAccent)
                        .frame(width: 22, height: 22)
                        .background(studioAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("高级设置")
                            .font(.caption.weight(.semibold))
                        Text("显示全部选项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $vm.showAdvancedSettings)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: vm.showAdvancedSettings) { _, _ in
                            vm.savePersistedState()
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.8)
                }

                Text("Shiori \(vm.appVersionDisplay) (\(vm.buildNumberDisplay))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func categoryListGroup(title: String?, items: [SettingsCategory]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
                }
                ForEach(items) { cat in
                    let sourceEnabled: Bool? = {
                        if case .source(let sid) = cat {
                            return vm.sourceConfig(for: sid).isEnabled
                        }
                        return nil
                    }()
                    SettingsCategorySidebarRow(
                        category: cat,
                        isSelected: vm.activeSettingsCategory == cat,
                        sourceEnabled: sourceEnabled
                    ) {
                        vm.activeSettingsCategory = cat
                    }
                }
            }
        }
    }

    private func categoryHeader(_ category: SettingsCategory) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(category.tintColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: category.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(category.tintColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.title2.weight(.bold))
                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - 1. 通用 (General)

    private var generalSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCardGroup(title: "站点与镜像") {
                SettingsRow(title: "首选站点", subtitle: "主站受限时客户端将自动尝试镜像回退") {
                    Picker("", selection: $vm.baseURL) {
                        Text("备用主站（推荐）· wenku8.cc").tag("https://www.wenku8.cc")
                        Text("原主站（自动回退）· wenku8.net").tag("https://www.wenku8.net")
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }

                if vm.showAdvancedSettings {
                    Divider()
                    SettingsRow(title: "自定义站点地址", subtitle: "如使用其他兼容镜像域名，可直接填写完整 HTTPS 地址") {
                        StudioSearchField(
                            icon: "globe",
                            placeholder: "https://www.wenku8.cc",
                            text: $vm.baseURL
                        )
                        .frame(width: 250)
                    }
                }
            }

            SettingsCardGroup(title: "下载与存储") {
                SettingsRow(title: "EPUB 输出目录", subtitle: vm.outputDirectoryPath) {
                    HStack(spacing: 8) {
                        StudioPillButton(title: "打开目录", systemImage: "folder", size: .small) {
                            vm.openOutputFolder()
                        }
                        StudioPillButton(title: "更改...", size: .small) {
                            vm.chooseOutputDirectory()
                        }
                    }
                }

                if vm.showAdvancedSettings {
                    Divider()
                    SettingsRow(title: "图片并发线程数", subtitle: "控制下载章节插图时的最大并发请求数（推荐 4）") {
                        Stepper("\(vm.maxConcurrency) 线程", value: $vm.maxConcurrency, in: 1...16)
                            .monospacedDigit()
                    }

                    Divider()
                    SettingsRow(title: "章节请求间隔", subtitle: "每次抓取正文的礼貌限速延迟（\(String(format: "%.2f", vm.politeDelaySeconds)) 秒）") {
                        Slider(value: $vm.politeDelaySeconds, in: 0...1.5, step: 0.05)
                            .frame(width: 200)
                    }
                }
            }
        }
    }

    // MARK: - 2. 外观与主题 (Appearance & Custom Pages)

    private var appearanceSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCardGroup(title: "主题配色") {
                SettingsRow(title: "界面明暗模式", subtitle: "切换浅色、深色或跟随 macOS 系统外观") {
                    StudioSegmentedTabs(selection: $vm.appColorScheme, items: AppColorScheme.allCases)
                        .frame(width: 220)
                        .onChange(of: vm.appColorScheme) { _, _ in
                            vm.savePersistedState()
                        }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("主题强调色")
                            .font(.callout.weight(.medium))
                        Text("应用于侧边栏高亮、主按钮、卡片选中状态与阅读器控件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        ForEach(AppAccentTheme.allCases) { preset in
                            let isSelected = vm.appAccentTheme == preset
                            Button {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    vm.appAccentTheme = preset
                                }
                                vm.savePersistedState()
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        Circle()
                                            .fill(preset.swatchColor)
                                            .frame(width: 26, height: 26)
                                            .overlay {
                                                Circle()
                                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                                            }
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                    .padding(3)
                                    .overlay {
                                        if isSelected {
                                            Circle()
                                                .strokeBorder(preset.swatchColor, lineWidth: 1.8)
                                        }
                                    }

                                    Text(preset.rawValue)
                                        .font(.caption2.weight(isSelected ? .semibold : .regular))
                                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            SettingsCardGroup(title: "自定义启动与页面") {
                SettingsRow(title: "应用默认启动页", subtitle: "启动 Shiori 时默认呈现的功能工作区") {
                    let startupCandidates = SidebarSection.allCases.filter { vm.isSidebarSectionVisible($0) && $0 != .settings }
                    Picker("", selection: $vm.startupSection) {
                        ForEach(startupCandidates) { sec in
                            Text(sec.rawValue).tag(sec)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: vm.startupSection) { _, _ in
                        vm.savePersistedState()
                    }
                }

                Divider()

                SettingsRow(title: "发现页初始内容", subtitle: "首次进入「发现」页面时自动载入的榜单或引导页") {
                    Picker("", selection: $vm.defaultDiscoveryChannel) {
                        ForEach(DiscoveryHomeChannel.allCases) { ch in
                            Text(ch.rawValue).tag(ch)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .onChange(of: vm.defaultDiscoveryChannel) { _, _ in
                        vm.savePersistedState()
                    }
                }

                Divider()

                SettingsRow(title: "侧边栏当前阅读快捷卡片", subtitle: "在左侧栏底部展示最近打开的书籍，点击一键回到目录") {
                    Toggle("", isOn: $vm.showSidebarQuickBookCard)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.showSidebarQuickBookCard) { _, _ in
                            vm.savePersistedState()
                        }
                }
            }

            SettingsCardGroup(title: "自定义侧边栏板块") {
                ForEach(Array([SidebarSection.bookshelf, .catalog, .reader, .tasks].enumerated()), id: \.element.id) { idx, section in
                    if idx > 0 { Divider() }
                    SettingsRow(
                        title: section.rawValue,
                        subtitle: "控制左侧导航栏是否显示「\(section.rawValue)」页面入口"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { vm.isSidebarSectionVisible(section) },
                            set: { vm.setSidebarSection(section, visible: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                    }
                }
            }

            SettingsCardGroup(title: "列表卡片密度") {
                SettingsRow(title: "显示作品简介摘要", subtitle: "在发现页与书架卡片中显示两行简介预览") {
                    Toggle("", isOn: $vm.showCardSummary)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.showCardSummary) { _, _ in
                            vm.savePersistedState()
                        }
                }

                Divider()

                SettingsRow(title: "紧凑卡片模式", subtitle: "减少卡片内标签与边距，同屏容纳更多书籍") {
                    Toggle("", isOn: $vm.compactBookCards)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.compactBookCards) { _, _ in
                            vm.savePersistedState()
                        }
                }
            }
        }
    }

    // MARK: - 3. 阅读器 (Reader)

    private var readerSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCardGroup(title: "默认阅读体验") {
                SettingsRow(title: "默认翻页模式", subtitle: "支持仿真贝塞尔卷页、水平滑动或连续上下滚动") {
                    StudioSegmentedTabs(selection: $vm.readerPageMode, items: ReaderPageMode.allCases)
                        .frame(width: 240)
                        .onChange(of: vm.readerPageMode) { _, _ in vm.savePersistedState() }
                }

                Divider()

                SettingsRow(title: "阅读纸张主题", subtitle: "选择最适合长时间阅读的背景色调") {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { theme in
                            let selected = vm.readerTheme == theme
                            Button {
                                vm.readerTheme = theme
                                vm.savePersistedState()
                            } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(theme.swatchColor)
                                        .frame(width: 24, height: 24)
                                        .overlay {
                                            Circle()
                                                .strokeBorder(selected ? studioAccent : Color.primary.opacity(0.18), lineWidth: selected ? 2.2 : 1)
                                        }
                                    Text(theme.rawValue)
                                        .font(.caption2.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? studioAccent : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                SettingsRow(title: "默认字体", subtitle: "可选系统默认字体、衬线宋体、黑体或本地任意字体") {
                    StudioSegmentedTabs(selection: $vm.readerFontFamily, items: ReaderFontFamily.allCases)
                        .frame(width: 260)
                        .onChange(of: vm.readerFontFamily) { _, _ in vm.savePersistedState() }
                }

                if vm.readerFontFamily == .custom {
                    Divider()
                    SettingsRow(title: "指定系统字体族", subtitle: "选择 macOS 已安装字体") {
                        Picker("", selection: $vm.readerCustomFontName) {
                            ForEach(vm.availableSystemFontFamilies, id: \.self) { fam in
                                Text(fam).tag(fam)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: vm.readerCustomFontName) { _, _ in vm.savePersistedState() }
                    }
                }

                Divider()

                SettingsRow(title: "默认简繁转换", subtitle: "实时切换正文与标题显示用字") {
                    StudioSegmentedTabs(selection: $vm.readerScriptMode, items: ReaderScriptMode.allCases)
                        .frame(width: 220)
                        .onChange(of: vm.readerScriptMode) { _, _ in vm.savePersistedState() }
                }
            }

            SettingsCardGroup(title: "版式与排版参数") {
                SettingsRow(title: "正文字号：\(Int(vm.readerFontSize)) pt", subtitle: "调节正文文字大小（13 - 30 pt）") {
                    Slider(value: $vm.readerFontSize, in: 13...30, step: 1)
                        .frame(width: 200)
                        .onChange(of: vm.readerFontSize) { _, _ in vm.savePersistedState() }
                }

                Divider()

                SettingsRow(title: "行间距：\(Int(vm.readerLineSpacing)) pt", subtitle: "调节行与行之间的垂直呼吸感") {
                    Slider(value: $vm.readerLineSpacing, in: 4...22, step: 1)
                        .frame(width: 200)
                        .onChange(of: vm.readerLineSpacing) { _, _ in vm.savePersistedState() }
                }

                if vm.showAdvancedSettings {
                    Divider()

                    SettingsRow(title: "版心最大宽度：\(Int(vm.readerColumnWidth)) px", subtitle: "双页模式或宽屏窗口下正文的自适应列宽") {
                        Slider(value: $vm.readerColumnWidth, in: 540...1280, step: 20)
                            .frame(width: 200)
                            .onChange(of: vm.readerColumnWidth) { _, _ in vm.savePersistedState() }
                    }

                    Divider()

                    SettingsRow(title: "页边安全留白：\(Int(vm.readerEdgePadding)) pt", subtitle: "文本与纸张边缘的内边距") {
                        Slider(value: $vm.readerEdgePadding, in: 10...64, step: 2)
                            .frame(width: 200)
                            .onChange(of: vm.readerEdgePadding) { _, _ in vm.savePersistedState() }
                    }

                    Divider()

                    SettingsRow(title: "仿真/平移双页对开", subtitle: "宽窗口下左右两栏并排阅读，模拟实体书对页") {
                        Toggle("", isOn: $vm.readerDualPageEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: vm.readerDualPageEnabled) { _, _ in vm.savePersistedState() }
                    }

                    Divider()

                    SettingsRow(title: "段首自动缩进两个汉字", subtitle: "开启后自动为段落增加标准中文首行缩进") {
                        Toggle("", isOn: $vm.readerIndentEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .onChange(of: vm.readerIndentEnabled) { _, _ in vm.savePersistedState() }
                    }
                }
            }
        }
    }

    // MARK: - 4. 账号与云端 (Account & Cloud)

    private var accountSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let profile = vm.userProfile, !profile.username.isEmpty {
                SettingsCardGroup(title: "当前已登录账号") {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 34))
                            .foregroundStyle(.green)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(profile.nickname.isEmpty ? profile.username : profile.nickname) · \(profile.level.isEmpty ? "会员" : profile.level)")
                                .font(.headline)
                            Text("积分 \(profile.holdingPoints.isEmpty ? "-" : profile.holdingPoints) · 经验 \(profile.experienceValue.isEmpty ? "-" : profile.experienceValue) · 每日推荐 \(profile.dailyVoteQuota.isEmpty ? "-" : profile.dailyVoteQuota) 次 · 书架上限 \(profile.bookcaseCapacity.isEmpty ? "-" : profile.bookcaseCapacity) 本")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        StudioPillButton(title: "打开书架", systemImage: "books.vertical", variant: .primary, size: .small) {
                            vm.navigateToSection(.bookshelf)
                            vm.syncBookshelfBidirectionally(silent: true)
                        }
                    }
                    .padding(16)
                }
            }

            SettingsCardGroup(title: "账号会话与 Cookie") {
                SettingsRow(title: "授权与登录方式", subtitle: "解锁全站搜索、榜单翻页、每日推荐与云端书架双向同步") {
                    HStack(spacing: 8) {
                        StudioPillButton(
                            title: "网页登录",
                            systemImage: "safari",
                            variant: .primary,
                            size: .small
                        ) {
                            vm.openWebLogin(for: "wenku8")
                        }

                        StudioPillButton(
                            title: "检测有效性",
                            systemImage: "checkmark.shield",
                            size: .small,
                            isLoading: vm.isTestingCookie,
                            isDisabled: vm.isTestingCookie
                        ) {
                            vm.testCookieValidity()
                        }

                        StudioPillButton(
                            title: "立即续期",
                            systemImage: "arrow.triangle.2.circlepath",
                            size: .small,
                            isLoading: vm.isRefreshingCookie,
                            isDisabled: vm.isRefreshingCookie || vm.customCookie.isEmpty
                        ) {
                            Task { await vm.refreshCookieKeepAlive(silent: false) }
                        }

                        if !vm.customCookie.isEmpty {
                            StudioPillButton(title: "清空", systemImage: "trash", variant: .destructive, size: .small) {
                                vm.clearSavedCookie(for: "wenku8")
                            }
                        }
                    }
                }

                if vm.showAdvancedSettings || vm.customCookie.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("手动 Cookie 字符串")
                            .font(.callout.weight(.medium))
                        StudioSearchField(
                            icon: "key.horizontal",
                            placeholder: "粘贴 wenku8 Cookie（包含 jieqiUserInfo=...; PHPSESSID=...）",
                            text: $vm.customCookie
                        )

                        let diag = vm.cookieDiagnostic
                        HStack(spacing: 6) {
                            Image(systemName: diag.isLikelyValidFormat ? "checkmark.seal.fill" : (diag.isForeignSiteCookie ? "exclamationmark.triangle.fill" : "info.circle"))
                                .foregroundStyle(diag.isLikelyValidFormat ? .green : (diag.isForeignSiteCookie ? .orange : .secondary))
                            Text(diag.message)
                                .font(.caption)
                                .foregroundStyle(diag.isForeignSiteCookie ? .orange : .secondary)
                        }

                        if let verifyMsg = vm.cookieVerifyMessage {
                            HStack(spacing: 6) {
                                Image(systemName: (vm.cookieVerifyPassed == true) ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle((vm.cookieVerifyPassed == true) ? .green : .red)
                                Text(verifyMsg)
                                    .font(.caption)
                                    .foregroundStyle((vm.cookieVerifyPassed == true) ? .green : .red)
                            }
                        }
                    }
                    .padding(16)
                }
            }

            SettingsCardGroup(title: "动态刷新与保活") {
                SettingsRow(title: "自动定时保活", subtitle: "定期轻量续期，尽可能避免 PHPSESSID 与登录态失效") {
                    Toggle("", isOn: $vm.autoRefreshCookieEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.autoRefreshCookieEnabled) { _, _ in
                            vm.rescheduleCookieRefresh()
                        }
                }

                if vm.autoRefreshCookieEnabled {
                    Divider()
                    SettingsRow(title: "刷新间隔", subtitle: statusLineForCookieRefresh) {
                        StudioSegmentedTabs(
                            selection: $vm.cookieRefreshIntervalMinutes,
                            items: [5, 10, 15, 30, 60],
                            title: { "\($0) 分钟" }
                        )
                        .frame(width: 310)
                        .onChange(of: vm.cookieRefreshIntervalMinutes) { _, _ in
                            vm.rescheduleCookieRefresh()
                        }
                    }
                }
            }
        }
    }

    private var statusLineForCookieRefresh: String {
        var parts: [String] = []
        if let lastAt = vm.lastCookieRefreshAt {
            parts.append("上次：\(lastAt.formatted(date: .omitted, time: .shortened))")
        }
        if let nextAt = vm.nextCookieRefreshAt, vm.autoRefreshCookieEnabled {
            parts.append("下次：\(nextAt.formatted(date: .omitted, time: .shortened))")
        }
        if let status = vm.lastCookieRefreshStatus, !status.isEmpty {
            parts.append(status)
        }
        return parts.isEmpty ? "自动按周期请求站点刷新凭证" : parts.joined(separator: " · ")
    }

    // MARK: - 5. EPUB 拼装 (EPUB Assembly)

    private var assemblySettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCardGroup(title: "格式与扉页") {
                SettingsRow(title: "EPUB 规范版本", subtitle: "EPUB 3.0 支持更好的现代阅读器导航与样式") {
                    Picker("", selection: $vm.assemblyConfig.epubVersion) {
                        ForEach(EPUBVersion.allCases) { ver in
                            Text(ver.rawValue).tag(ver)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }

                Divider()

                SettingsRow(title: "分卷导出策略", subtitle: "导出为按卷独立的多个 EPUB 或合并成整本合集") {
                    StudioSegmentedTabs(selection: $vm.assemblyConfig.exportMode, items: ExportMode.allCases)
                        .frame(width: 240)
                }

                Divider()

                SettingsRow(title: "生成书籍简介扉页", subtitle: "包含封面、标签、字数及作品简介") {
                    Toggle("", isOn: $vm.assemblyConfig.includeInfoPage)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsCardGroup(title: "封面与彩插") {
                SettingsRow(title: "包含封面页", subtitle: "将书籍封面嵌入 EPUB 首页与阅读器书架缩略图") {
                    Toggle("", isOn: $vm.assemblyConfig.includeCover)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if vm.assemblyConfig.includeCover {
                    Divider()
                    SettingsRow(title: "封面来源", subtitle: "默认使用官网拉取的高清封面") {
                        Picker("", selection: $vm.assemblyConfig.coverSource) {
                            ForEach(CoverSourceMode.allCases) { src in
                                Text(src.rawValue).tag(src)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }

                    if vm.assemblyConfig.coverSource == .customLocalFile {
                        Divider()
                        SettingsRow(
                            title: "本地封面图片",
                            subtitle: vm.assemblyConfig.customCoverPath.isEmpty ? "尚未选择图片文件" : vm.assemblyConfig.customCoverPath
                        ) {
                            StudioPillButton(title: "选择文件...", systemImage: "photo", size: .small) {
                                vm.chooseCustomCoverImage()
                            }
                        }
                    }
                }

                Divider()

                SettingsRow(title: "彩插排版方式", subtitle: "设置每卷彩色插图的合并与展示逻辑") {
                    Picker("", selection: $vm.assemblyConfig.colorLayout) {
                        ForEach(ColorLayoutMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }

                if vm.assemblyConfig.colorLayout != .skipColor {
                    Divider()
                    SettingsRow(title: "彩插章节位置", subtitle: "将汇总彩插放置在卷首或卷末") {
                        Picker("", selection: $vm.assemblyConfig.colorPlacement) {
                            ForEach(ColorPlacement.allCases) { pos in
                                Text(pos.rawValue).tag(pos)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }

                    Divider()
                    SettingsRow(title: "自动去重插图", subtitle: "过滤已在正文中内嵌出现的重复插图") {
                        Toggle("", isOn: $vm.assemblyConfig.dedupColorImages)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()
                    SettingsRow(
                        title: "额外追加本地彩页",
                        subtitle: "当前已附加 \(vm.assemblyConfig.extraColorImagePaths.count) 张本地图片"
                    ) {
                        HStack(spacing: 8) {
                            if !vm.assemblyConfig.extraColorImagePaths.isEmpty {
                                StudioPillButton(title: "清空", systemImage: "trash", variant: .destructive, size: .small) {
                                    vm.assemblyConfig.extraColorImagePaths.removeAll()
                                }
                            }
                            StudioPillButton(title: "添加图片...", systemImage: "plus", size: .small) {
                                vm.addExtraColorImages()
                            }
                        }
                    }

                    if !vm.assemblyConfig.extraColorImagePaths.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(vm.assemblyConfig.extraColorImagePaths, id: \.self) { path in
                                HStack {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.caption)
                                    Spacer()
                                    StudioCircleButton(systemImage: "xmark", size: .small, accessibilityLabel: "移除图片") {
                                        vm.assemblyConfig.extraColorImagePaths.removeAll { $0 == path }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
            }

            if vm.showAdvancedSettings {
                SettingsCardGroup(title: "正文清洗与 CSS 样式") {
                    SettingsRow(title: "清理录入组/图源/修图声明", subtitle: "自动移除章节开头的扫图与录入信息头行") {
                        Toggle("", isOn: $vm.assemblyConfig.cleanCreditsHeader)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider()
                    SettingsRow(title: "段首缩进：\(String(format: "%.1f", vm.assemblyConfig.textIndentEm)) em", subtitle: "EPUB CSS text-indent") {
                        Slider(value: $vm.assemblyConfig.textIndentEm, in: 0...3, step: 0.5)
                            .frame(width: 200)
                    }

                    Divider()
                    SettingsRow(title: "正文行高：\(String(format: "%.2f", vm.assemblyConfig.lineHeight))", subtitle: "EPUB CSS line-height") {
                        Slider(value: $vm.assemblyConfig.lineHeight, in: 1.3...2.2, step: 0.05)
                            .frame(width: 200)
                    }

                    Divider()
                    SettingsRow(title: "段落间距：\(String(format: "%.2f", vm.assemblyConfig.paragraphSpacingEm)) em", subtitle: "段落底部间距") {
                        Slider(value: $vm.assemblyConfig.paragraphSpacingEm, in: 0...1.5, step: 0.1)
                            .frame(width: 200)
                    }
                }

                SettingsCardGroup(title: "元数据覆写与文件命名模板") {
                    VStack(alignment: .leading, spacing: 10) {
                        StudioSearchField(icon: "textformat", placeholder: "自定义书名（留空使用原书名）", text: $vm.assemblyConfig.customTitleOverride)
                        StudioSearchField(icon: "person", placeholder: "自定义作者（留空使用原作者）", text: $vm.assemblyConfig.customAuthorOverride)
                        StudioSearchField(icon: "doc.badge.gearshape", placeholder: "文件名模板（{title} {volume} {index} {author} {id}）", text: $vm.assemblyConfig.filenameTemplate)

                        HStack {
                            Text("命名预览")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(previewFilename).epub")
                                .font(.callout.monospaced())
                                .foregroundStyle(studioAccent)
                        }
                        .padding(.top, 2)

                        HStack {
                            StudioPillButton(title: "恢复默认拼装配置", systemImage: "arrow.counterclockwise", size: .small) {
                                vm.assemblyConfig = AssemblyConfig()
                                vm.savePersistedState()
                            }
                            Spacer()
                            StudioPillButton(title: "应用并保存拼装设置", systemImage: "checkmark.circle.fill", variant: .primary, size: .small) {
                                Task {
                                    await vm.syncClientSettings()
                                    vm.statusBanner = "设置与拼装参数已保存"
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - 6. 关于与更新 (About)

    private var aboutSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCardGroup(title: nil) {
                HStack(spacing: 16) {
                    appIconView(size: 62)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shiori")
                            .font(.title3.weight(.bold))
                        Text("版本 \(vm.appVersionDisplay) (\(vm.buildNumberDisplay))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("为 macOS 打造的轻小说多书源聚合阅读器与 EPUB 出版拼装工坊")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(16)

                Divider()

                SettingsRow(title: "GitHub 仓库", subtitle: "github.com/generalio/Shiori") {
                    StudioPillButton(title: "在浏览器中打开", systemImage: "safari", size: .small) {
                        if let url = URL(string: "https://github.com/generalio/Shiori") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }

            SettingsCardGroup(title: "更新") {
                SettingsRow(
                    title: "检查更新",
                    subtitle: vm.updateCheckStatus ?? "当前版本 \(vm.appVersionDisplay) (\(vm.buildNumberDisplay))"
                ) {
                    HStack(spacing: 8) {
                        if let releaseURL = vm.latestReleaseURL,
                           let tag = vm.latestReleaseTag,
                           (vm.updateCheckStatus ?? "").contains("发现新版本") {
                            StudioPillButton(title: "下载 \(tag)", systemImage: "arrow.down.circle.fill", variant: .primary, size: .small) {
                                if let url = URL(string: releaseURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        StudioPillButton(
                            title: "检查更新",
                            systemImage: "arrow.clockwise",
                            size: .small,
                            isLoading: vm.isCheckingUpdates,
                            isDisabled: vm.isCheckingUpdates
                        ) {
                            Task { await vm.checkForAppUpdates(silent: false) }
                        }
                    }
                }

                Divider()

                SettingsRow(title: "自动检查更新", subtitle: "启动应用时自动对比 GitHub Releases 最新版本") {
                    Toggle("", isOn: $vm.autoCheckUpdatesOnLaunch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: vm.autoCheckUpdatesOnLaunch) { _, _ in
                            vm.savePersistedState()
                        }
                }
            }

            SettingsCardGroup(title: "重置") {
                SettingsRow(
                    title: "恢复默认设置",
                    subtitle: "所有常规、外观主题、阅读器及 EPUB 拼装参数回到初始状态，不影响账号 Cookie 与书架记录"
                ) {
                    StudioPillButton(title: "恢复默认", systemImage: "arrow.counterclockwise", variant: .destructive, size: .small) {
                        vm.resetPreferencesToDefaults()
                    }
                }
            }
        }
    }

    // MARK: - 7. 书源平台配置 (Plugin Source)

    @ViewBuilder
    private func sourceSettingsContent(sourceId: String) -> some View {
        let plugin = vm.sourceRegistry.plugin(for: sourceId)
        let cfgBinding = Binding<SourceRuntimeConfig>(
            get: { vm.sourceConfig(for: sourceId) },
            set: { newVal in
                vm.updateSourceConfig(newVal)
                vm.savePersistedState()
            }
        )

        if let desc = plugin?.descriptor {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCardGroup(title: "插件信息与状态") {
                    HStack(spacing: 14) {
                        let sourceTint: Color = sourceId == "bilinovel" ? .pink : (sourceId == "copymanga" ? .teal : studioAccent)
                        let sourceIcon: String = sourceId == "bilinovel" ? "sparkles.rectangle.stack.fill" : (sourceId == "copymanga" ? "photo.stack.fill" : "books.vertical.fill")
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(sourceTint.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: sourceIcon)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(sourceTint)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(desc.displayName)
                                    .font(.headline)
                                StudioSourceBadge(title: desc.shortBadge, sourceId: desc.id)
                                Text(desc.requiresBrowserRuntime ? "WKWebView 浏览器运行时" : "原生 HTTP 运行时")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            Text(desc.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: cfgBinding.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                }

                SettingsCardGroup(title: "镜像地址与请求限速") {
                    SettingsRow(title: "主站与镜像域名", subtitle: "可在官方域名间快速切换或填写自定义镜像地址") {
                        VStack(alignment: .trailing, spacing: 8) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(desc.defaultMirrors, id: \.self) { mirror in
                                        let host = mirror.replacingOccurrences(of: "https://", with: "")
                                        StudioFilterChip(
                                            title: host,
                                            isSelected: cfgBinding.wrappedValue.baseURL.lowercased() == mirror.lowercased()
                                        ) {
                                            var updated = cfgBinding.wrappedValue
                                            updated.baseURL = mirror
                                            cfgBinding.wrappedValue = updated
                                        }
                                        .fixedSize()
                                    }
                                }
                            }
                            .frame(maxWidth: 420)
                            TextField("https://...", text: cfgBinding.baseURL)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 300)
                        }
                    }

                    Divider()

                    SettingsRow(title: "礼貌请求间隔", subtitle: "每次页面或章节抓取之间的最小间隔，降低触发风控概率") {
                        HStack(spacing: 10) {
                            Slider(value: cfgBinding.politeDelaySeconds, in: 0.0...4.0, step: 0.25)
                                .frame(width: 160)
                            Text(String(format: "%.2fs", cfgBinding.wrappedValue.politeDelaySeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }

                SettingsCardGroup(title: "会话验证、外部浏览器导入与传输引擎") {
                    SettingsRow(
                        title: "浏览器认证与 cURL / Token 导入",
                        subtitle: sourceId == "bilinovel"
                            ? "内置浏览器被 Cloudflare 拦截时，可在系统 Safari/Chrome 手动验证后一键粘贴 Copy as cURL 自动提取 Cookie 与 User-Agent"
                            : (sourceId == "copymanga"
                                ? "公开搜漫与看漫无需登录；如需同步个人云端书架，可导入浏览器 Authorization Token"
                                : "通过内置或系统浏览器登录并同步凭证")
                    ) {
                        HStack(spacing: 8) {
                            StudioPillButton(
                                title: sourceId == "copymanga" ? "导入 Token" : "登录 / 导入",
                                systemImage: "key.fill",
                                variant: .primary,
                                size: .small
                            ) {
                                vm.openWebLogin(for: sourceId)
                            }
                            .fixedSize()

                            StudioPillButton(
                                title: "浏览器打开",
                                systemImage: "safari",
                                size: .small
                            ) {
                                vm.openExternalBrowserForLogin(sourceId: sourceId)
                            }
                            .fixedSize()

                            StudioPillButton(
                                title: "检测连接",
                                systemImage: "checkmark.shield",
                                size: .small
                            ) {
                                vm.testSourceSession(sourceId: sourceId)
                            }
                            .fixedSize()

                            if !cfgBinding.wrappedValue.cookie.isEmpty || !cfgBinding.wrappedValue.authorizationToken.isEmpty {
                                StudioPillButton(
                                    title: "清空",
                                    systemImage: "trash",
                                    variant: .destructive,
                                    size: .small
                                ) {
                                    vm.clearSavedCookie(for: sourceId)
                                }
                            }
                        }
                    }

                    if sourceId == "bilinovel" {
                        Divider()

                        SettingsRow(
                            title: "网络传输引擎",
                            subtitle: "若导入 cf_clearance 后原生网络仍 403，可切换本地 Python curl_cffi 桥接以对齐真实浏览器 TLS 指纹"
                        ) {
                            HStack(spacing: 8) {
                                StudioSegmentedTabs(
                                    selection: cfgBinding.transportEngine,
                                    items: SourceTransportEngine.allCases,
                                    title: { $0 == .native ? "原生网络" : "Python curl_cffi" }
                                )
                                StudioPillButton(title: "检测环境", systemImage: "terminal", size: .small) {
                                    vm.detectCurlCFFIEnvironment(for: sourceId)
                                }
                            }
                        }

                        if cfgBinding.wrappedValue.transportEngine == .curlCFFI {
                            Divider()
                            SettingsRow(title: "自定义 Python 路径（可选）", subtitle: "留空则自动探测项目 .venv 及系统 Homebrew Python3") {
                                TextField("/opt/homebrew/bin/python3", text: cfgBinding.pythonExecutablePath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 260)
                            }
                        }

                        if let env = vm.curlCFFIStatus {
                            Divider()
                            HStack(spacing: 8) {
                                Image(systemName: env.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(env.isAvailable ? .green : .orange)
                                Text(env.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                    }

                    if desc.contentKind == .manga {
                        Divider()

                        SettingsRow(title: "图片 CDN 线路", subtitle: "根据当前网络环境切换海外或大陆加速线路") {
                            StudioSegmentedTabs(
                                selection: cfgBinding.cdnRegion,
                                items: ["1", "0"],
                                title: { $0 == "1" ? "海外线路 (1)" : "大陆线路 (0)" }
                            )
                        }

                        Divider()

                        SettingsRow(title: "优先高清画质（c1500x）", subtitle: "关闭时使用标准清晰度（c800x）以节省流量") {
                            Toggle("", isOn: cfgBinding.preferHighQualityImages)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }

                    if let msg = vm.perSourceVerifyMessage[sourceId], !msg.isEmpty {
                        let passed = vm.perSourceVerifyPassed[sourceId] == true
                        Divider()
                        HStack(spacing: 8) {
                            Image(systemName: passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(passed ? .green : .orange)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    if vm.showAdvancedSettings {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("User-Agent（导入 cURL 时会自动对齐浏览器 UA）")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField(HTTPRuntime.defaultUserAgent, text: cfgBinding.userAgent)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())

                            if desc.contentKind == .manga {
                                Text("Authorization Token（拷贝漫画个人收藏同步）")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                TextField("不含 Token 前缀的纯令牌或直接粘贴 Token ...", text: cfgBinding.authorizationToken)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption.monospaced())
                            } else {
                                Text("手动 Cookie（仅限当前书源）")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                TextEditor(text: cfgBinding.cookie)
                                    .font(.caption.monospaced())
                                    .frame(height: 62)
                                    .padding(6)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.8)
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
    }

    private func appIconView(size: CGFloat) -> some View {
        Group {
            if let nsImg = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: nsImg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(studioAccent.gradient)
                    .frame(width: size, height: size)
                    .overlay {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: size * 0.44, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .shadow(color: StudioTokens.cardShadowColor, radius: 6, y: 2)
    }

    private var previewFilename: String {
        let title = vm.assemblyConfig.customTitleOverride.isEmpty
            ? (vm.bookDetail?.title ?? "轻小说示例")
            : vm.assemblyConfig.customTitleOverride
        let author = vm.assemblyConfig.customAuthorOverride.isEmpty
            ? (vm.bookDetail?.author ?? "作者名")
            : vm.assemblyConfig.customAuthorOverride
        let bookId = vm.bookDetail?.bookId ?? "0000"
        return builder.renderFilename(
            template: vm.assemblyConfig.filenameTemplate,
            title: title,
            volume: vm.assemblyConfig.exportMode == .mergedSingle ? "合集" : "第一卷",
            index: 1,
            author: author,
            bookId: bookId
        )
    }
}

// MARK: - Settings Layout Helpers

private struct SettingsCategorySidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    var sourceEnabled: Bool? = nil
    let action: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? studioAccent : Color.secondary)
                    .frame(width: 18, height: 18)

                Text(category.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                if let sourceEnabled {
                    if sourceEnabled {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    } else {
                        Text("待启用")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? studioAccent.opacity(0.14)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous)
                        .strokeBorder(studioAccent.opacity(0.22), lineWidth: 0.8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct SettingsCardGroup<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .studioCard(cornerRadius: StudioTokens.cardRadius, padding: 0)
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
