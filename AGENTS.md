# Repository Guidelines & UI Component Specifications

This repository contains **lightnovel-download** (Python CLI + core EPUB builder) and **Shiori** (native macOS SwiftUI client targeting macOS `26.0`, built on `Wenku8Core` + `Wenku8Studio`).

---

## 1. Repository Layout & Build Commands

- `Wenku8Studio/project.yml` — XcodeGen project specification (`Wenku8Core`, `Wenku8Studio` producing `Shiori.app`, `Wenku8CoreTests`). Always re-run `xcodegen generate` inside `Wenku8Studio/` after adding or removing `.swift` files.
- `Wenku8Studio/Sources/Wenku8Core/` — `BookSourceKit` SPI, `SourceAggregationEngine` (`SourceRegistry`, `AggregatedSearchEngine`), `Plugins/` (`Wenku8Plugin`, hot-pluggable `BilinovelPlugin`), HTML/metadata parsing, Cloud Bookcase & cookie handling, EPUB packaging.
- `Wenku8Studio/Sources/Wenku8Studio/` — SwiftUI app, `StudioViewModel.swift`, `Services/` (`CoverThumbnailCache`, `WebKitFetchService`), and UI views under `Views/`.
- `lightnovel.py`, `Editer.py`, `utils.py` — Python CLI and EPUB processing utilities.
- `tests/test_core.py` — Python core unit tests.

### Standard Build & Verification Commands

```bash
# 1. Regenerate Xcode project & run macOS unit tests
(cd Wenku8Studio && xcodegen generate) && \
  xcodebuild test -project Wenku8Studio/Wenku8Studio.xcodeproj -scheme Wenku8Studio -destination 'platform=macOS'

# 2. Build standalone Shiori.app bundle (gitignored build artifact)
./Wenku8Studio/build_app.sh

# 3. Run Python core tests
.venv/bin/python -m pytest -v tests/test_core.py
```

### Toolchain & Git Constraints

- **No `.metal` files**: The local Xcode environment does not include the standalone Metal Toolchain; prefer GPU-backed CoreImage filters (e.g., `CIPageCurlWithShadowTransition` in `SimulationPageReaderView.swift`) and native SwiftUI animations.
- **No build artifacts in git**: Never commit `Shiori.app`, `ShioriStudio.app`, `Wenku8Studio.app`, `.build`, or `.build_xcode`.
- **macOS App Icon Spec**: Assets in `Wenku8Studio/AppResources/Assets.xcassets/AppIcon.appiconset/` must keep transparent outer canvas padding (`824/1024` inner tile ratio) with a `.continuous` squircle (`22.5%` corner radius of inner tile) and subtle drop shadow per macOS HIG. Keep `icon_raw.png` intact as the full-bleed source artwork.

---

## 2. Wenku8Studio UI Design System (`DesignSystem.swift`)

