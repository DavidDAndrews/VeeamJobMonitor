import SwiftUI
import AppKit

// MARK: - Tooltip delay

/// App-wide initial tooltip delay (SwiftUI `.help()` uses AppKit tooltips under the hood).
private enum TooltipConfiguration {
    /// `NSInitialToolTipDelay` is measured in milliseconds; 500 ms = 0.5 s.
    static let initialDelayMilliseconds = 500

    static func applyInitialDelay() {
        UserDefaults.standard.set(initialDelayMilliseconds, forKey: "NSInitialToolTipDelay")
    }
}

// MARK: - Window frame persistence

/// Persists the main window frame between launches (origin + size, not splash dimensions).
private enum WindowFrameStore {
    static let originXKey = "com.veeammonitor.window.originX"
    static let originYKey = "com.veeammonitor.window.originY"
    static let widthKey = "com.veeammonitor.window.width"
    static let heightKey = "com.veeammonitor.window.height"

    static let defaultSize = NSSize(width: 960, height: 640)
    static let minimumSize = NSSize(width: 400, height: 300)
    static let saveDebounceInterval: TimeInterval = 0.35

    static var hasSavedFrame: Bool {
        UserDefaults.standard.object(forKey: widthKey) != nil
    }

    static func save(_ frame: NSRect) {
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: originXKey)
        defaults.set(frame.origin.y, forKey: originYKey)
        defaults.set(frame.size.width, forKey: widthKey)
        defaults.set(frame.size.height, forKey: heightKey)
    }

    static func load() -> NSRect? {
        guard hasSavedFrame else { return nil }

        let defaults = UserDefaults.standard
        let frame = NSRect(
            x: defaults.double(forKey: originXKey),
            y: defaults.double(forKey: originYKey),
            width: defaults.double(forKey: widthKey),
            height: defaults.double(forKey: heightKey)
        )

        guard frame.width >= minimumSize.width, frame.height >= minimumSize.height else { return nil }
        return frame
    }

    /// First launch: fill the active screen's visible area (zoomed, not full-screen mode).
    static func firstRunFrame(for screen: NSScreen) -> NSRect {
        screen.visibleFrame
    }

    /// Clamps a saved frame onto the current display layout when monitors change or the frame is off-screen.
    static func frameEnsuringOnScreen(_ frame: NSRect) -> NSRect {
        var adjusted = frame
        adjusted.size.width = max(adjusted.width, minimumSize.width)
        adjusted.size.height = max(adjusted.height, minimumSize.height)

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return adjusted }

        let bestScreen = screens.max(by: { lhs, rhs in
            intersectionArea(lhs.visibleFrame, adjusted) < intersectionArea(rhs.visibleFrame, adjusted)
        }) ?? NSScreen.main ?? screens[0]

        let visible = bestScreen.visibleFrame

        if !visible.intersects(adjusted) {
            adjusted.size.width = min(adjusted.width, visible.width)
            adjusted.size.height = min(adjusted.height, visible.height)
            adjusted = centeredFrame(size: adjusted.size, in: visible)
        }

        adjusted.size.width = min(adjusted.width, visible.width)
        adjusted.size.height = min(adjusted.height, visible.height)

        if adjusted.maxX > visible.maxX {
            adjusted.origin.x = visible.maxX - adjusted.width
        }
        if adjusted.minX < visible.minX {
            adjusted.origin.x = visible.minX
        }
        if adjusted.maxY > visible.maxY {
            adjusted.origin.y = visible.maxY - adjusted.height
        }
        if adjusted.minY < visible.minY {
            adjusted.origin.y = visible.minY
        }

        return adjusted
    }

    static func mainFrame(for screen: NSScreen) -> NSRect {
        if let saved = load() {
            return frameEnsuringOnScreen(saved)
        }
        return firstRunFrame(for: screen)
    }

    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        a.intersection(b).width * a.intersection(b).height
    }

    private static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Splash window layout

/// Sizes and positions the app window for the splash overlay (~25% of screen area),
/// then restores the persisted frame (or first-run maximized size) when the splash dismisses.
private enum SplashWindowLayout {
    static let areaFraction: CGFloat = 0.25
    /// Splash card aspect ratio (width / height); keeps proportions on ultrawide displays.
    static let splashAspectRatio: CGFloat = 4.0 / 3.0

    static let minSplashSize = NSSize(width: 380, height: 285)
    static let maxSplashSize = NSSize(width: 600, height: 450)

    static func splashFrame(for screen: NSScreen) -> NSRect {
        centeredFrame(
            size: clampedSplashSize(for: screen.visibleFrame),
            in: screen.visibleFrame
        )
    }

