import SwiftUI

// MARK: - Environment Theme Key

private struct StudioAccentColorKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var studioAccentColor: Color {
        get { self[StudioAccentColorKey.self] }
        set { self[StudioAccentColorKey.self] = newValue }
    }
}

// MARK: - Motion Tokens (macOS Native, Reduce-Motion Safe)

enum StudioMotion {
    /// Fast tactile feedback (hover, button press, icon bounce)
    static let micro: Animation = .snappy(duration: 0.14)
    /// Standard spring for structural transitions (sidebar pill, banners, foldouts, chips)
    static let standard: Animation = .spring(response: 0.26, dampingFraction: 0.86)
    /// Smooth cross-dissolve / directional slide for workspace & page transitions
    static let page: Animation = .smooth(duration: 0.20)
    /// Soft fade-in when async covers or manga pages finish decoding
    static let imageFade: Animation = .easeOut(duration: 0.18)

    static func animation(_ preferred: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? .easeInOut(duration: 0.08) : preferred
    }
}

/// Lightweight static placeholder surface (zero continuous per-cell timer/animation ticks).
struct StudioBreathingPlaceholder: View {
    var cornerRadius: CGFloat = 8
    var iconName: String = "book.closed.fill"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.13))
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary.opacity(0.55))
        }
    }
}

// MARK: - Design Tokens

enum StudioTokens {
    static let cardRadius: CGFloat = 14
    static let panelRadius: CGFloat = 16
    static let cardRadiusLarge: CGFloat = 18
    static let sidebarRowRadius: CGFloat = 10
    static let pagePadding: CGFloat = 20
    static let cardPadding: CGFloat = 14

    static let buttonShadowColor = Color.black.opacity(0.13)
    static let cardShadowColor = Color.black.opacity(0.07)
    static let floatingShadowColor = Color.black.opacity(0.18)
    static let hairlineStroke = Color.primary.opacity(0.09)
    static let controlBackground = Color(nsColor: .controlBackgroundColor).opacity(0.86)
}

enum StudioButtonVariant {
    case primary
    case secondary
    case subtle
    case destructive
}

enum StudioControlSize {
    case small
    case regular
    case large

    var circleDiameter: CGFloat {
        switch self {
        case .small: return 26
        case .regular: return 32
        case .large: return 40
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 10
        case .regular: return 14
        case .large: return 18
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: return 5
        case .regular: return 7
        case .large: return 9
        }
    }

    var font: Font {
        switch self {
        case .small: return .caption.weight(.medium)
        case .regular: return .callout.weight(.medium)
        case .large: return .callout.weight(.semibold)
        }
    }
}

// MARK: - Press Scale ButtonStyle (Scroll-Safe)

struct StudioPressScaleStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.95
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!isDisabled && configuration.isPressed ? pressedScale : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Circular Shadow Icon Button

struct StudioCircleButton: View {
    let systemImage: String
    var variant: StudioButtonVariant = .secondary
    var size: StudioControlSize = .regular
    var isLoading: Bool = false
    var spinIconWhenLoading: Bool = false
    var bounceTrigger: Bool? = nil
    var isDisabled: Bool = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var diameter: CGFloat { size.circleDiameter }