All interactive controls, navigation tabs, segmented switches, filter chips, search bars, and card containers **must** use the custom components in `Wenku8Studio/Sources/Wenku8Studio/Views/DesignSystem.swift`.  
**Do NOT** scatter stock `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, `.buttonStyle(.bordered)`, `.pickerStyle(.segmented)`, or `GlassEffectContainer` in feature views.

### 2.1 Design Tokens (`StudioTokens`)

- `StudioTokens.cardRadius` (`14`) — Standard floating toolbars and cards.
- `StudioTokens.panelRadius` (`16`) — Prominent feature containers.
- `StudioTokens.cardRadiusLarge` (`18`) — Bottom action bars and hero summary cards.
- `StudioTokens.sidebarRowRadius` (`10`) — Sidebar navigation tab highlight radius.
- `StudioTokens.pagePadding` (`20`) / `StudioTokens.cardPadding` (`14`)
- `StudioTokens.buttonShadowColor` / `StudioTokens.cardShadowColor` / `StudioTokens.floatingShadowColor`
- `StudioTokens.hairlineStroke` — Subtle `1px`-weight hairline border (`Color.primary.opacity(0.09)`).
- `StudioTokens.controlBackground` — Adaptive elevated control fill (`Color(nsColor: .controlBackgroundColor).opacity(0.86)`).

### 2.2 Standard Sizes & Variants & Theme Environment

- `StudioButtonVariant`: `.primary` (accent gradient + white text), `.secondary` (elevated surface + hairline + shadow), `.subtle` (transparent until hover), `.destructive` (tinted red).
- `StudioControlSize`: `.small` (26pt circle / compact capsule), `.regular` (32pt circle / standard capsule), `.large` (40pt circle / prominent CTA).
- Theme Propagation: `EnvironmentValues.studioAccentColor` propagates the user's chosen `AppAccentTheme` alongside `.tint(...)` and `.preferredColorScheme(...)` set at `ContentView`. Use `@Environment(\.studioAccentColor)` inside custom interactive controls in `DesignSystem.swift` instead of hardcoding `Color.accentColor`.

### 2.3 Component Usage Guide

| Component | Purpose | Usage Rule |
| :--- | :--- | :--- |
| `StudioCircleButton` | Circular icon-only toolbar & card actions (Back `<`, Forward `>`, Refresh, Settings, Zoom, Close, Bookmark icon) | Features elevated circle fill, hairline stroke, soft drop shadow, hover scale (`1.04`), and press feedback (`0.93`). Always provide `accessibilityLabel` and `.help(...)`. |
| `StudioCircleMenu` | Circular dropdown trigger (e.g. `chevron.down` card group switcher) | Built on `StudioCircleButton` + `.popover` menu list (`StudioMenuOption`), eliminating macOS stock `Menu` disclosure arrow overlap. |
| `StudioPillButton` | Primary CTAs, text+icon actions, pagination, task controls | Capsule shape with optional leading SF Symbol, `isLoading` spinner state, and `isDisabled` handling. Use `.primary` sparingly for the main CTA in a bar. |
| `StudioSegmentedTabs` | View-mode / scope / interval switches | Works with any `Hashable` item array (`init(selection:items:)` shorthand for `RawRepresentable where RawValue == String`, or explicit `title:` closure). Uses animated `matchedGeometryEffect` pill indicator. |
| `StudioFilterChip` | Quick channels, tag toggles, compact hero toolbar actions | Soft tinted active state when `isSelected == true`, elevated neutral capsule otherwise. |
| `StudioSearchField` | Global top search bar, filter inputs, form text boxes with icons | Includes leading icon focus tint, inline clear (`xmark.circle.fill`) button, optional `shortcutHint` badge (e.g. `"⌘K"`), and `focusTrigger` binding. |
| `StudioNavTabRow` | Left sidebar navigation tabs | Apple Music-inspired rounded row (`sidebarRowRadius`), monochrome SF Symbol, accent highlight pill when active, hover fill, and optional count badge / busy indicator. |
| `.studioCard(...)` | Card surfaces, banners, floating reader toolbars | `View.studioCard(cornerRadius:padding:tint:)` applies `.regularMaterial` + optional soft tint + `hairlineStroke` border + `cardShadowColor` shadow. |

---

## 3. Navigation Stack & Startup Rules

- **Default Startup State**: By default `startupSection` is `.discovery` (`SidebarSection.discovery`) with an empty `bookInput` (`""`). Do **not** auto-load any hardcoded sample book ID on launch.
- **History Stack Compliance**: Never mutate `vm.selectedSection = ...` directly from SwiftUI views. Always go through:
  - `vm.navigateToSection(_:recordNavigation:)` or `vm.navigateToSettingsCategory(_:)` for sidebar/button/menu section switches,
  - `vm.loadBook(...)` / `vm.loadAuthorWorks(...)` for catalog & search navigation,
  - `vm.openChapterInReader(...)` / `vm.openBookmarkChapter(...)` for reader jumps,
  - `vm.goBack()` (`⌘[`) and `vm.goForward()` (`⌘]`) bound to top-bar `StudioCircleButton` controls,
  - macOS top-left Application Menu `.commands` in `Wenku8StudioApp.swift` (`关于 Wenku8 Studio`, `检查更新…`, `设置… ⌘,`).
- `StudioViewModel` maintains in-memory `bookDetailCache` and `chapterContentCache` so Back/Forward navigation restores previously viewed books and chapters quickly.

---

## 4. Illustration Lightbox & Contrast Rules

- **Zero Black Borders (`ReaderImageLightboxView`)**: Size the preview modal dynamically to match the artwork's aspect ratio (`fittedModalSize` within `460×380` to `980×760`), render the image edge-to-edge without outer border padding, and fill any remaining backdrop with a blurred, `.regularMaterial`-veiled extension of the current illustration rather than a black box.
- **Adaptive HUD Legibility**: Floating HUD pills over illustrations (such as `"插图预览 X / Y"`) must use adaptive `.primary` foreground text on `.regularMaterial` with `StudioTokens.hairlineStroke` and shadow—never hardcoded `.white` text over translucent glass.
