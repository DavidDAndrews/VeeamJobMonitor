import SwiftUI

enum JobsToolbarLayout {
    /// Horizontal padding on each side of a toolbar icon (`ThemeHoverButtonStyle`, toolbar variant).
    static let toolbarButtonHorizontalInset: CGFloat = 6
    /// Spacing between icon buttons inside a toolbar cluster `HStack`.
    static let toolbarClusterButtonSpacing: CGFloat = 6
    /// Gap between the primary (refresh/export/share) and utility toolbar clusters.
    static let toolbarInterClusterSpacing: CGFloat = 10
    /// Navigation split sidebar toggle + outer toolbar edge inset in the sidebar column.
    static let toolbarChromeWidth: CGFloat = 36

    /// Floor width for the jobs sidebar column so unified-toolbar icon buttons are not clipped.
    static func minimumWidth(for textScale: CGFloat) -> CGFloat {
        let iconButtonWidth = (13 * textScale) + (toolbarButtonHorizontalInset * 2)
        let primaryClusterWidth =
            (iconButtonWidth * 3) + (toolbarClusterButtonSpacing * 2)
        let utilityClusterWidth =
            (iconButtonWidth * 6) + (toolbarClusterButtonSpacing * 5)
        return toolbarChromeWidth
            + primaryClusterWidth
            + toolbarInterClusterSpacing
            + utilityClusterWidth
    }
}

/// Left-aligned job search field in the sidebar column (not the unified toolbar).
struct JobsSidebarSearchField: View {
    @Binding var text: String
    @Environment(\.textScaleFactor) private var textScaleFactor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Font.scaledSystem(size: 13, weight: .medium, scale: textScaleFactor))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search by job name or description", text: $text)
                .textFieldStyle(.plain)
                .font(Font.scaledText(.callout, scale: textScaleFactor))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.scaledSystem(size: 13, scale: textScaleFactor))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
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
        JobsToolbarGlassCluster(spacing: JobsToolbarLayout.toolbarClusterButtonSpacing) {
            HStack(spacing: JobsToolbarLayout.toolbarClusterButtonSpacing) {
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
        JobsToolbarGlassCluster(spacing: JobsToolbarLayout.toolbarClusterButtonSpacing) {
            HStack(spacing: JobsToolbarLayout.toolbarClusterButtonSpacing) {
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