    private static func clampedSplashSize(for visibleFrame: NSRect) -> NSSize {
        let targetArea = visibleFrame.width * visibleFrame.height * areaFraction
        var height = sqrt(targetArea / splashAspectRatio)
        var width = height * splashAspectRatio

        width = min(max(width, minSplashSize.width), maxSplashSize.width)
        height = min(max(height, minSplashSize.height), maxSplashSize.height)

        // Preserve aspect ratio after clamping against independent min/max bounds.
        if width / height > splashAspectRatio {
            width = height * splashAspectRatio
        } else {
            height = width / splashAspectRatio
        }

        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct SplashWindowFrameController: NSViewRepresentable {
    let showSplash: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.applyFrame(showSplash: showSplash, from: view, animated: false)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.applyFrame(showSplash: showSplash, from: nsView, animated: true)
        }
    }

    final class Coordinator {
        private var hasAppliedInitialFrame = false
        private var lastShowSplash: Bool?
        private var shouldPersistFrame = false
        private var frameSaveWorkItem: DispatchWorkItem?
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func applyFrame(showSplash: Bool, from view: NSView, animated: Bool) {
            guard let window = view.window else { return }

            if observedWindow !== window {
                observedWindow = window
                installFramePersistence(for: window)
            }

            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { return }

            let targetFrame = showSplash
                ? SplashWindowLayout.splashFrame(for: screen)
                : WindowFrameStore.mainFrame(for: screen)

            let shouldAnimate = animated
                && hasAppliedInitialFrame
                && lastShowSplash == true
                && !showSplash

            window.setFrame(targetFrame, display: true, animate: shouldAnimate)
            hasAppliedInitialFrame = true
            lastShowSplash = showSplash

            if !showSplash {
                shouldPersistFrame = true
            }
        }

        private func installFramePersistence(for window: NSWindow) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            let center = NotificationCenter.default
            let windowNotifications: [Notification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.willCloseNotification
            ]

            for name in windowNotifications {
                observers.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.persistFrameIfNeeded()
                })
            }

            observers.append(center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.persistFrameIfNeeded(immediate: true)
            })
        }

        private func persistFrameIfNeeded(immediate: Bool = false) {
            guard shouldPersistFrame, let window = observedWindow else { return }
            guard !window.isMiniaturized else { return }

            frameSaveWorkItem?.cancel()

            let save = DispatchWorkItem {
                WindowFrameStore.save(window.frame)
            }

            frameSaveWorkItem = save
            if immediate {
                save.perform()
            } else {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + WindowFrameStore.saveDebounceInterval,
                    execute: save
                )
            }
        }
    }
}

@main
struct VeeamMonitorApp: App {
    @StateObject private var api = VeeamAPIService()

    init() {
        TooltipConfiguration.applyInitialDelay()
        TextScalePreference.migrateLegacyScaleIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(api)
                .tint(Theme.brand)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(
            width: WindowFrameStore.defaultSize.width,
            height: WindowFrameStore.defaultSize.height
        )
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Veeam Monitor") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: "Author: David Andrews\nCopyright © 2026 David Andrews\nAll rights reserved."
                        )
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Refresh Jobs") {
                    // handled via NotificationCenter
                    NotificationCenter.default.post(name: .refreshJobs, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var api: VeeamAPIService
    @AppStorage(AppearancePreference.storageKey) private var isDarkModeEnabled = false
    @State private var showSplash = true

    private static let minimumSplashDuration: Duration = .milliseconds(850)
    private static let maximumSplashDuration: Duration = .seconds(2)

    var body: some View {
        ZStack {
            Group {
                if api.isAuthenticated {
                    if showSplash {
                        Color.clear
                    } else {
                        JobsListView(api: api)
                    }
                } else {
                    LoginView(api: api)
                        .frame(width: 400)
                }
            }
            .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashScreenView()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: api.isAuthenticated)
        .preferredColorScheme(isDarkModeEnabled ? .dark : .light)
        .background {
            SplashWindowFrameController(showSplash: showSplash)
        }
        .task {
            await dismissSplashWhenReady()
        }
    }

    @MainActor
    private func dismissSplashWhenReady() async {
        let started = ContinuousClock.now

        api.prepareForLaunch()
        try? await Task.sleep(for: Self.minimumSplashDuration)

        if api.isAuthenticated {
            while api.isRefreshingJobs {
                if started.duration(to: .now) >= Self.maximumSplashDuration {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        withAnimation(.easeOut(duration: 0.22)) {
            showSplash = false
        }
    }
}

private struct SplashScreenView: View {
    @State private var contentVisible = false

    private var versionBuildText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.brand, Theme.brandDark],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                SplashLogoMark()
                    .frame(width: 124, height: 124)
                    .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)

                VStack(spacing: 8) {
                    Text("VEEAM MONITOR V13")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)

                    Text("David Andrews © 2026  All rights reserved.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))

                    Text(versionBuildText)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.82))
                }
            }
            .padding(24)
            .opacity(contentVisible ? 1 : 0)
            .scaleEffect(contentVisible ? 1 : 0.96)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                contentVisible = true
            }
        }
    }
}

private struct SplashLogoMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 1.5)
                )

            Circle()
                .fill(.white.opacity(0.12))
                .padding(22)

            Text("V")
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

extension Notification.Name {
    static let refreshJobs = Notification.Name("com.veeammonitor.refreshJobs")
}
