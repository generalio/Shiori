import AppKit
import PDFKit
import SwiftUI
import Wenku8Core

private enum PDFDisplayLayoutMode: String, CaseIterable, Identifiable {
    case continuous = "连续滚动"
    case singlePage = "单页"
    case twoUp = "双页"

    var id: String { rawValue }

    var pdfDisplayMode: PDFDisplayMode {
        switch self {
        case .continuous: return .singlePageContinuous
        case .singlePage: return .singlePage
        case .twoUp: return .twoUpContinuous
        }
    }
}

private struct PDFOutlineRowItem: Identifiable {
    let id: String
    let label: String
    let pageIndex: Int
    let depth: Int
}

private struct PDFSearchMatchItem: Identifiable {
    let id: String
    let pageIndex: Int
    let snippet: String
    let selection: PDFSelection
}

struct PDFReaderView: View {
    @EnvironmentObject var vm: StudioViewModel
    let record: LocalBookRecord
    let initialPageIndex: Int

    @State private var showSidebar: Bool = true
    @State private var sidebarTab: SidebarTab = .outline
    @State private var layoutMode: PDFDisplayLayoutMode = .continuous
    @State private var currentPageIndex: Int = 0
    @State private var totalPages: Int = 0
    @State private var jumpToPageCommand: (page: Int, token: UUID)? = nil
    @State private var zoomCommand: (delta: CGFloat?, fitWidth: Bool, token: UUID)? = nil
    @State private var currentScalePercent: Int = 100
    @State private var outlineItems: [PDFOutlineRowItem] = []
    @State private var searchText: String = ""
    @State private var searchResults: [PDFSearchMatchItem] = []
    @State private var activeSelection: PDFSelection? = nil
    @State private var loadedDocument: PDFDocument? = nil
    @State private var loadErrorMessage: String? = nil

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case outline = "目录"
        case search = "搜索"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar && !vm.isFocusReadingMode {
                sidebarDrawer
                    .frame(width: 268)
                Divider()
            }

