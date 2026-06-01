import SwiftUI

enum JobsToolbarLayout {
    /// Floor width for the jobs sidebar toolbar row (icon buttons + search) so controls are not clipped.
    static func minimumWidth(for textScale: CGFloat) -> CGFloat {
        // Keep in sync with toolbar ToolbarItem list, ToolbarIcon, ThemeHoverButtonStyle, and `.searchable`.
        let iconWidth: CGFloat = 13 * textScale
        let buttonHorizontalPadding: CGFloat = 12
        let iconButtonWidth = iconWidth + buttonHorizontalPadding
        let toolbarItemSpacing: CGFloat = 8
        let toolbarPlacementGroupSpacing: CGFloat = 16
        let searchFieldMinimumWidth: CGFloat = 160
        let toolbarHorizontalMargin: CGFloat = 24
        let sidebarToggleWidth: CGFloat = 36
        let toolbarButtonCount = 9
        let buttonsRowWidth = iconButtonWidth * CGFloat(toolbarButtonCount)
            + toolbarItemSpacing * CGFloat(toolbarButtonCount - 1)
            + toolbarPlacementGroupSpacing
        return sidebarToggleWidth + buttonsRowWidth + searchFieldMinimumWidth + toolbarHorizontalMargin
    }
}

enum LeftPaneSort {
    case jobName
    case status
}

struct ToolbarIcon: View {
    let symbol: String
    @Environment(\.textScaleFactor) private var textScaleFactor

    var body: some View {
        Image(systemName: symbol)
            .font(Font.scaledSystem(size: 13, weight: .semibold, scale: textScaleFactor))
            .frame(width: 13 * textScaleFactor, height: 13 * textScaleFactor)
    }
}

struct JobsPrimaryToolbarCluster: View {
    let isRefreshing: Bool
    let jobsEmpty: Bool
    let onRefresh: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void

    var body: some View {
        JobsToolbarGlassCluster {
            HStack(spacing: 8) {
                Button(action: onRefresh) {
                    ToolbarIcon(symbol: "arrow.clockwise")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(isRefreshing)
                .help("Refresh all jobs and backup-point details from the server.")

                Button(action: onExport) {
                    ToolbarIcon(symbol: "doc.badge.arrow.up")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(jobsEmpty)
                .help("Generate and open an HTML backup report.")

                Button(action: onShare) {
                    ToolbarIcon(symbol: "square.and.arrow.up")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(jobsEmpty)
                .help("Share the HTML backup report by email, message, or other share targets.")
            }
        }
    }
}

struct JobsUtilityToolbarCluster: View {
    let canDecreaseTextScale: Bool
    let canIncreaseTextScale: Bool
    let canResetTextScale: Bool
    let isDarkModeEnabled: Bool
    let onDecreaseTextScale: () -> Void
    let onResetTextScale: () -> Void
    let onIncreaseTextScale: () -> Void
    let onToggleDarkMode: () -> Void
    let onLogout: () -> Void
    let onQuit: () -> Void

    var body: some View {
        JobsToolbarGlassCluster {
            HStack(spacing: 8) {
                Button(action: onDecreaseTextScale) {
                    ToolbarIcon(symbol: "textformat.size.smaller")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(!canDecreaseTextScale)
                .help("Decrease text size in the jobs list and detail panes.")

                Button(action: onResetTextScale) {
                    ToolbarIcon(symbol: "arrow.counterclockwise")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(!canResetTextScale)
                .help("Reset text size to the default.")

                Button(action: onIncreaseTextScale) {
                    ToolbarIcon(symbol: "textformat.size.larger")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .disabled(!canIncreaseTextScale)
                .help("Increase text size in the jobs list and detail panes.")

                Button(action: onToggleDarkMode) {
                    ToolbarIcon(symbol: isDarkModeEnabled ? "sun.max.fill" : "moon.fill")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .help(isDarkModeEnabled ? "Switch to light mode." : "Switch to dark mode.")

                Button(action: onLogout) {
                    ToolbarIcon(symbol: "server.rack")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .help("Return to the server connection screen.")

                Button(action: onQuit) {
                    ToolbarIcon(symbol: "power")
                }
                .buttonStyle(ThemeHoverButtonStyle())
                .help("Quit the application.")
            }
        }
    }
}

struct ServerLoadingView: View {
    let title: String
    let subtitle: String
    let progressPercent: Int?
    @State private var isAnimating = false
    @Environment(\.textScaleFactor) private var textScaleFactor

    private var clampedProgress: Double? {
        guard let progressPercent else { return nil }
        return min(max(Double(progressPercent), 0), 100)
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .stroke(Theme.brand.opacity(0.2), lineWidth: 8)
                    .frame(width: 84, height: 84)

                Circle()
                    .trim(from: clampedProgress == nil ? 0.12 : 0.0, to: clampedProgress == nil ? 0.86 : (clampedProgress ?? 0) / 100.0)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Theme.brand.opacity(0.2), Theme.brand, Theme.brand.opacity(0.35)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 84, height: 84)
                    .rotationEffect(.degrees(clampedProgress == nil ? (isAnimating ? 360 : 0) : -90))
                    .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isAnimating)
                    .animation(.easeOut(duration: 0.25), value: clampedProgress ?? 0)

                if let clampedProgress {
                    Text("\(Int(clampedProgress))%")
                        .font(Font.scaledSystem(size: 16, weight: .bold, design: .rounded, scale: textScaleFactor))
                        .foregroundStyle(Theme.brand)
                        .contentTransition(.numericText(value: clampedProgress))
                        .animation(.easeOut(duration: 0.2), value: clampedProgress)
                }
            }
            .shadow(color: Theme.brand.opacity(0.25), radius: 14, x: 0, y: 6)

            VStack(spacing: 4) {
                Text(title)
                    .font(Font.scaledText(.title3, scale: textScaleFactor, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                Text(subtitle)
                    .font(Font.scaledText(.subheadline, scale: textScaleFactor))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .themeGlassPanel(cornerRadius: Theme.Radius.large)
        .themeShadow(Theme.shadowSubtle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onAppear {
            if progressPercent == nil {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
        }
    }
}
