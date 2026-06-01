import SwiftUI
import AppKit

// MARK: - Design Tokens
//
// Single source of truth for the app's visual language. Every surface (splash,
// login, list, detail, toolbar) and the HTML report pull from these tokens so
// the brand green, neutrals, and the five status semantics stay consistent.

enum Theme {

    // MARK: Brand
    /// The one Veeam green used across chrome and the Success status.
    static let brand = Color(hex: 0x0F8A43)
    /// Darker brand variant for the splash band and gradients.
    static let brandDark = Color(hex: 0x0A6332)
    /// Light brand wash for tinted backgrounds.
    static let brandTint = Color(hex: 0x0F8A43, opacity: 0.12)

    // MARK: Jobs list selection (fixed brand-dark + white for contrast in light and dark mode)
    static let listRowSelectedBackground = brandDark
    static let listRowSelectedPrimary = Color.white
    static let listRowSelectedSecondary = Color.white.opacity(0.82)
    static let listRowSelectedTertiary = Color.white.opacity(0.62)

    // MARK: Neutrals (dynamic system colors so dark mode adapts automatically)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let surfaceSecondary = Color(nsColor: .controlBackgroundColor)
    static let surfaceElevated = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: Semantic status (mirrors the five buckets in JobResultClassification)
    static let statusRunning = Color(hex: 0x2563EB)   // blue
    static let statusSuccess = brand                   // green (unified with brand)
    static let statusWarning = Color(hex: 0xF59E0B)   // orange
    static let statusFailed = Color(hex: 0xDC2626)    // red
    static let statusDisabled = Color(hex: 0x64748B)  // slate (retires yellow-for-disabled)
    static let statusUnknown = Color(nsColor: .secondaryLabelColor)
}

// MARK: - Status style

/// Bundles the color + SF Symbol + derived tint for a single status bucket.
struct StatusStyle {
    let color: Color
    let icon: String

    /// Background tint at ~14% opacity for pills and accents.
    var tint: Color { color.opacity(0.14) }
    /// Slightly stronger tint for selected/active states.
    var strongTint: Color { color.opacity(0.22) }

}

extension Theme {
    /// Maps a `JobResultBucket` to its unified color + icon. This is the helper
    /// every view should use instead of hardcoding `.green/.orange/.yellow/...`.
    static func style(for bucket: JobResultBucket) -> StatusStyle {
        switch bucket {
        case .running:
            return StatusStyle(color: statusRunning, icon: "arrow.triangle.2.circlepath.circle.fill")
        case .success:
            return StatusStyle(color: statusSuccess, icon: "checkmark.circle.fill")
        case .warning:
            return StatusStyle(color: statusWarning, icon: "exclamationmark.triangle.fill")
        case .failed:
            return StatusStyle(color: statusFailed, icon: "xmark.circle.fill")
        case .disabled:
            return StatusStyle(color: statusDisabled, icon: "pause.circle.fill")
        case .unknown:
            return StatusStyle(color: statusUnknown, icon: "circle.dashed")
        }
    }

    /// Readable status foreground when a jobs list row uses `listRowSelectedBackground`.
    static func onSelectedRowStatus(for bucket: JobResultBucket) -> Color {
        switch bucket {
        case .running: return Color(hex: 0x93C5FD)
        case .success: return Color(hex: 0xBBF7D0)
        case .warning: return Color(hex: 0xFDE68A)
        case .failed: return Color(hex: 0xFECACA)
        case .disabled: return Color(hex: 0xE2E8F0)
        case .unknown: return listRowSelectedSecondary
        }
    }
}

// MARK: - Spacing scale

extension Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }
}

// MARK: - Elevation / shadow presets

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

extension Theme {
    /// Resting elevation for cards and chips.
    static let shadowSubtle = ShadowStyle(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    /// Hover/floating elevation for toasts and lifted buttons.
    static let shadowElevated = ShadowStyle(color: .black.opacity(0.16), radius: 12, x: 0, y: 6)
}

extension View {
    func themeShadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

// MARK: - Shared hover button styles

struct ThemeHoverButtonStyle: ButtonStyle {
    enum Variant {
        case toolbar
        case brand
    }

