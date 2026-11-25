import AppKit
import SwiftUI
import Wenku8Core

/// Native manga reader supporting seamless vertical Webtoon scrolling and single-page RTL/LTR
/// reading backed by `StudioViewModel`'s bounded sliding-window `BoundedReaderImageCache`.
struct MangaReaderView: View {
    @EnvironmentObject var vm: StudioViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: ChapterContent
    let onPreviousChapter: () -> Void
    let onNextChapter: () -> Void

    @State private var currentPageIndex: Int = 0
    @State private var pageTurnForward: Bool = true
    @State private var zoomScale: Double = 1.0

    private var pages: [String] {
        content.imageURLs
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .underPageBackgroundColor)
                .ignoresSafeArea()

            if pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("当前章节暂无可显示的漫画图片")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.mangaReadingMode == .webtoon {
                webtoonScrollBody
            } else {
                singlePageBody
            }

            if !pages.isEmpty && !vm.isFocusReadingMode {
                floatingMangaHUD
            }
        }
        .onAppear {
            currentPageIndex = 0
            vm.ensureMangaPageWindowLoaded(currentIndex: 0, in: content)
        }
        .onChange(of: content.chapter.id) { _, _ in
            currentPageIndex = 0
            zoomScale = 1.0
            vm.ensureMangaPageWindowLoaded(currentIndex: 0, in: content)
        }
    }

    // MARK: - Webtoon Continuous Vertical Mode

    private var webtoonScrollBody: some View {
        GeometryReader { geo in
            let maxDisplayWidth = max(320, min(geo.size.width - 24, 960) * zoomScale)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, url in
                        mangaPageSlot(index: idx, url: url, containerWidth: maxDisplayWidth, containerHeight: geo.size.height)
                            .onAppear {
                                currentPageIndex = idx
                                vm.ensureMangaPageWindowLoaded(currentIndex: idx, in: content)
                            }
                    }

                    chapterEndNavigationFooter
                        .padding(.vertical, 28)
                        .padding(.bottom, 64)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectHidden(true, for: .all)
        }
    }

    // MARK: - Single-Page Mode (RTL / LTR)

    private var singlePageBody: some View {
        GeometryReader { geo in
            let safeIdx = min(max(0, currentPageIndex), max(0, pages.count - 1))
            let url = pages[safeIdx]
            let slideToLeft = (vm.mangaReadingDirection == .ltr) ? pageTurnForward : !pageTurnForward
            let pageTransition: AnyTransition = reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: slideToLeft ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: slideToLeft ? .leading : .trailing).combined(with: .opacity)
                )

            ZStack {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    ZStack {
                        mangaPageSlot(
                            index: safeIdx,
                            url: url,
                            containerWidth: max(320, (geo.size.width - 32) * zoomScale),
                            containerHeight: max(360, (geo.size.height - 84) * zoomScale)
                        )
                        .id("\(content.chapter.id)_\(safeIdx)")
                        .transition(pageTransition)
                    }
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height - 64)
                    .animation(StudioMotion.animation(StudioMotion.page, reduceMotion: reduceMotion), value: safeIdx)
                }

                // Transparent left/right tap zones respecting RTL/LTR reading direction
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if vm.mangaReadingDirection == .rtl {
                                stepForward()
                            } else {
                                stepBackward()
                            }
                        }
                    Color.clear
                        .frame(width: geo.size.width * 0.34)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if vm.mangaReadingDirection == .rtl {
                                stepBackward()
                            } else {
                                stepForward()
                            }
                        }
                }
            }
            .onChange(of: currentPageIndex) { _, newIdx in
                vm.ensureMangaPageWindowLoaded(currentIndex: newIdx, in: content)
            }
        }
    }

    // MARK: - Page Slot Renderer

    @ViewBuilder
    private func mangaPageSlot(index: Int, url: String, containerWidth: CGFloat, containerHeight: CGFloat) -> some View {
        if let nsImg = vm.mangaLoadedImages[url] ?? vm.readerImageCache.image(forKey: url) {
            let aspect = nsImg.size.height > 0 ? (nsImg.size.width / nsImg.size.height) : 0.7
            let imgView = Image(nsImage: nsImg)
                .resizable()
                .interpolation(.high)

            switch vm.mangaFitMode {
            case .fitWidth:
                imgView
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(width: containerWidth)
                    .transition(.opacity)
            case .fitPage:
                imgView
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: containerWidth, maxHeight: containerHeight)
                    .transition(.opacity)
            case .original:
                Image(nsImage: nsImg)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        } else if vm.mangaFailedImageURLs.contains(url) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("第 \(index + 1) 页加载失败")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                StudioPillButton(title: "重试本页", systemImage: "arrow.clockwise", size: .small) {
                    vm.retryMangaPage(url: url, in: content)
                }
            }
            .frame(width: containerWidth, height: 320)
            .background(Color.secondary.opacity(0.08))
        } else {
            ZStack {
                StudioBreathingPlaceholder(cornerRadius: 6, iconName: "photo.stack.fill")
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载第 \(index + 1) / \(pages.count) 页...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 56)
            }
            .frame(width: containerWidth, height: 360)
        }
    }

    // MARK: - Floating HUD & Chapter Footer

    private var floatingMangaHUD: some View {
        HStack(spacing: 12) {
            StudioCircleButton(systemImage: "chevron.left", size: .small, accessibilityLabel: "上一页/上一话") {
                if vm.mangaReadingMode == .singlePage {
                    vm.mangaReadingDirection == .rtl ? stepForward() : stepBackward()
                } else {
                    onPreviousChapter()
                }
            }

            Text("第 \(min(currentPageIndex + 1, pages.count)) / \(pages.count) 页")
                .font(.caption.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .frame(minWidth: 82)
                .animation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion), value: currentPageIndex)

            if vm.mangaReadingMode == .singlePage && pages.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentPageIndex) },
                        set: { newVal in
                            let target = min(max(0, Int(newVal.rounded())), pages.count - 1)
                            pageTurnForward = target >= currentPageIndex
                            currentPageIndex = target
                        }
                    ),
                    in: 0...Double(max(1, pages.count - 1)),
                    step: 1
                )
                .frame(width: 160)
            }

            HStack(spacing: 4) {
                StudioCircleButton(systemImage: "minus.magnifyingglass", size: .small, isDisabled: zoomScale <= 0.6, accessibilityLabel: "缩小") {
                    withAnimation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion)) {
                        zoomScale = max(0.6, zoomScale - 0.15)
                    }
                }
                Text("\(Int(zoomScale * 100))%")
                    .font(.caption2.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
                    .frame(width: 38)
                StudioCircleButton(systemImage: "plus.magnifyingglass", size: .small, isDisabled: zoomScale >= 2.0, accessibilityLabel: "放大") {
                    withAnimation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion)) {
                        zoomScale = min(2.0, zoomScale + 0.15)
                    }
                }
            }

            StudioCircleButton(systemImage: "chevron.right", size: .small, accessibilityLabel: "下一页/下一话") {
                if vm.mangaReadingMode == .singlePage {
                    vm.mangaReadingDirection == .rtl ? stepBackward() : stepForward()
                } else {
                    onNextChapter()
                }
            }
        }
        .studioCard(cornerRadius: StudioTokens.cardRadiusLarge, padding: 10)
        .padding(.bottom, 14)
    }

    private var chapterEndNavigationFooter: some View {
        HStack(spacing: 12) {
            StudioPillButton(title: "上一话", systemImage: "chevron.left", size: .regular, isDisabled: vm.adjacentChapter(offset: -1) == nil) {
                onPreviousChapter()
            }
            StudioPillButton(title: "下一话", systemImage: "chevron.right", variant: .primary, size: .regular, isDisabled: vm.adjacentChapter(offset: 1) == nil) {
                onNextChapter()
            }
        }
    }

    private func stepForward() {
        if currentPageIndex + 1 < pages.count {
            pageTurnForward = true
            withAnimation(StudioMotion.animation(StudioMotion.page, reduceMotion: reduceMotion)) {
                currentPageIndex += 1
            }
        } else if vm.adjacentChapter(offset: 1) != nil {
            onNextChapter()
        }
    }

    private func stepBackward() {
        if currentPageIndex > 0 {
            pageTurnForward = false
            withAnimation(StudioMotion.animation(StudioMotion.page, reduceMotion: reduceMotion)) {
                currentPageIndex -= 1
            }
        } else if vm.adjacentChapter(offset: -1) != nil {
            onPreviousChapter()
        }
    }
}