            VStack(spacing: 0) {
                if !vm.isFocusReadingMode {
                    toolbarBar
                    Divider()
                }

                if let err = loadErrorMessage {
                    missingOrBrokenView(err)
                } else {
                    ZStack(alignment: .bottom) {
                        pdfCanvasWithTheme

                        if vm.isFocusReadingMode {
                            focusFloatingControls
                                .padding(.bottom, 16)
                        } else if totalPages > 1 {
                            bottomPageBar
                                .padding(.horizontal, 18)
                                .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .onAppear {
            currentPageIndex = max(0, initialPageIndex)
            totalPages = max(record.pageCount, 0)
            loadDocumentMetadata()
        }
        .onChange(of: record.id) { _, _ in
            currentPageIndex = max(0, initialPageIndex)
            totalPages = max(record.pageCount, 0)
            searchText = ""
            searchResults = []
            activeSelection = nil
            loadDocumentMetadata()
        }
        .onChange(of: initialPageIndex) { _, newPage in
            jumpToPage(newPage)
        }
    }

    // MARK: - PDF Canvas + Theme Filters

    @ViewBuilder
    private var pdfCanvasWithTheme: some View {
        let baseCanvas = ShioriPDFKitRepresentable(
            fileURL: record.fileURL,
            initialPageIndex: initialPageIndex,
            layoutMode: layoutMode,
            jumpCommand: jumpToPageCommand,
            zoomCommand: zoomCommand,
            activeSelection: activeSelection,
            backgroundColor: nsBackgroundColor(for: vm.readerTheme),
            onPageChanged: { pageIdx, count in
                if totalPages != count {
                    totalPages = count
                }
                if currentPageIndex != pageIdx {
                    currentPageIndex = pageIdx
                    vm.updatePDFReadPage(bookId: record.id, pageIndex: pageIdx)
                }
            },
            onScaleChanged: { factor in
                currentScalePercent = max(25, min(500, Int(round(factor * 100))))
            }
        )

        ZStack {
            switch vm.readerTheme {
            case .paper:
                baseCanvas
            case .sepia:
                baseCanvas
                    .overlay {
                        Color(red: 0.94, green: 0.87, blue: 0.72)
                            .opacity(0.24)
                            .blendMode(.multiply)
                            .allowsHitTesting(false)
                    }
            case .green:
                baseCanvas
                    .overlay {
                        Color(red: 0.78, green: 0.90, blue: 0.78)
                            .opacity(0.25)
                            .blendMode(.multiply)
                            .allowsHitTesting(false)
                    }
            case .night:
                baseCanvas
                    .colorInvert()
                    .hueRotation(.degrees(180))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func nsBackgroundColor(for theme: ReaderTheme) -> NSColor {
        switch theme {
        case .paper: return NSColor.textBackgroundColor
        case .sepia: return NSColor(red: 0.95, green: 0.91, blue: 0.82, alpha: 1)
        case .green: return NSColor(red: 0.85, green: 0.92, blue: 0.86, alpha: 1)
        case .night: return NSColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
        }
    }

    // MARK: - Top Toolbar

    private var toolbarBar: some View {
        HStack(spacing: 10) {
            StudioCircleButton(
                systemImage: "sidebar.left",
                variant: showSidebar ? .primary : .secondary,
                size: .small,
                accessibilityLabel: "切换 PDF 目录与搜索侧栏"
            ) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSidebar.toggle()
                }
            }
            .help("显示/隐藏目录与搜索侧栏")

            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("PDF 原版渲染 · 第 \(min(totalPages, currentPageIndex + 1)) / \(max(1, totalPages)) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer()

            StudioSegmentedTabs(selection: $layoutMode, items: PDFDisplayLayoutMode.allCases)
                .frame(width: 210)

            HStack(spacing: 4) {
                StudioCircleButton(
                    systemImage: "minus.magnifyingglass",
                    variant: .secondary,
                    size: .small,
                    accessibilityLabel: "缩小"
                ) {
                    zoomCommand = (delta: -0.15, fitWidth: false, token: UUID())
                }
                .help("缩小")

                StudioPillButton(
                    title: "\(currentScalePercent)%",
                    variant: .subtle,
                    size: .small
                ) {
                    zoomCommand = (delta: nil, fitWidth: true, token: UUID())
                }
                .help("恢复自适应宽度")

                StudioCircleButton(
                    systemImage: "plus.magnifyingglass",
                    variant: .secondary,
                    size: .small,
                    accessibilityLabel: "放大"
                ) {
                    zoomCommand = (delta: 0.15, fitWidth: false, token: UUID())
                }
                .help("放大")
            }

            StudioCircleMenu(
                systemImage: themeIcon(vm.readerTheme),
                variant: .secondary,
                size: .small,
                header: "PDF 阅读纸张主题",
                accessibilityLabel: "切换 PDF 阅读主题",
                options: ReaderTheme.allCases.map { theme in
                    StudioMenuOption(
                        id: theme.rawValue,
                        title: theme.rawValue,
                        systemImage: themeIcon(theme),
                        isSelected: vm.readerTheme == theme
                    ) {
                        vm.readerTheme = theme
                        vm.savePersistedState()
                    }
                }
            )
            .help("切换阅读纸张主题（支持夜间反色）")

            if AppleBooksBridge.isAppleBooksInstalled {
                StudioCircleButton(
                    systemImage: "books.vertical",
                    variant: .secondary,
                    size: .small,
                    accessibilityLabel: "在 Apple Books 中打开"
                ) {
                    vm.sendFileToAppleBooks(record.filePath)
                }
                .help("发送到 Apple Books 打开")
            }

            StudioCircleButton(
                systemImage: "folder",
                variant: .secondary,
                size: .small,
                accessibilityLabel: "在 Finder 中显示原文件"
            ) {
                vm.revealInFinder(record.filePath)
            }
            .help("在 Finder 中显示原 PDF 文件")

            StudioCircleButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                variant: .secondary,
                size: .small,
                accessibilityLabel: "专注阅读模式"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    vm.isFocusReadingMode = true
                }
            }
            .help("进入专注阅读模式")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func themeIcon(_ theme: ReaderTheme) -> String {
        switch theme {
        case .paper: return "sun.max"
        case .sepia: return "doc.plaintext"
        case .green: return "leaf"
        case .night: return "moon.stars"
        }
    }

    // MARK: - Sidebar Drawer (Outline & Search)

    private var sidebarDrawer: some View {
        VStack(spacing: 0) {
            StudioSegmentedTabs(selection: $sidebarTab, items: SidebarTab.allCases)
                .padding(10)

            Divider()

            switch sidebarTab {
            case .outline:
                if outlineItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.indent")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("此 PDF 未包含内置书签大纲")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("可使用下方滑块或页码按钮快速跳转")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(outlineItems) { item in
                                let isActive = item.pageIndex == currentPageIndex
                                Button {
                                    jumpToPage(item.pageIndex)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(item.label)
                                            .font(.caption.weight(isActive ? .semibold : .regular))
                                            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 4)
                                        Text("\(item.pageIndex + 1)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.leading, CGFloat(min(item.depth, 4) * 12 + 10))
                                    .padding(.trailing, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        isActive ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                }

            case .search:
                VStack(spacing: 8) {
                    StudioSearchField(
                        icon: "magnifyingglass",
                        placeholder: "搜索 PDF 内文...",
                        text: $searchText,
                        onSubmit: { performPDFSearch() }
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .onChange(of: searchText) { _, newVal in
                        if newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            searchResults = []
                            activeSelection = nil
                        }
                    }

                    if searchResults.isEmpty {
                        Text(searchText.isEmpty ? "输入关键词后回车搜索 PDF 文本" : "未找到匹配文本（扫描版图片 PDF 不含可检索文字层）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(searchResults) { hit in
                                    Button {
                                        activeSelection = hit.selection
                                        jumpToPage(hit.pageIndex)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("第 \(hit.pageIndex + 1) 页")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                            Text(hit.snippet)
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Bottom Page Scrubber & Focus Floating Bar

    private var bottomPageBar: some View {
        HStack(spacing: 10) {
            StudioCircleButton(
                systemImage: "chevron.left",
                variant: .secondary,
                size: .small,
                isDisabled: currentPageIndex <= 0,
                accessibilityLabel: "上一页"
            ) {
                jumpToPage(max(0, currentPageIndex - 1))
            }

            Slider(
                value: Binding(
                    get: { Double(currentPageIndex) },
                    set: { jumpToPage(Int(round($0))) }
                ),
                in: 0...Double(max(1, totalPages - 1)),
                step: 1
            )
            .frame(maxWidth: 320)

            StudioCircleButton(
                systemImage: "chevron.right",
                variant: .secondary,
                size: .small,
                isDisabled: currentPageIndex >= totalPages - 1,
                accessibilityLabel: "下一页"
            ) {
                jumpToPage(min(totalPages - 1, currentPageIndex + 1))
            }

            Text("\(currentPageIndex + 1) / \(totalPages)")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 54, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .studioCard(cornerRadius: 14, padding: 0)
    }

    private var focusFloatingControls: some View {
        HStack(spacing: 10) {
            StudioCircleButton(
                systemImage: "chevron.left",
                variant: .secondary,
                size: .small,
                isDisabled: currentPageIndex <= 0,
                accessibilityLabel: "上一页"
            ) {
                jumpToPage(max(0, currentPageIndex - 1))
            }

            Text("第 \(currentPageIndex + 1) / \(max(1, totalPages)) 页")
                .font(.caption.monospacedDigit().weight(.medium))

            StudioCircleButton(
                systemImage: "chevron.right",
                variant: .secondary,
                size: .small,
                isDisabled: currentPageIndex >= totalPages - 1,
                accessibilityLabel: "下一页"
            ) {
                jumpToPage(min(totalPages - 1, currentPageIndex + 1))
            }

            StudioPillButton(title: "退出专注", systemImage: "arrow.down.right.and.arrow.up.left", size: .small) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    vm.isFocusReadingMode = false
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .studioCard(cornerRadius: 16, padding: 0)
    }

    private func missingOrBrokenView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text(message)
                .font(.headline)
            Text(record.filePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                StudioPillButton(title: "重新定位文件…", systemImage: "folder.badge.questionmark", variant: .primary) {
                    vm.relinkLocalBook(bookId: record.id)
                }
                StudioPillButton(title: "返回目录", systemImage: "arrow.left") {
                    vm.navigateToSection(.catalog)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Actions

    private func jumpToPage(_ index: Int) {
        let clamped = max(0, min(max(0, totalPages - 1), index))
        currentPageIndex = clamped
        jumpToPageCommand = (page: clamped, token: UUID())
    }

    private func loadDocumentMetadata() {
        let availability = AppleBooksBridge.fileAvailability(at: record.fileURL)
        if availability == .missing {
            loadErrorMessage = "原 PDF 文件已被移动或删除"
            loadedDocument = nil
            outlineItems = []
            return
        }
        if availability == .iCloudNotDownloaded {
            loadErrorMessage = "该 PDF 目前位于 iCloud 云端，请先下载到本地"
            loadedDocument = nil
            outlineItems = []
            return
        }
        guard let doc = PDFDocument(url: record.fileURL) else {
            loadErrorMessage = "无法解析该 PDF 文件"
            loadedDocument = nil
            outlineItems = []
            return
        }
        loadErrorMessage = nil
        loadedDocument = doc
        totalPages = doc.pageCount
        var items: [PDFOutlineRowItem] = []
        if let root = doc.outlineRoot {
            flattenOutline(root, in: doc, depth: -1, into: &items)
        }
        outlineItems = items
    }

    private func flattenOutline(_ outline: PDFOutline, in doc: PDFDocument, depth: Int, into results: inout [PDFOutlineRowItem]) {
        if depth >= 0 {
            let label = (outline.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pageIdx: Int? = {
                if let p = outline.destination?.page { return doc.index(for: p) }
                if let go = outline.action as? PDFActionGoTo, let p = go.destination.page { return doc.index(for: p) }
                return nil
            }()
            if !label.isEmpty, let pageIdx {
                results.append(
                    PDFOutlineRowItem(
                        id: "\(results.count)_\(pageIdx)_\(label)",
                        label: label,
                        pageIndex: pageIdx,
                        depth: depth
                    )
                )
            }
        }
        for i in 0..<outline.numberOfChildren {
            if let child = outline.child(at: i) {
                flattenOutline(child, in: doc, depth: depth + 1, into: &results)
            }
        }
    }

    private func performPDFSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let doc = loadedDocument else {
            searchResults = []
            return
        }
        let selections = doc.findString(q, withOptions: .caseInsensitive)
        searchResults = selections.prefix(120).enumerated().compactMap { idx, sel in
            guard let page = sel.pages.first else { return nil }
            let pIdx = doc.index(for: page)
            let extended = sel.copy() as? PDFSelection
            extended?.extend(atStart: 14)
            extended?.extend(atEnd: 28)
            let snippet = (extended?.string ?? sel.string ?? q)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFSearchMatchItem(
                id: "\(idx)_\(pIdx)",
                pageIndex: pIdx,
                snippet: snippet,
                selection: sel
            )
        }
    }
}

// MARK: - NSViewRepresentable Wrapper

private struct ShioriPDFKitRepresentable: NSViewRepresentable {
    let fileURL: URL
    let initialPageIndex: Int
    let layoutMode: PDFDisplayLayoutMode
    let jumpCommand: (page: Int, token: UUID)?
    let zoomCommand: (delta: CGFloat?, fitWidth: Bool, token: UUID)?
    let activeSelection: PDFSelection?
    let backgroundColor: NSColor
    let onPageChanged: (Int, Int) -> Void
    let onScaleChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChanged: onPageChanged, onScaleChanged: onScaleChanged)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = layoutMode.pdfDisplayMode
        pdfView.displaysPageBreaks = true
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = backgroundColor
        context.coordinator.attach(to: pdfView)
        loadDocumentIfNeeded(into: pdfView, coordinator: context.coordinator)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onScaleChanged = onScaleChanged

        if pdfView.backgroundColor != backgroundColor {
            pdfView.backgroundColor = backgroundColor
        }
        if pdfView.displayMode != layoutMode.pdfDisplayMode {
            pdfView.displayMode = layoutMode.pdfDisplayMode
        }

        loadDocumentIfNeeded(into: pdfView, coordinator: context.coordinator)

        if let cmd = jumpCommand, cmd.token != context.coordinator.lastJumpToken {
            context.coordinator.lastJumpToken = cmd.token
            if let doc = pdfView.document,
               cmd.page >= 0 && cmd.page < doc.pageCount,
               let page = doc.page(at: cmd.page) {
                pdfView.go(to: page)
            }
        }

        if let z = zoomCommand, z.token != context.coordinator.lastZoomToken {
            context.coordinator.lastZoomToken = z.token
            if z.fitWidth {
                pdfView.autoScales = true
            } else if let delta = z.delta {
                pdfView.autoScales = false
                let nextScale = max(0.25, min(5.0, pdfView.scaleFactor + delta))
                pdfView.scaleFactor = nextScale
            }
            onScaleChanged(pdfView.scaleFactor)
        }

        if let sel = activeSelection, sel !== context.coordinator.lastSelection {
            context.coordinator.lastSelection = sel
            pdfView.setCurrentSelection(sel, animate: true)
            pdfView.go(to: sel)
        }
    }

    private func loadDocumentIfNeeded(into pdfView: PDFView, coordinator: Coordinator) {
        guard coordinator.loadedURL != fileURL else { return }
        coordinator.loadedURL = fileURL
        if let doc = PDFDocument(url: fileURL) {
            pdfView.document = doc
            pdfView.autoScales = true
            let clamped = max(0, min(max(0, doc.pageCount - 1), initialPageIndex))
            if let page = doc.page(at: clamped) {
                pdfView.go(to: page)
            }
            DispatchQueue.main.async {
                coordinator.onPageChanged(clamped, doc.pageCount)
                coordinator.onScaleChanged(pdfView.scaleFactor)
            }
        }
    }

    final class Coordinator: NSObject {
        var loadedURL: URL?
        var lastJumpToken: UUID?
        var lastZoomToken: UUID?
        var lastSelection: PDFSelection?
        var onPageChanged: (Int, Int) -> Void
        var onScaleChanged: (CGFloat) -> Void
        private weak var observedView: PDFView?

        init(onPageChanged: @escaping (Int, Int) -> Void, onScaleChanged: @escaping (CGFloat) -> Void) {
            self.onPageChanged = onPageChanged
            self.onScaleChanged = onScaleChanged
        }

        func attach(to pdfView: PDFView) {
            observedView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged(_:)),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScaleChanged(_:)),
                name: Notification.Name.PDFViewScaleChanged,
                object: pdfView
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handlePageChanged(_ notification: Notification) {
            guard let view = observedView,
                  let doc = view.document,
                  let currentPage = view.currentPage else { return }
            let idx = doc.index(for: currentPage)
            DispatchQueue.main.async { [weak self] in
                self?.onPageChanged(idx, doc.pageCount)
            }
        }

        @objc private func handleScaleChanged(_ notification: Notification) {
            guard let view = observedView else { return }
            let scale = view.scaleFactor
            DispatchQueue.main.async { [weak self] in
                self?.onScaleChanged(scale)
            }
        }
    }
}