    var variant: Variant = .toolbar

    func makeBody(configuration: Configuration) -> some View {
        ThemeHoverButtonBody(configuration: configuration, variant: variant)
    }
}

private struct ThemeHoverButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let variant: ThemeHoverButtonStyle.Variant
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(variant == .toolbar ? EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6) : EdgeInsets())
            .modifier(ToolbarChromeModifier(variant: variant, isHovered: isHovered))
            .shadow(
                color: brandShadowColor,
                radius: brandShadowRadius,
                x: 0,
                y: brandShadowY
            )
            .overlay(brandHoverOverlay)
            .scaleEffect(scale)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    @ViewBuilder
    private var brandHoverOverlay: some View {
        if variant == .brand {
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(Color.white.opacity(isHovered ? 0.10 : 0.0))
        }
    }

    private var scale: CGFloat {
        if configuration.isPressed { return variant == .toolbar ? 0.96 : 0.98 }
        return isHovered ? (variant == .toolbar ? 1.02 : 1.01) : 1.0
    }

    private var brandShadowColor: Color {
        variant == .brand ? Color.black.opacity(isHovered ? 0.20 : 0.12) : .clear
    }

    private var brandShadowRadius: CGFloat {
        variant == .brand ? (isHovered ? 8 : 3) : 0
    }

    private var brandShadowY: CGFloat {
        variant == .brand ? (isHovered ? 5 : 2) : 0
    }
}

private struct ToolbarChromeModifier: ViewModifier {
    let variant: ThemeHoverButtonStyle.Variant
    let isHovered: Bool

    func body(content: Content) -> some View {
        switch variant {
        case .toolbar:
            content.themeGlassToolbarChrome(isHovered: isHovered)
        case .brand:
            content
        }
    }
}

// MARK: - Shared hex strings (single source for the HTML report's CSS variables)

extension Theme {
    enum Hex {
        static let brand = "#0F8A43"
        static let brandDark = "#0A6332"
        static let running = "#2563EB"
        static let success = "#0F8A43"
        static let warning = "#F59E0B"
        static let failed = "#DC2626"
        static let disabled = "#64748B"
        static let unknown = "#64748B"

        /// Throughput coloring aligned with `JobDetailView.throughputColor`.
        static func throughput(forMbps mbps: Double) -> String {
            switch mbps {
            case ..<1: return failed
            case 1..<40: return warning
            case 40..<100: return success
            default: return running
            }
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

// MARK: - Appearance preference

enum AppearancePreference {
    static let storageKey = "isDarkModeEnabled"
}

// MARK: - Text scale preference

/// Stepped text scale for the jobs list and detail panes. Each toolbar click moves one step.
enum TextScalePreference {
    static let storageKey = "textScaleFactor"
    static let legacyStorageKey = "textScaleLevelIndex"

    static let defaultFactor: Double = 1.0
    static let minFactor: Double = 0.75
    static let maxFactor: Double = 1.5
    static let step: Double = 0.05

    private static let legacyScaleLevels: [Double] = [0.85, 1.0, 1.15, 1.30]
    private static var minStepIndex: Int { Int((minFactor - defaultFactor) / step) }
    private static var maxStepIndex: Int { Int((maxFactor - defaultFactor) / step) }

    /// Migrates the old discrete level index to a stored scale factor before views read `@AppStorage`.
    static func migrateLegacyScaleIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: storageKey) == nil else { return }

        if defaults.object(forKey: legacyStorageKey) != nil {
            let legacyIndex = defaults.integer(forKey: legacyStorageKey)
            let clampedIndex = min(max(legacyIndex, 0), legacyScaleLevels.count - 1)
            defaults.set(normalizedFactor(legacyScaleLevels[clampedIndex]), forKey: storageKey)
            return
        }

        defaults.set(defaultFactor, forKey: storageKey)
    }