    var body: some View {
        Button {
            guard !isDisabled && !isLoading else { return }
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(backgroundFill)
                    .shadow(
                        color: shadowColor,
                        radius: 4.5,
                        x: 0,
                        y: 2
                    )
                    .overlay {
                        Circle()
                            .strokeBorder(borderColor, lineWidth: 0.9)
                    }

                if isLoading && !spinIconWhenLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                } else {
                    let baseIcon = Image(systemName: systemImage)
                        .font(.system(size: iconFontSize, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                        .contentTransition(.symbolEffect(.replace))
                    if spinIconWhenLoading {
                        baseIcon
                            .symbolEffect(.rotate, options: .repeating, isActive: isLoading && !reduceMotion)
                    } else if let bounceTrigger {
                        baseIcon
                            .symbolEffect(.bounce, value: reduceMotion ? false : bounceTrigger)
                    } else {
                        baseIcon
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(isHovered && !isDisabled && !reduceMotion ? 1.04 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(StudioPressScaleStyle(pressedScale: reduceMotion ? 1.0 : 0.93, isDisabled: isDisabled))
        .disabled(isDisabled || isLoading)
        .onHover { hovering in
            withAnimation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .accessibilityLabel(accessibilityLabel ?? systemImage)
    }

    private var iconFontSize: CGFloat {
        switch size {
        case .small: return 11
        case .regular: return 13
        case .large: return 16
        }
    }

    private var backgroundFill: AnyShapeStyle {
        if isDisabled {
            return AnyShapeStyle(Color.primary.opacity(0.075))
        }
        switch variant {
        case .primary:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [studioAccent, studioAccent.opacity(0.84)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .secondary:
            return AnyShapeStyle(
                isHovered
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.86)
            )
        case .subtle:
            return AnyShapeStyle(
                isHovered
                    ? Color.primary.opacity(0.08)
                    : Color.clear
            )
        case .destructive:
            return AnyShapeStyle(
                isHovered
                    ? Color.red.opacity(0.16)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.82)
            )
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return Color.primary.opacity(0.42)
        }
        switch variant {
        case .primary: return .white
        case .secondary: return .primary
        case .subtle: return isHovered ? .primary : .secondary
        case .destructive: return .red
        }
    }

    private var borderColor: Color {
        if isDisabled {
            return variant == .subtle ? .clear : StudioTokens.hairlineStroke
        }
        switch variant {
        case .primary: return Color.white.opacity(0.22)
        case .secondary: return StudioTokens.hairlineStroke
        case .subtle: return isHovered ? StudioTokens.hairlineStroke : .clear
        case .destructive: return Color.red.opacity(0.22)
        }
    }

    private var shadowColor: Color {
        if isDisabled { return .clear }
        switch variant {
        case .primary: return studioAccent.opacity(0.28)
        case .secondary, .destructive: return StudioTokens.buttonShadowColor
        case .subtle: return .clear
        }
    }
}

// MARK: - Capsule Action Button

struct StudioPillButton: View {
    let title: String
    var systemImage: String? = nil
    var variant: StudioButtonVariant = .secondary
    var size: StudioControlSize = .regular
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !isDisabled && !isLoading else { return }
            action()
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(size.font)
                }
                if !title.isEmpty {
                    Text(title)
                        .font(size.font)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background {
                Capsule()
                    .fill(backgroundFill)
                    .shadow(
                        color: shadowColor,
                        radius: 4,
                        x: 0,
                        y: 1.5
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 0.9)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(StudioPressScaleStyle(pressedScale: 0.97, isDisabled: isDisabled))
        .disabled(isDisabled || isLoading)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var backgroundFill: AnyShapeStyle {
        if isDisabled {
            return AnyShapeStyle(Color.primary.opacity(0.075))
        }
        switch variant {
        case .primary:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [studioAccent, studioAccent.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .secondary:
            return AnyShapeStyle(
                isHovered
                    ? Color(nsColor: .controlBackgroundColor)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.84)
            )
        case .subtle:
            return AnyShapeStyle(
                isHovered
                    ? Color.primary.opacity(0.08)
                    : Color.primary.opacity(0.03)
            )
        case .destructive:
            return AnyShapeStyle(
                isHovered
                    ? Color.red.opacity(0.18)
                    : Color.red.opacity(0.10)
            )
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return Color.primary.opacity(0.45)
        }
        switch variant {
        case .primary: return .white
        case .secondary: return .primary
        case .subtle: return .primary
        case .destructive: return .red
        }
    }

    private var borderColor: Color {
        if isDisabled {
            return StudioTokens.hairlineStroke
        }
        switch variant {
        case .primary: return Color.white.opacity(0.20)
        case .secondary: return StudioTokens.hairlineStroke
        case .subtle: return Color.primary.opacity(0.06)
        case .destructive: return Color.red.opacity(0.22)
        }
    }

    private var shadowColor: Color {
        if isDisabled { return .clear }
        switch variant {
        case .primary: return studioAccent.opacity(0.26)
        case .secondary: return StudioTokens.buttonShadowColor
        case .subtle, .destructive: return .clear
        }
    }
}

// MARK: - Custom Animated Segmented Tabs

struct StudioSegmentedTabs<SelectionValue: Hashable>: View {
    @Binding var selection: SelectionValue
    let items: [SelectionValue]
    let titleProvider: (SelectionValue) -> String

    @Namespace private var indicatorNamespace
    @State private var hoveredItem: SelectionValue?

    init(
        selection: Binding<SelectionValue>,
        items: [SelectionValue],
        title: @escaping (SelectionValue) -> String
    ) {
        self._selection = selection
        self.items = items
        self.titleProvider = title
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                let isHovered = hoveredItem == item
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selection = item
                    }
                } label: {
                    Text(titleProvider(item))
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.primary : (isHovered ? Color.primary : Color.secondary))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(StudioTokens.hairlineStroke, lineWidth: 0.7)
                                    }
                                    .shadow(color: Color.black.opacity(0.09), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "StudioTabPill", in: indicatorNamespace)
                            } else if isHovered {
                                Capsule()
                                    .fill(Color.primary.opacity(0.05))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredItem = hovering ? item : (hoveredItem == item ? nil : hoveredItem)
                }
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
        }
    }
}

extension StudioSegmentedTabs where SelectionValue: RawRepresentable, SelectionValue.RawValue == String {
    init(selection: Binding<SelectionValue>, items: [SelectionValue]) {
        self.init(selection: selection, items: items, title: { $0.rawValue })
    }
}

// MARK: - Filter / Channel Capsule Chip

struct StudioFilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isSelected: Bool
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @State private var isHovered = false

