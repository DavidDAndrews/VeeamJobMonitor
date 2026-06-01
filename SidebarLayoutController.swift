import SwiftUI
import AppKit

// MARK: - Sidebar toggle window frame (AppKit)

/// Keeps the outer window frame stable when the jobs sidebar is hidden or shown.
/// NavigationSplitView collapses the sidebar column but does not shrink or restore the NSWindow frame.
struct SidebarToggleWindowFrameController: NSViewRepresentable {
    let columnVisibility: NavigationSplitViewVisibility
    let fallbackSidebarWidth: CGFloat
    let minimumSidebarWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            fallbackSidebarWidth: fallbackSidebarWidth,
            minimumSidebarWidth: minimumSidebarWidth
        )
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.minimumSidebarWidth = minimumSidebarWidth
        context.coordinator.fallbackSidebarWidth = fallbackSidebarWidth
        let visibility = columnVisibility
        DispatchQueue.main.async {
            context.coordinator.handle(
                columnVisibility: visibility,
                window: nsView.window
            )
        }
    }

    final class Coordinator {
        var fallbackSidebarWidth: CGFloat
        var minimumSidebarWidth: CGFloat
        private var lastVisibility: NavigationSplitViewVisibility?
        private var frameBeforeHide: NSRect?
        private var sidebarWidthBeforeHide: CGFloat?
        private var pendingAdjustment: DispatchWorkItem?

        private static let minimumWindowWidth: CGFloat = 400
        private static let layoutDelay: TimeInterval = 0.1

        init(fallbackSidebarWidth: CGFloat, minimumSidebarWidth: CGFloat) {
            self.fallbackSidebarWidth = fallbackSidebarWidth
            self.minimumSidebarWidth = minimumSidebarWidth
        }

        deinit {
            pendingAdjustment?.cancel()
        }

        func handle(columnVisibility: NavigationSplitViewVisibility, window: NSWindow?) {
            guard let window else { return }
            guard columnVisibility != lastVisibility else { return }

            let previousVisibility = lastVisibility
            lastVisibility = columnVisibility
            pendingAdjustment?.cancel()

            if columnVisibility == .detailOnly {
                frameBeforeHide = window.frame
                let measuredWidth = Self.sidebarColumnWidth(in: window) ?? fallbackSidebarWidth
                sidebarWidthBeforeHide = max(measuredWidth, minimumSidebarWidth)

                let savedFrame = window.frame
                let sidebarWidth = sidebarWidthBeforeHide ?? fallbackSidebarWidth
                let work = DispatchWorkItem { [weak self, weak window] in
                    guard let self, let window, self.lastVisibility == .detailOnly else { return }
                    Self.shrinkWindow(window, savedFrame: savedFrame, sidebarWidth: sidebarWidth)
                }
                pendingAdjustment = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutDelay, execute: work)
            } else if previousVisibility == .detailOnly, let savedFrame = frameBeforeHide {
                let restoreSidebarWidth = max(
                    sidebarWidthBeforeHide ?? fallbackSidebarWidth,
                    minimumSidebarWidth
                )
                frameBeforeHide = nil
                sidebarWidthBeforeHide = nil

                // Apply sidebar floor before the unified toolbar lays out on show.
                Self.enforceSidebarWidth(
                    atLeast: minimumSidebarWidth,
                    preferredWidth: restoreSidebarWidth,
                    in: window
                )

                let work = DispatchWorkItem { [weak self, weak window] in
                    guard let self, let window else { return }
                    window.setFrame(savedFrame, display: true, animate: true)
                    Self.enforceSidebarWidth(
                        atLeast: self.minimumSidebarWidth,
                        preferredWidth: restoreSidebarWidth,
                        in: window
                    )
                }
                pendingAdjustment = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.layoutDelay, execute: work)
            }
        }

        private static func shrinkWindow(_ window: NSWindow, savedFrame: NSRect, sidebarWidth: CGFloat) {
            var shrunkFrame = savedFrame
            shrunkFrame.size.width = max(minimumWindowWidth, savedFrame.width - sidebarWidth)
            window.setFrame(shrunkFrame, display: true, animate: true)
        }

        private static func enforceSidebarWidth(
            atLeast minimumWidth: CGFloat,
            preferredWidth: CGFloat,
            in window: NSWindow
        ) {
            guard let contentView = window.contentView else { return }
            guard let splitView = findPrimaryVerticalSplitView(in: contentView) else { return }
            guard splitView.isVertical, splitView.subviews.count >= 2 else { return }

            let target = max(minimumWidth, preferredWidth)
            splitView.setPosition(target, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        }

        private static func sidebarColumnWidth(in window: NSWindow) -> CGFloat? {
            guard let contentView = window.contentView else { return nil }
            guard let splitView = findPrimaryVerticalSplitView(in: contentView) else { return nil }
            let width = splitView.subviews.first?.frame.width ?? 0
            return width > 1 ? width : nil
        }

        private static func findPrimaryVerticalSplitView(in view: NSView) -> NSSplitView? {
            var firstMatch: NSSplitView?

            func walk(_ node: NSView) {
                if let split = node as? NSSplitView, split.isVertical, split.subviews.count >= 2 {
                    if firstMatch == nil {
                        firstMatch = split
                    }
                }
                for subview in node.subviews {
                    walk(subview)
                }
            }

            walk(view)
            return firstMatch
        }
    }
}