    static func clamped(_ factor: Double) -> CGFloat {
        CGFloat(scaledFactor(forStepIndex: stepIndex(for: factor)))
    }

    static func canDecrease(_ factor: Double) -> Bool {
        stepIndex(for: factor) > minStepIndex
    }

    static func canIncrease(_ factor: Double) -> Bool {
        stepIndex(for: factor) < maxStepIndex
    }

    static func isAtDefault(_ factor: Double) -> Bool {
        stepIndex(for: factor) == 0
    }

    static func decreased(from factor: Double) -> Double {
        scaledFactor(forStepIndex: stepIndex(for: factor) - 1)
    }

    static func increased(from factor: Double) -> Double {
        scaledFactor(forStepIndex: stepIndex(for: factor) + 1)
    }

    static func dynamicTypeSize(for factor: CGFloat) -> DynamicTypeSize {
        switch factor {
        case ..<0.82: return .xSmall
        case ..<0.92: return .small
        case ..<1.05: return .medium
        case ..<1.18: return .large
        case ..<1.32: return .xLarge
        default: return .xxLarge
        }
    }

    private static func stepIndex(for factor: Double) -> Int {
        Int(((factor - defaultFactor) / step).rounded())
    }

    private static func scaledFactor(forStepIndex index: Int) -> Double {
        let clampedIndex = min(max(index, minStepIndex), maxStepIndex)
        return min(max(defaultFactor + Double(clampedIndex) * step, minFactor), maxFactor)
    }

    private static func normalizedFactor(_ factor: Double) -> Double {
        let clamped = min(max(factor, minFactor), maxFactor)
        return scaledFactor(forStepIndex: stepIndex(for: clamped))
    }

    #if DEBUG
    /// Test-only accessors for launch regression coverage.
    static func testing_scaledFactor(forStepIndex index: Int) -> Double {
        scaledFactor(forStepIndex: index)
    }

    static func testing_normalizedFactor(_ factor: Double) -> Double {
        normalizedFactor(factor)
    }
    #endif
}

private struct TextScaleFactorKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

private struct DetailTextBonusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var textScaleFactor: CGFloat {
        get { self[TextScaleFactorKey.self] }
        set { self[TextScaleFactorKey.self] = newValue }
    }

    /// Extra points added to scaled detail-pane fonts (jobs list uses the default of 0).
    var detailTextBonus: CGFloat {
        get { self[DetailTextBonusKey.self] }
        set { self[DetailTextBonusKey.self] = newValue }
    }
}

/// Semantic text styles mapped to macOS base point sizes used in the jobs list and detail panes.
enum ScaledTextStyle {
    case title2
    case title3
    case callout
    case subheadline
    case footnote
    case caption
    case caption2

    var baseSize: CGFloat {
        switch self {
        case .title2: return 17
        case .title3: return 15
        case .callout: return 13
        case .subheadline: return 11
        case .footnote, .caption: return 10
        case .caption2: return 9
        }
    }
}

extension Font {
    static func scaledSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        scale: CGFloat,
        baselineOffset: CGFloat = 0
    ) -> Font {
        .system(size: size * scale + baselineOffset, weight: weight, design: design)
    }

    /// Scales a semantic style by the persisted text-scale factor (macOS does not reliably honor `dynamicTypeSize` alone).
    static func scaledText(
        _ style: ScaledTextStyle,
        scale: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        baselineOffset: CGFloat = 0
    ) -> Font {
        .system(size: style.baseSize * scale + baselineOffset, weight: weight, design: design)
    }
}

extension View {
    /// Applies persisted text scale to semantic fonts and exposes `textScaleFactor` for fixed-size typography.
    func appTextScale(_ factor: CGFloat, detailTextBonus: CGFloat = 0) -> some View {
        environment(\.textScaleFactor, factor)
            .environment(\.detailTextBonus, detailTextBonus)
            .dynamicTypeSize(TextScalePreference.dynamicTypeSize(for: factor))
    }
}