    private var effectiveTint: Color { tint ?? studioAccent }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                }
                Text(title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? effectiveTint : (isHovered ? Color.primary : Color.primary.opacity(0.84)))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(
                        isSelected
                            ? effectiveTint.opacity(0.15)
                            : (isHovered ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .controlBackgroundColor).opacity(0.76))
                    )
                    .shadow(
                        color: isSelected ? effectiveTint.opacity(0.12) : StudioTokens.cardShadowColor,
                        radius: 3.5,
                        y: 1.5
                    )
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? effectiveTint.opacity(0.38) : StudioTokens.hairlineStroke,
                        lineWidth: isSelected ? 1.0 : 0.8
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Capsule Search / Input Field

struct StudioSearchField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var shortcutHint: String? = nil
    var focusTrigger: Binding<Bool>? = nil
    var onSubmit: (() -> Void)? = nil

    @Environment(\.studioAccentColor) private var studioAccent
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isFocused ? studioAccent : Color.secondary)
                .font(.callout)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if let shortcutHint, !isFocused {
                Text(shortcutHint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.86), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(
                    isFocused ? studioAccent.opacity(0.55) : StudioTokens.hairlineStroke,
                    lineWidth: isFocused ? 1.2 : 0.9
                )
        }
        .shadow(color: StudioTokens.cardShadowColor, radius: 4, y: 1.5)
        .onChange(of: focusTrigger?.wrappedValue ?? false) { _, shouldFocus in
            if shouldFocus {
                isFocused = true
                DispatchQueue.main.async {
                    focusTrigger?.wrappedValue = false
                }
            }
        }
    }
}

// MARK: - Sidebar Navigation Tab Row (Apple Music / Modern macOS Style)

struct StudioNavTabRow: View, Equatable {
    let section: SidebarSection
    let isSelected: Bool
    let badgeCount: Int
    let isBusy: Bool
    var selectionNamespace: Namespace.ID? = nil
    let onSelect: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    static func == (lhs: StudioNavTabRow, rhs: StudioNavTabRow) -> Bool {
        lhs.section == rhs.section &&
        lhs.isSelected == rhs.isSelected &&
        lhs.badgeCount == rhs.badgeCount &&
        lhs.isBusy == rhs.isBusy
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? studioAccent : Color.secondary)
                    .frame(width: 20, height: 20)
                    .scaleEffect(isSelected && !reduceMotion ? 1.06 : 1.0)