// MARK: - Sidebar split view width (AppKit)

/// Applies sidebar width on the underlying `NSSplitView`. SwiftUI's `navigationSplitViewColumnWidth(ideal:)`
/// is only a layout hint and is often ignored after the first layout on macOS.
struct SidebarSplitViewWidthApplier: NSViewRepresentable {
    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let applyToken: Int
    let columnVisibility: NavigationSplitViewVisibility
    let onUserResize: () -> Void

    func makeNSView(context: Context) -> SidebarSplitViewAnchorView {
        let view = SidebarSplitViewAnchorView()
        view.isHidden = true
        view.onUserResize = onUserResize
        return view
    }

    func updateNSView(_ nsView: SidebarSplitViewAnchorView, context: Context) {
        nsView.onUserResize = onUserResize
        nsView.minimumSidebarWidth = minWidth
        context.coordinator.scheduleApply(
            width: width,
            minWidth: minWidth,
            maxWidth: maxWidth,
            token: applyToken,
            columnVisibility: columnVisibility,
            anchorView: nsView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var lastAppliedToken = -1
        private var lastColumnVisibility: NavigationSplitViewVisibility?
        private var pendingRetry: DispatchWorkItem?

        deinit {
            pendingRetry?.cancel()
        }

        func scheduleApply(
            width: CGFloat,
            minWidth: CGFloat,
            maxWidth: CGFloat,
            token: Int,
            columnVisibility: NavigationSplitViewVisibility,
            anchorView: NSView
        ) {
            let visibilityChanged = columnVisibility != lastColumnVisibility
            lastColumnVisibility = columnVisibility
            guard columnVisibility != .detailOnly else { return }
            guard token != lastAppliedToken || visibilityChanged else { return }
            pendingRetry?.cancel()

            let work = DispatchWorkItem { [weak self, weak anchorView] in
                guard let self, let anchorView else { return }
                if Self.applyWidth(width, minWidth: minWidth, maxWidth: maxWidth, from: anchorView, anchor: anchorView) {
                    self.lastAppliedToken = token
                }
            }
            DispatchQueue.main.async(execute: work)

            let retry = DispatchWorkItem { [weak self, weak anchorView] in
                guard let self, let anchorView, token != self.lastAppliedToken else { return }
                if Self.applyWidth(width, minWidth: minWidth, maxWidth: maxWidth, from: anchorView, anchor: anchorView) {
                    self.lastAppliedToken = token
                }
            }
            pendingRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: retry)
        }

        @discardableResult
        private static func applyWidth(
            _ width: CGFloat,
            minWidth: CGFloat,
            maxWidth: CGFloat,
            from anchorView: NSView,
            anchor: NSView
        ) -> Bool {
            guard let splitView = findSplitView(from: anchorView) else { return false }
            guard splitView.isVertical, splitView.subviews.count >= 2 else { return false }

            let clamped = min(max(width, minWidth), maxWidth)
            (anchor as? SidebarSplitViewAnchorView)?.noteProgrammaticWidth(clamped)
            splitView.setPosition(clamped, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()

            let actualWidth = splitView.subviews[0].frame.width
            return abs(actualWidth - clamped) <= 2.0
        }

        private static func findSplitView(from view: NSView) -> NSSplitView? {
            var candidates: [NSSplitView] = []
            var current: NSView? = view
            while let node = current {
                if let split = node as? NSSplitView, split.isVertical, split.subviews.count >= 2 {
                    candidates.append(split)
                }
                current = node.superview
            }

            for split in candidates where view.isDescendant(of: split.subviews[0]) {
                return split
            }

            if let contentView = view.window?.contentView {
                return findVerticalSplitView(in: contentView, preferContaining: view)
            }
            return candidates.first
        }

        private static func findVerticalSplitView(in view: NSView, preferContaining anchor: NSView) -> NSSplitView? {
            var bestMatch: NSSplitView?
            var firstMatch: NSSplitView?

            func walk(_ node: NSView) {
                if let split = node as? NSSplitView, split.isVertical, split.subviews.count >= 2 {
                    if firstMatch == nil {
                        firstMatch = split
                    }
                    if anchor.isDescendant(of: split.subviews[0]) {
                        bestMatch = split
                    }
                }
                for subview in node.subviews {
                    walk(subview)
                }
            }

            walk(view)
            return bestMatch ?? firstMatch
        }
    }
}

/// Observes divider drags on the jobs-list NSSplitView so auto-resize does not override manual sizing.
final class SidebarSplitViewAnchorView: NSView, NSSplitViewDelegate {
    var onUserResize: (() -> Void)?
    var minimumSidebarWidth: CGFloat = 320 {
        didSet {
            guard abs(minimumSidebarWidth - oldValue) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.clampSidebarToMinimumIfNeeded()
            }
        }
    }

