import SwiftUI

// MARK: - Liquid Glass (macOS 26+)

enum LiquidGlass {
    /// Whether system Liquid Glass should be used for the current accessibility settings.
    static func prefersSystemGlass(reduceTransparency: Bool, contrast: ColorSchemeContrast = .standard) -> Bool {
        if #available(macOS 26, *) {
            return !reduceTransparency && contrast != .increased
        }
        return false
    }

    #if DEBUG
    static func testing_prefersSystemGlass(reduceTransparency: Bool, contrast: ColorSchemeContrast = .standard) -> Bool {
        prefersSystemGlass(reduceTransparency: reduceTransparency, contrast: contrast)
    }
    #endif
}

// MARK: - Panel / chip modifiers

private struct ThemeGlassPanelModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat
    let material: Material
    let fallbackSurface: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if LiquidGlass.prefersSystemGlass(reduceTransparency: reduceTransparency, contrast: contrast) {
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                legacyBackground(content: content, shape: shape)
            }
        } else if reduceTransparency || contrast == .increased {
            legacyBackground(content: content, shape: shape, strokeOpacity: contrast == .increased ? 0.9 : 0.65)
        } else {
            content
                .background(material, in: shape)
                .overlay(shape.stroke(Theme.separator.opacity(0.65), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func legacyBackground(content: Content, shape: RoundedRectangle, strokeOpacity: Double = 0.65) -> some View {
        content
            .background(fallbackSurface, in: shape)
            .overlay(shape.stroke(Theme.separator.opacity(strokeOpacity), lineWidth: contrast == .increased ? 1.0 : 0.5))
    }
}

private struct ThemeGlassChipModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if LiquidGlass.prefersSystemGlass(reduceTransparency: reduceTransparency, contrast: contrast) {
            if #available(macOS 26, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content.background(Theme.brandTint, in: shape)
            }
        } else {
            content.background(Theme.brandTint, in: shape)
        }
    }
}

private struct ThemeGlassToolbarChromeModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let isHovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        if LiquidGlass.prefersSystemGlass(reduceTransparency: reduceTransparency, contrast: contrast) {
            if #available(macOS 26, *) {
                content.glassEffect(
                    isHovered
                        ? .regular.interactive().tint(Theme.brand.opacity(0.14))
                        : .regular.interactive(),
                    in: shape
                )
            } else {
                content.background(shape.fill(isHovered ? Theme.brandTint : Color.clear))
            }
        } else {
            content.background(shape.fill(isHovered ? Theme.brandTint : Color.clear))
        }
    }
}

extension View {
    /// Floating panel chrome for login cards, filter bars, toasts, and loading overlays.
    func themeGlassPanel(
        cornerRadius: CGFloat = Theme.Radius.large,
        material: Material = .regularMaterial,
        fallbackSurface: Color = Theme.surface
    ) -> some View {
        modifier(
            ThemeGlassPanelModifier(
                cornerRadius: cornerRadius,
                material: material,
                fallbackSurface: fallbackSurface
            )
        )
    }

    /// Small interactive control chrome (theme toggle, compact toolbar chips).
    func themeGlassChip(cornerRadius: CGFloat = Theme.Radius.small) -> some View {
        modifier(ThemeGlassChipModifier(cornerRadius: cornerRadius))
    }

    /// Toolbar icon button chrome; pair with `GlassEffectContainer` when grouping controls.
    func themeGlassToolbarChrome(isHovered: Bool) -> some View {
        modifier(ThemeGlassToolbarChromeModifier(isHovered: isHovered))
    }
}

// MARK: - Toolbar glass container

struct JobsToolbarGlassCluster<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if LiquidGlass.prefersSystemGlass(reduceTransparency: reduceTransparency, contrast: contrast) {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: spacing) {
                    content()
                }
            } else {
                content()
            }
        } else {
            content()
        }
    }
}