                Text(section.rawValue)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                    .lineLimit(1)

                Spacer()

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                } else if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .contentTransition(.numericText())
                        .foregroundStyle(isSelected ? studioAccent : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            isSelected ? studioAccent.opacity(0.16) : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                        .animation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion), value: badgeCount)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    if isSelected {
                        let activePill = RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous)
                            .fill(studioAccent.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous)
                                    .strokeBorder(studioAccent.opacity(0.22), lineWidth: 0.8)
                            }
                        if let ns = selectionNamespace {
                            activePill.matchedGeometryEffect(id: "StudioSidebarActivePill", in: ns)
                        } else {
                            activePill
                        }
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.055))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: StudioTokens.sidebarRowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(StudioMotion.animation(StudioMotion.micro, reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
        .animation(StudioMotion.animation(StudioMotion.standard, reduceMotion: reduceMotion), value: isSelected)
    }
}

// MARK: - Circular Dropdown Menu Button

struct StudioMenuOption: Identifiable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void
}

struct StudioCircleMenu: View {
    var systemImage: String = "chevron.down"
    var variant: StudioButtonVariant = .secondary
    var size: StudioControlSize = .small
    var header: String? = nil
    var isDisabled: Bool = false
    var accessibilityLabel: String? = nil
    let options: [StudioMenuOption]

    @State private var isPresented = false

    var body: some View {
        StudioCircleButton(
            systemImage: systemImage,
            variant: variant,
            size: size,
            isDisabled: isDisabled || options.isEmpty,
            accessibilityLabel: accessibilityLabel ?? "更多选项"
        ) {
            isPresented.toggle()
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let header, !header.isEmpty {
                    Text(header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                    Divider()
                        .padding(.bottom, 2)
                }

                ForEach(options) { option in
                    StudioMenuRow(option: option) {
                        isPresented = false
                        option.action()
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 168)
        }
    }
}

private struct StudioMenuRow: View {
    let option: StudioMenuOption
    let onSelect: () -> Void

    @Environment(\.studioAccentColor) private var studioAccent
    @State private var isHovered = false

    var body: some View {
        Button {
            guard !option.isDisabled else { return }
            onSelect()
        } label: {
            HStack(spacing: 8) {
                if let systemImage = option.systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(option.isSelected ? studioAccent : Color.secondary)
                        .frame(width: 14)
                }

                Text(option.title)
                    .font(.callout.weight(option.isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        option.isDisabled
                            ? Color.secondary
                            : (option.isSelected ? studioAccent : Color.primary)
                    )
                    .lineLimit(1)

                Spacer(minLength: 10)

                if option.isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(studioAccent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isHovered && !option.isDisabled
                            ? studioAccent.opacity(0.12)
                            : Color.clear
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(option.isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Source Platform Badge

struct StudioSourceBadge: View {
    let title: String
    var sourceId: String = "wenku8"

    @Environment(\.studioAccentColor) private var studioAccent

    private var badgeTint: Color {
        switch sourceId {
        case "bilinovel": return Color.pink
        case "copymanga": return Color.teal
        default: return studioAccent
        }
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badgeTint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(badgeTint.opacity(0.13), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(badgeTint.opacity(0.24), lineWidth: 0.7)
            }
    }
}

// MARK: - Surface Card Modifier

struct StudioCardModifier: ViewModifier {
    var cornerRadius: CGFloat = StudioTokens.cardRadius
    var padding: CGFloat = StudioTokens.cardPadding
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: StudioTokens.cardShadowColor, radius: 7, y: 2)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.08))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint?.opacity(0.22) ?? StudioTokens.hairlineStroke,
                        lineWidth: 0.9
                    )
            }
    }
}

extension View {
    func studioCard(
        cornerRadius: CGFloat = StudioTokens.cardRadius,
        padding: CGFloat = StudioTokens.cardPadding,
        tint: Color? = nil
    ) -> some View {
        modifier(StudioCardModifier(cornerRadius: cornerRadius, padding: padding, tint: tint))
    }
}