    private weak var observedSplitView: NSSplitView?
    private var lastObservedDividerPosition: CGFloat?
    private var programmaticWidth: CGFloat?

    func noteProgrammaticWidth(_ width: CGFloat) {
        programmaticWidth = width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        guard dividerIndex == 0 else { return proposedMinimumPosition }
        return max(proposedMinimumPosition, minimumSidebarWidth)
    }

    private func clampSidebarToMinimumIfNeeded() {
        guard let splitView = observedSplitView ?? findJobsListSplitView() else { return }
        guard let currentWidth = splitView.subviews.first?.frame.width else { return }
        guard currentWidth < minimumSidebarWidth - 1 else { return }

        noteProgrammaticWidth(minimumSidebarWidth)
        splitView.setPosition(minimumSidebarWidth, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachSplitViewObserverIfNeeded()
    }

    override func layout() {
        super.layout()
        attachSplitViewObserverIfNeeded()
    }

    private func attachSplitViewObserverIfNeeded() {
        guard let splitView = findJobsListSplitView() else { return }
        guard splitView !== observedSplitView else { return }
        observedSplitView?.delegate = nil
        observedSplitView = splitView
        lastObservedDividerPosition = splitView.subviews.first.map(\.frame.width)
        splitView.delegate = self
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let splitView = notification.object as? NSSplitView,
              splitView === observedSplitView,
              let currentWidth = splitView.subviews.first?.frame.width else { return }

        defer { lastObservedDividerPosition = currentWidth }

        if currentWidth < minimumSidebarWidth - 1 {
            noteProgrammaticWidth(minimumSidebarWidth)
            splitView.setPosition(minimumSidebarWidth, ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
            return
        }

        if let programmaticWidth, abs(currentWidth - programmaticWidth) <= 2.0 {
            self.programmaticWidth = nil
            return
        }

        guard let lastWidth = lastObservedDividerPosition else { return }
        guard abs(currentWidth - lastWidth) > 1.0 else { return }
        programmaticWidth = nil
        onUserResize?()
    }

    private func findJobsListSplitView() -> NSSplitView? {
        var current: NSView? = self
        while let node = current {
            if let split = node as? NSSplitView, split.isVertical, split.subviews.count >= 2,
               isDescendant(of: split.subviews[0]) {
                return split
            }
            current = node.superview
        }
        return nil
    }
}
