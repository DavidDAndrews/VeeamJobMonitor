import SwiftUI
import AppKit

// MARK: - Main list view

struct JobsListView: View {
    @ObservedObject var api: VeeamAPIService
    @AppStorage(AppearancePreference.storageKey) private var isDarkModeEnabled = false
    @AppStorage(TextScalePreference.storageKey) private var storedTextScaleFactor = TextScalePreference.defaultFactor

    @State private var searchText = ""
    @State private var selectedJobID: String?
    @State private var leftPaneSort: LeftPaneSort = .jobName
    @State private var leftPaneSortAscending = true
    @State private var selectedStatusFilter: StatusFilter = .all
    @State private var selectedBackupScope: BackupScope = .all
    @State private var activeErrorMessage: String?
    @State private var runningRefreshTask: Task<Void, Never>?
    @State private var activeShareCoordinator: ReportShareCoordinator?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarIdealWidth: CGFloat = 480
    @State private var sidebarWidthApplyToken = 0
    @State private var initialSidebarWidthTask: Task<Void, Never>?
    @State private var hasAppliedInitialSidebarWidth = false
    @State private var userHasManuallyResizedSidebar = false
    @State private var showPaneRefreshAnimation = false
    @State private var paneLoadingTitle = "Retrieving Server Information"
    @State private var paneLoadingSubtitle = "Please wait..."
    @State private var paneLoadingProgressPercent: Int?
    @State private var showReportReadyToast = false

    private var scopeAndSearchFilteredJobs: [VeeamJob] {
        api.jobs.filter { job in
            guard matchesBackupTypeFilter(job) else { return false }

            if searchText.isEmpty {
                return true
            }

            let matchesName = job.name.localizedCaseInsensitiveContains(searchText)
            let matchesDescription = job.jobDescription?.localizedCaseInsensitiveContains(searchText) ?? false
            let matchesType = job.jobType.localizedCaseInsensitiveContains(searchText)
            let matchesResult = job.resultText.localizedCaseInsensitiveContains(searchText)
            let matchesRepository = job.repositoryName?.localizedCaseInsensitiveContains(searchText) ?? false

            return matchesName || matchesDescription || matchesType || matchesResult || matchesRepository
        }
    }

    private var filteredJobs: [VeeamJob] {
        let base = scopeAndSearchFilteredJobs.filter { matchesResultFilter($0) }
        return base.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch leftPaneSort {
            case .jobName:
                comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            case .status:
                comparison = statusSortText(for: lhs).localizedCaseInsensitiveCompare(statusSortText(for: rhs))
            }
            if leftPaneSortAscending {
                return comparison == .orderedAscending
            }
            return comparison == .orderedDescending
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarPane
        } detail: {
            detailPaneContent
                .appTextScale(textScaleFactor, detailTextBonus: 2)
        }
        .background {
            SidebarToggleWindowFrameController(
                columnVisibility: columnVisibility,
                fallbackSidebarWidth: sidebarIdealWidth,
                minimumSidebarWidth: sidebarColumnMinWidth
            )
        }
        .onChange(of: columnVisibility) { oldValue, newValue in
            handleColumnVisibilityChange(from: oldValue, to: newValue)
        }
        .onAppear {
            ensureWindowFitsSidebarToolbarFloor()
            ensureSidebarMeetsToolbarFloor()
            refresh()
            startRunningJobsAutoRefresh()
        }
        .onDisappear {
            runningRefreshTask?.cancel()
            runningRefreshTask = nil
            initialSidebarWidthTask?.cancel()
            initialSidebarWidthTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshJobs)) { _ in refresh() }
        .onChange(of: api.errorMessage) { _, newValue in
            if let newValue, !newValue.isEmpty {
                activeErrorMessage = newValue
            }
        }
        .onReceive(api.$jobs) { _ in
            ensureInitialSelection()
        }
        .onChange(of: selectedJobID) { _, newValue in
            handleSelectedJobIDChanged(newValue)
        }
        .onChange(of: selectedStatusFilter) { _, _ in
            selectFirstJobInFilteredList()
        }
        .onChange(of: selectedBackupScope) { _, _ in
            selectFirstJobInFilteredList()
        }
        .onChange(of: api.isRefreshingJobs) { _, isRefreshing in
            handleRefreshingChanged(isRefreshing)
        }
        .onChange(of: api.loadingProgressPercent) { _, newValue in
            handleLoadingProgressChanged(newValue)
        }
        .onChange(of: storedTextScaleFactor) { _, _ in
            handleTextScaleChanged()
        }
        .alert("Error", isPresented: errorAlertIsPresented) {
            Button("OK") {
                activeErrorMessage = nil
                api.errorMessage = nil
            }
        } message: {
            errorAlertMessageView
        }
        .overlay(alignment: .topTrailing) {
            reportReadyToastOverlay
        }
    }

    @ViewBuilder
    private var reportReadyToastOverlay: some View {
        if showReportReadyToast {
            ReportReadyToastView(textScaleFactor: textScaleFactor)
                .padding(.top, 14)
                .padding(.trailing, 18)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var textScaleFactor: CGFloat {
        TextScalePreference.clamped(storedTextScaleFactor)
    }

    private var errorAlertIsPresented: Binding<Bool> {
        Binding(
            get: { activeErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    activeErrorMessage = nil
                    api.errorMessage = nil
                }
            }
        )
    }

    private var errorAlertMessageView: Text {
        Text(activeErrorMessage ?? "")
    }

    private var sidebarJobsListView: some View {
        ScrollViewReader { proxy in
            List(filteredJobs, selection: $selectedJobID) { job in
                jobRow(for: job)
            }
            .listStyle(.inset)
            .onChange(of: selectedJobID) { _, newValue in
                handleSelectedJobChange(newValue, proxy: proxy)
            }
        }
    }

    private var sidebarPane: some View {
        VStack(spacing: 0) {
            Text("Backup Jobs")
                .font(Font.scaledText(.title3, scale: textScaleFactor, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if !api.jobs.isEmpty {
                StatusSummaryBar(
                    jobs: api.jobs,
                    filteredByScopeAndSearch: scopeAndSearchFilteredJobs,
                    selectedStatusFilter: $selectedStatusFilter,
                    selectedBackupScope: $selectedBackupScope
                )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                HStack(spacing: 12) {
                    Button(action: { toggleLeftPaneSort(.jobName) }) {
                        HStack(spacing: 3) {
                            Text("Job Name")
                                .font(Font.scaledText(.caption, scale: textScaleFactor, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            if leftPaneSort == .jobName {
                                Image(systemName: leftPaneSortAscending ? "chevron.up" : "chevron.down")
                                    .font(Font.scaledSystem(size: 8, weight: .semibold, scale: textScaleFactor))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sort jobs by name. Click again to reverse the order.")
                    Spacer()
                    Button(action: { toggleLeftPaneSort(.status) }) {
                        HStack(spacing: 3) {
                            Text("Current Job Status")
                                .font(Font.scaledText(.caption, scale: textScaleFactor, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            if leftPaneSort == .status {
                                Image(systemName: leftPaneSortAscending ? "chevron.up" : "chevron.down")
                                    .font(Font.scaledSystem(size: 8, weight: .semibold, scale: textScaleFactor))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Sort jobs by current status. Click again to reverse the order.")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
            }

            sidebarJobsListView
        }
        .navigationSplitViewColumnWidth(
            min: sidebarColumnMinWidth,
            ideal: sidebarIdealWidth,
            max: Self.sidebarColumnMaxWidth
        )
        .background {
            SidebarSplitViewWidthApplier(
                width: sidebarIdealWidth,
                minWidth: sidebarColumnMinWidth,
                maxWidth: Self.sidebarColumnMaxWidth,
                applyToken: sidebarWidthApplyToken,
                columnVisibility: columnVisibility,
                onUserResize: { userHasManuallyResizedSidebar = true }
            )
        }
        .searchable(text: $searchText, prompt: "Search jobs")
        .toolbar {
            mainToolbarContent
        }
        .overlay { sidebarEmptyStateOverlay }
        .appTextScale(textScaleFactor)
    }

    @ViewBuilder
    private var sidebarEmptyStateOverlay: some View {
        if api.jobs.isEmpty && !api.isRefreshingJobs {
            ContentUnavailableView(
                "No Jobs Found",
                systemImage: "externaldrive",
                description: Text("No backup jobs are available on this server.")
            )
        }
    }

    @ViewBuilder
    private var detailPaneContent: some View {
        if showPaneRefreshAnimation || (api.isRefreshingJobs && api.jobs.isEmpty) {
            ServerLoadingView(
                title: paneLoadingTitle,
                subtitle: paneLoadingSubtitle,
                progressPercent: paneLoadingProgressPercent
            )
        } else if let id = selectedJobID, let job = api.jobs.first(where: { $0.id == id }) {
            JobDetailView(job: job, api: api)
        } else {
            ContentUnavailableView(
                "Select a Job",
                systemImage: "list.bullet.rectangle",
                description: Text("Choose a backup job from the list.")
            )
        }
    }

    @ToolbarContentBuilder
    private var mainToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: refresh) {
                ToolbarIcon(symbol: "arrow.clockwise")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(api.isRefreshingJobs)
            .help("Refresh all jobs and backup-point details from the server.")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: { Task { await exportHTMLReport() } }) {
                ToolbarIcon(symbol: "doc.badge.arrow.up")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(api.jobs.isEmpty)
            .help("Generate and open an HTML backup report.")
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: { Task { await shareHTMLReport() } }) {
                ToolbarIcon(symbol: "square.and.arrow.up")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(api.jobs.isEmpty)
            .help("Share the HTML backup report by email, message, or other share targets.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: decreaseTextScale) {
                ToolbarIcon(symbol: "textformat.size.smaller")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(!canDecreaseTextScale)
            .help("Decrease text size in the jobs list and detail panes.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: resetTextScale) {
                ToolbarIcon(symbol: "arrow.counterclockwise")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(!canResetTextScale)
            .help("Reset text size to the default.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: increaseTextScale) {
                ToolbarIcon(symbol: "textformat.size.larger")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .disabled(!canIncreaseTextScale)
            .help("Increase text size in the jobs list and detail panes.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { isDarkModeEnabled.toggle() }) {
                ToolbarIcon(symbol: isDarkModeEnabled ? "sun.max.fill" : "moon.fill")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .help(isDarkModeEnabled ? "Switch to light mode." : "Switch to dark mode.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { api.logout() }) {
                ToolbarIcon(symbol: "server.rack")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .help("Return to the server connection screen.")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: { NSApp.terminate(nil) }) {
                ToolbarIcon(symbol: "power")
            }
            .buttonStyle(ToolbarHover3DButtonStyle())
            .help("Quit the application.")
        }
        if api.isRefreshingJobs || api.isPerformingAction {
            ToolbarItem(placement: .automatic) {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func handleSelectedJobChange(_ newValue: String?, proxy: ScrollViewProxy) {
        guard let firstID = filteredJobs.first?.id, newValue == firstID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(firstID, anchor: .top)
            }
        }
    }

    private func handleColumnVisibilityChange(
        from oldValue: NavigationSplitViewVisibility,
        to newValue: NavigationSplitViewVisibility
    ) {
        if newValue == .detailOnly {
            initialSidebarWidthTask?.cancel()
        } else if oldValue == .detailOnly {
            reapplySidebarWidthAfterShow()
        }
    }

    private func handleSelectedJobIDChanged(_ newValue: String?) {
        guard let newValue else { return }
        Task { await api.loadJobConfigDetails(for: newValue) }
    }

    private func handleRefreshingChanged(_ isRefreshing: Bool) {
        guard isRefreshing == false else { return }
        if !api.jobs.isEmpty {
            scheduleInitialSidebarWidthAfterConfigs()
        }
        if showPaneRefreshAnimation {
            showPaneRefreshAnimation = false
        }
        if let selectedJobID {
            Task { await api.loadJobConfigDetails(for: selectedJobID, force: true) }
        }
    }

    private func handleLoadingProgressChanged(_ newValue: Int?) {
        if api.isRefreshingJobs && paneLoadingTitle == "Retrieving Server Information" {
            paneLoadingProgressPercent = newValue
        }
    }

    private func handleTextScaleChanged() {
        ensureSidebarMeetsToolbarFloor()
        applySidebarWidthForTextScale()
    }

    private var canDecreaseTextScale: Bool {
        TextScalePreference.canDecrease(storedTextScaleFactor)
    }

    private var canIncreaseTextScale: Bool {
        TextScalePreference.canIncrease(storedTextScaleFactor)
    }

    private var canResetTextScale: Bool {
        !TextScalePreference.isAtDefault(storedTextScaleFactor)
    }

    private func decreaseTextScale() {
        guard canDecreaseTextScale else { return }
        storedTextScaleFactor = TextScalePreference.decreased(from: storedTextScaleFactor)
        applySidebarWidthForTextScale()
    }

    private func increaseTextScale() {
        guard canIncreaseTextScale else { return }
        storedTextScaleFactor = TextScalePreference.increased(from: storedTextScaleFactor)
        applySidebarWidthForTextScale()
    }

    private func resetTextScale() {
        guard canResetTextScale else { return }
        storedTextScaleFactor = TextScalePreference.defaultFactor
        applySidebarWidthForTextScale()
    }

    /// Upper bound for divider drag; content-based initial width is not capped here.
    private static let sidebarColumnMaxWidth: CGFloat = 2400

    /// Absolute lower bound for the jobs sidebar column; matches toolbar icon + search fit at the current text scale.
    private var sidebarColumnMinWidth: CGFloat {
        Self.sidebarColumnMinimumWidth(for: textScaleFactor)
    }

    /// Floor width for manual divider drag and `navigationSplitViewColumnWidth(min:)`.
    private static func sidebarColumnMinimumWidth(for textScale: CGFloat) -> CGFloat {
        sidebarToolbarMinimumWidth(for: textScale)
    }

    /// Floor width for the jobs sidebar toolbar row (icon buttons + search) so controls are not clipped.
    private static func sidebarToolbarMinimumWidth(for textScale: CGFloat) -> CGFloat {
        // Keep in sync with toolbar ToolbarItem list, ToolbarIcon, ToolbarHover3DButtonStyle, and `.searchable`.
        // Title lives in sidebar content, not the unified toolbar — only sidebar toggle + icons + search compete.
        let iconWidth: CGFloat = 13 * textScale
        let buttonHorizontalPadding: CGFloat = 12
        let iconButtonWidth = iconWidth + buttonHorizontalPadding
        let toolbarItemSpacing: CGFloat = 8
        let toolbarPlacementGroupSpacing: CGFloat = 16
        let searchFieldMinimumWidth: CGFloat = 160
        let toolbarHorizontalMargin: CGFloat = 24
        let sidebarToggleWidth: CGFloat = 36

        // Nine toolbar buttons: Refresh/Report/Share (primaryAction) + six automatic items including Reset.
        let toolbarButtonCount = 9
        let buttonsRowWidth = iconButtonWidth * CGFloat(toolbarButtonCount)
            + toolbarItemSpacing * CGFloat(toolbarButtonCount - 1)
            + toolbarPlacementGroupSpacing
        return sidebarToggleWidth + buttonsRowWidth + searchFieldMinimumWidth + toolbarHorizontalMargin
    }

    private func refresh() {
        hasAppliedInitialSidebarWidth = false
        userHasManuallyResizedSidebar = false
        paneLoadingTitle = "Retrieving Server Information"
        paneLoadingSubtitle = "Please wait..."
        paneLoadingProgressPercent = api.loadingProgressPercent
        showPaneRefreshAnimation = true
        Task {
            await api.fetchJobs(reloadBackupInventory: true)
            await MainActor.run {
                paneLoadingProgressPercent = nil
                showPaneRefreshAnimation = false
                ensureInitialSelection()
                if !api.jobs.isEmpty {
                    scheduleInitialSidebarWidthAfterConfigs()
                }
            }
        }
    }

    private func ensureInitialSelection() {
        if let selectedJobID, filteredJobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        selectedJobID = filteredJobs.first?.id
    }

    private func selectFirstJobInFilteredList() {
        selectedJobID = filteredJobs.first?.id
    }

    private func toggleLeftPaneSort(_ sort: LeftPaneSort) {
        if leftPaneSort == sort {
            leftPaneSortAscending.toggle()
        } else {
            leftPaneSort = sort
            leftPaneSortAscending = true
        }
        selectFirstJobInFilteredList()
    }

    private func statusSortText(for job: VeeamJob) -> String {
        if job.isRunning { return job.runningStatusText }
        return job.resultText
    }

    @ViewBuilder
    private func jobRow(for job: VeeamJob) -> some View {
        let isSelected = selectedJobID == job.id
        JobRowView(job: job, isSelected: isSelected)
            .tag(job.id)
            .listRowBackground(
                isSelected
                    ? RoundedRectangle(cornerRadius: Theme.Radius.small)
                        .fill(Theme.listRowSelectedBackground)
                    : nil
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .contextMenu {
                Button("Start Job") { Task { await api.startJob(job) } }
                Button("Start Active Full") { Task { await api.startActiveFullJob(job) } }
                Button("Stop Job") { Task { await api.stopJob(job) } }
                Button("Retry Job") { Task { await api.retryJob(job) } }
                Divider()
                Button("Enable Job") { Task { await api.enableJob(job) } }
                Button("Disable Job") { Task { await api.disableJob(job) } }
            }
            .help("Job: \(job.displayName). Current result: \(job.resultText). Right-click for job actions.")
    }

    @MainActor
    private func exportHTMLReport() async {
        let previousSelectedJobID = selectedJobID
        paneLoadingTitle = "Generating Backup Report"
        paneLoadingSubtitle = "Please wait..."
        paneLoadingProgressPercent = 0
        showPaneRefreshAnimation = true
        api.isGeneratingReport = true
        defer { api.isGeneratingReport = false }

        let safeServerName = api.connectedServerDisplayName
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = "VeeamBackup - \(safeServerName).html"
        let contexts = await buildReportJobContexts { percent in
            paneLoadingProgressPercent = max(0, min(90, percent))
        }
        paneLoadingProgressPercent = 94
        let html = HTMLReportGenerator(
            serverDisplayName: api.connectedServerDisplayName,
            jobsCount: api.jobs.count
        ).makeHTML(contexts: contexts)

        guard let downloadsDirectory = ReportExportPaths.downloadsDirectory else {
            activeErrorMessage = "Report export failed: Downloads folder is unavailable."
            paneLoadingProgressPercent = nil
            showPaneRefreshAnimation = false
            return
        }
        let fileURL = downloadsDirectory.appendingPathComponent(fileName)

        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            paneLoadingProgressPercent = 100
            NSWorkspace.shared.open(fileURL)
            showReportGeneratedNotification()
        } catch {
            if isPermissionError(error) {
                requestFolderPermissionAndExport(fileName: fileName, html: html)
            } else {
                activeErrorMessage = "Report export failed: \(error.localizedDescription)"
            }
        }

        if let previousSelectedJobID, api.jobs.contains(where: { $0.id == previousSelectedJobID }) {
            selectedJobID = previousSelectedJobID
        }
        paneLoadingProgressPercent = nil
        showPaneRefreshAnimation = false
    }

    @MainActor
    private func shareHTMLReport() async {
        paneLoadingTitle = "Generating Backup Report"
        paneLoadingSubtitle = "Please wait..."
        paneLoadingProgressPercent = 0
        showPaneRefreshAnimation = true
        api.isGeneratingReport = true
        defer { api.isGeneratingReport = false }

        let safeServerName = api.connectedServerDisplayName
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = "VeeamBackup - \(safeServerName).html"
        let contexts = await buildReportJobContexts { percent in
            paneLoadingProgressPercent = max(0, min(90, percent))
        }
        paneLoadingProgressPercent = 94
        let html = HTMLReportGenerator(
            serverDisplayName: api.connectedServerDisplayName,
            jobsCount: api.jobs.count
        ).makeHTML(contexts: contexts)
        guard let downloadsDirectory = ReportExportPaths.downloadsDirectory else {
            activeErrorMessage = "Report share failed: Downloads folder is unavailable."
            paneLoadingProgressPercent = nil
            showPaneRefreshAnimation = false
            return
        }
        let fileURL = downloadsDirectory.appendingPathComponent(fileName)

        do {
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
            paneLoadingProgressPercent = 100
            presentSharePicker(for: fileURL)
        } catch {
            if isPermissionError(error) {
                requestFolderPermissionAndShare(fileName: fileName, html: html)
            } else {
                activeErrorMessage = "Report share failed: \(error.localizedDescription)"
            }
        }
        paneLoadingProgressPercent = nil
        showPaneRefreshAnimation = false
    }

    @MainActor
    private func requestFolderPermissionAndShare(fileName: String, html: String) {
        endTextInputSessionIfNeeded()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Veeam Monitor needs folder access to prepare a shareable HTML report."
        panel.prompt = "Use This Folder"
        panel.directoryURL = ReportExportPaths.downloadsDirectory

        if panel.runModal() == .OK, let folderURL = panel.url {
            ReportExportPaths.writeHTMLReport(html, fileName: fileName, to: folderURL) { result in
                switch result {
                case .success(let destination):
                    presentSharePicker(for: destination)
                case .failure(let error):
                    activeErrorMessage = "Report share failed: \(error.localizedDescription)"
                }
            }
        } else {
            activeErrorMessage = "Report share cancelled. Folder permission was not granted."
        }
    }

    @MainActor
    private func presentSharePicker(for fileURL: URL) {
        endTextInputSessionIfNeeded()
        guard let contentView = NSApp.keyWindow?.contentView else {
            activeErrorMessage = "Unable to present share options right now."
            return
        }

        let coordinator = ReportShareCoordinator(
            fileURL: fileURL,
            onError: { message in
                self.activeErrorMessage = message
                self.activeShareCoordinator = nil
            },
            onFinish: {
                self.activeShareCoordinator = nil
            }
        )
        activeShareCoordinator = coordinator

        let picker = NSSharingServicePicker(items: [fileURL])
        picker.delegate = coordinator
        let rect = NSRect(
            x: contentView.bounds.midX - 1,
            y: contentView.bounds.maxY - 1,
            width: 2,
            height: 2
        )
        DispatchQueue.main.async {
            picker.show(relativeTo: rect, of: contentView, preferredEdge: .maxY)
        }
    }

    @MainActor
    private func requestFolderPermissionAndExport(fileName: String, html: String) {
        endTextInputSessionIfNeeded()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Veeam Monitor needs permission to save the HTML report."
        panel.prompt = "Use This Folder"
        panel.directoryURL = ReportExportPaths.downloadsDirectory

        if panel.runModal() == .OK, let folderURL = panel.url {
            ReportExportPaths.writeHTMLReport(html, fileName: fileName, to: folderURL) { result in
                switch result {
                case .success(let destination):
                    NSWorkspace.shared.open(destination)
                    showReportGeneratedNotification()
                case .failure(let error):
                    activeErrorMessage = "Report export failed: \(error.localizedDescription)"
                }
            }
        } else {
            activeErrorMessage = "Report export cancelled. Folder permission was not granted."
        }
    }

    @MainActor
    private func showReportGeneratedNotification() {
        withAnimation(.easeOut(duration: 0.18)) {
            showReportReadyToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeIn(duration: 0.16)) {
                showReportReadyToast = false
            }
        }
    }

    @MainActor
    private func endTextInputSessionIfNeeded() {
        guard let window = NSApp.keyWindow else { return }
        // Commit and end active text editing before presenting remote view services
        // (share picker/open panel) to avoid benign ViewBridge cancellation noise.
        window.makeFirstResponder(nil)
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileWriteNoPermissionError ||
                nsError.code == NSFileReadNoPermissionError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == EACCES || nsError.code == EPERM
        }
        return false
    }

    private func buildReportJobContexts(onProgress: @escaping (Int) -> Void) async -> [HTMLReportGenerator.JobContext] {
        onProgress(3)
        await api.ensureAllJobConfigsLoaded()
        onProgress(10)
        let summariesByJobID = await api.fetchLatestJobRunLogSummaries(for: api.jobs) { logProgress in
            onProgress(10 + Int((Double(logProgress) / 85.0 * 80.0).rounded()))
        }
        return api.jobs.map { job in
            HTMLReportGenerator.JobContext(job: job, summary: summariesByJobID[job.id] ?? nil)
        }
    }

    private func startRunningJobsAutoRefresh() {
        runningRefreshTask?.cancel()
        runningRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                if api.jobs.contains(where: { $0.isRunning }) {
                    await api.refreshJobsIfRunningProgressChanged()
                }
            }
        }
    }

    /// One-shot auto-resize after job configs finish loading (descriptions included).
    private func scheduleInitialSidebarWidthAfterConfigs() {
        guard !hasAppliedInitialSidebarWidth, !userHasManuallyResizedSidebar, !api.jobs.isEmpty else { return }

        initialSidebarWidthTask?.cancel()
        initialSidebarWidthTask = Task { @MainActor in
            await api.ensureAllJobConfigsLoaded()
            guard !Task.isCancelled, !userHasManuallyResizedSidebar else { return }
            applyContentBasedSidebarWidth(markInitialApplied: false)

            // NavigationSplitView may not have created its NSSplitView yet on first layout.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, !userHasManuallyResizedSidebar else { return }
            applyContentBasedSidebarWidth(markInitialApplied: true)
        }
    }

    private func applySidebarWidthForTextScale() {
        guard !api.jobs.isEmpty, !userHasManuallyResizedSidebar else { return }
        applyContentBasedSidebarWidth(markInitialApplied: false)
    }

    /// Expands the outer window when a saved frame is narrower than the jobs toolbar floor plus detail pane.
    private func ensureWindowFitsSidebarToolbarFloor() {
        let sidebarFloor = sidebarColumnMinWidth
        let detailMinimum: CGFloat = 360
        let requiredWidth = sidebarFloor + detailMinimum

        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            guard window.frame.width < requiredWidth - 0.5 else { return }

            var frame = window.frame
            frame.size.width = requiredWidth
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// Keeps programmatic sidebar width at or above the toolbar floor (including before jobs load).
    private func ensureSidebarMeetsToolbarFloor(reapply: Bool = false) {
        let floor = sidebarColumnMinWidth
        var didChangeIdeal = false
        if sidebarIdealWidth < floor - 0.5 {
            sidebarIdealWidth = floor
            didChangeIdeal = true
        }
        if reapply || didChangeIdeal {
            sidebarWidthApplyToken &+= 1
        }
    }

    /// Re-applies sidebar width after the jobs pane is shown again so toolbar icons are never clipped.
    private func reapplySidebarWidthAfterShow() {
        ensureSidebarMeetsToolbarFloor(reapply: true)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard columnVisibility != .detailOnly else { return }
            ensureSidebarMeetsToolbarFloor(reapply: true)
        }
    }

    private func applyContentBasedSidebarWidth(markInitialApplied: Bool) {
        guard !api.jobs.isEmpty else { return }
        if userHasManuallyResizedSidebar { return }
        if hasAppliedInitialSidebarWidth, markInitialApplied { return }

        let target = Self.resolvedSidebarWidth(for: api.jobs, textScale: textScaleFactor)

        guard abs(sidebarIdealWidth - target) > 0.5 else {
            if markInitialApplied { hasAppliedInitialSidebarWidth = true }
            return
        }

        sidebarIdealWidth = target
        sidebarWidthApplyToken &+= 1
        if markInitialApplied { hasAppliedInitialSidebarWidth = true }
    }

    private static func rowSubtitle(for job: VeeamJob) -> String {
        var parts = [job.jobType]
        if let repositoryName = job.repositoryName, !repositoryName.isEmpty {
            parts.append(repositoryName)
        }
        if let objectsCount = job.objectsCount {
            parts.append("\(objectsCount) objects")
        }
        if let lastRun = job.lastRun {
            parts.append(RelativeTimeFormatter.shared.localizedString(for: lastRun, relativeTo: Date()))
        }
        return parts.joined(separator: " • ")
    }

    /// Content width clamped to the toolbar floor so auto-resize never hides toolbar icons.
    private static func resolvedSidebarWidth(for jobs: [VeeamJob], textScale: CGFloat) -> CGFloat {
        max(contentBasedSidebarWidth(for: jobs, textScale: textScale), sidebarToolbarMinimumWidth(for: textScale))
    }

    /// Width needed to show the widest job name + description (`displayName`) and row metadata without clipping.
    private static func contentBasedSidebarWidth(for jobs: [VeeamJob], textScale: CGFloat = 1.0) -> CGFloat {
        guard !jobs.isEmpty else { return 480 }

        // Match JobRowView typography: callout medium title, caption subtitle, caption2 badge.
        let titleFont = sidebarMeasurementFont(style: .callout, weight: .medium, textScale: textScale)
        let subtitleFont = sidebarMeasurementFont(style: .caption, weight: .regular, textScale: textScale)
        let badgeFont = sidebarMeasurementFont(style: .caption2, weight: .semibold, textScale: textScale)

        let maxTitleWidth = jobs.map {
            ($0.displayName as NSString).size(withAttributes: [.font: titleFont]).width
        }.max() ?? 260

        let maxSubtitleWidth = jobs.map { job in
            (rowSubtitle(for: job) as NSString).size(withAttributes: [.font: subtitleFont]).width
        }.max() ?? 220

        let maxBadgeWidth = jobs.map { job in
            let badgeText = job.isRunning ? job.runningStatusText : job.resultText
            let textWidth = (badgeText as NSString).size(withAttributes: [.font: badgeFont]).width
            // Icon (9pt scaled) + HStack spacing + horizontal badge padding (Theme.Spacing.sm each side).
            return textWidth + (9 * textScale) + 4 + (Theme.Spacing.sm * 2)
        }.max() ?? 88

        let contentWidth = max(maxTitleWidth, maxSubtitleWidth)
        // Status dot, HStack spacing (Theme.Spacing.md × 2), list insets, trailing badge, and layout fudge.
        let chromeWidth: CGFloat = 18 + (Theme.Spacing.md * 2) + 24 + maxBadgeWidth + 20
        return contentWidth + chromeWidth
    }

    /// Maps app text scale to NSFont sizes aligned with JobRowView scaled typography.
    private static func sidebarMeasurementFont(style: ScaledTextStyle, weight: NSFont.Weight, textScale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: style.baseSize * textScale, weight: weight)
    }

    private func matchesResultFilter(_ job: VeeamJob) -> Bool {
        if selectedStatusFilter == .all {
            return true
        }
        switch jobResultBucket(for: job) {
        case .running:
            return selectedStatusFilter == .running
        case .success:
            return selectedStatusFilter == .success
        case .warning:
            return selectedStatusFilter == .warning
        case .failed:
            return selectedStatusFilter == .failed
        case .disabled:
            return selectedStatusFilter == .disabled
        case .unknown:
            return false
        }
    }

    private func matchesBackupTypeFilter(_ job: VeeamJob) -> Bool {
        switch selectedBackupScope {
        case .all:
            return true
        case .regular:
            return !isCopyJob(job)
        case .copy:
            return isCopyJob(job)
        }
    }

    private func isCopyJob(_ job: VeeamJob) -> Bool {
        job.jobType.localizedCaseInsensitiveContains("copy")
    }
}

// MARK: - Sidebar toggle window frame (AppKit)

/// Keeps the outer window frame stable when the jobs sidebar is hidden or shown.
/// NavigationSplitView collapses the sidebar column but does not shrink or restore the NSWindow frame.
private struct SidebarToggleWindowFrameController: NSViewRepresentable {
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
private struct SidebarSplitViewWidthApplier: NSViewRepresentable {
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
private final class SidebarSplitViewAnchorView: NSView, NSSplitViewDelegate {
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

private enum LeftPaneSort {
    case jobName
    case status
}

private struct ToolbarIcon: View {
    let symbol: String
    @Environment(\.textScaleFactor) private var textScaleFactor

    var body: some View {
        Image(systemName: symbol)
            .font(Font.scaledSystem(size: 13, weight: .semibold, scale: textScaleFactor))
            .frame(width: 13 * textScaleFactor, height: 13 * textScaleFactor)
    }
}

private struct ToolbarHover3DButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToolbarHover3DButtonBody(configuration: configuration)
    }
}

private struct ToolbarHover3DButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small)
                    .fill(isHovered ? Theme.brandTint : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered ? 1.02 : 1.0))
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

private struct ServerLoadingView: View {
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

// MARK: - Report export paths (App Sandbox)

/// Resolves sandbox-permitted report destinations instead of hard-coded home paths.
private enum ReportExportPaths {
    static var downloadsDirectory: URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    static func writeHTMLReport(
        _ html: String,
        fileName: String,
        to folderURL: URL,
        completion: (Result<URL, Error>) -> Void
    ) {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let destination = folderURL.appendingPathComponent(fileName)
        do {
            try html.write(to: destination, atomically: true, encoding: .utf8)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
        }
    }
}

private final class ReportShareCoordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let fileURL: URL
    private let onError: (String) -> Void
    private let onFinish: () -> Void

    init(fileURL: URL, onError: @escaping (String) -> Void, onFinish: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onError = onError
        self.onFinish = onFinish
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        if sharingService.subject == nil || sharingService.subject?.isEmpty == true {
            sharingService.subject = "VEEAM BACKUP REPORT"
        }
        return self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        scheduleCleanupExportFile()
        onFinish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        onError("Report share failed: \(error.localizedDescription)")
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if let service {
            if service.subject == nil || service.subject?.isEmpty == true {
                service.subject = "VEEAM BACKUP REPORT"
            }
        } else {
            onFinish()
        }
    }

    private func scheduleCleanupExportFile() {
        // Some share services (notably Messages) may still need the source file
        // briefly after didShareItems fires. Delay deletion to avoid empty sends.
        let fileURL = self.fileURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                self.onError("Report shared, but cleanup failed: \(error.localizedDescription)")
            }
        }
    }
}


// MARK: - Status Summary Bar

private struct StatusSummaryBar: View {
    let jobs: [VeeamJob]
    let filteredByScopeAndSearch: [VeeamJob]
    @Binding var selectedStatusFilter: StatusFilter
    @Binding var selectedBackupScope: BackupScope

    private var runningCount: Int { filteredByScopeAndSearch.filter { jobResultBucket(for: $0) == .running }.count }
    private var successCount: Int { filteredByScopeAndSearch.filter { jobResultBucket(for: $0) == .success }.count }
    private var warningCount: Int { filteredByScopeAndSearch.filter { jobResultBucket(for: $0) == .warning }.count }
    private var failedCount: Int { filteredByScopeAndSearch.filter { jobResultBucket(for: $0) == .failed }.count }
    private var disabledCount: Int { filteredByScopeAndSearch.filter { jobResultBucket(for: $0) == .disabled }.count }
    private var regularCount: Int { jobs.filter { !isCopyJob($0) }.count }
    private var copyCount: Int { jobs.filter { isCopyJob($0) }.count }

    var body: some View {
        HStack(spacing: 6) {
            FilterChipWithLegend(
                legend: "ALL",
                label: "\(jobs.count)",
                color: Theme.textPrimary,
                selectedTextColor: Theme.surface,
                isSelected: selectedStatusFilter == .all
            ) {
                selectedStatusFilter = .all
            }
            FilterChipWithLegend(
                legend: "RUN",
                label: "\(runningCount)",
                color: Theme.statusRunning,
                isSelected: selectedStatusFilter == .running
            ) {
                selectedStatusFilter = .running
            }
            FilterChipWithLegend(
                legend: "OK",
                label: "\(successCount)",
                color: Theme.statusSuccess,
                isSelected: selectedStatusFilter == .success
            ) {
                selectedStatusFilter = .success
            }
            FilterChipWithLegend(
                legend: "WRN",
                label: "\(warningCount)",
                color: Theme.statusWarning,
                isSelected: selectedStatusFilter == .warning
            ) {
                selectedStatusFilter = .warning
            }
            FilterChipWithLegend(
                legend: "FAIL",
                label: "\(failedCount)",
                color: Theme.statusFailed,
                isSelected: selectedStatusFilter == .failed
            ) {
                selectedStatusFilter = .failed
            }
            FilterChipWithLegend(
                legend: "DIS",
                label: "\(disabledCount)",
                color: Theme.statusDisabled,
                isSelected: selectedStatusFilter == .disabled
            ) {
                selectedStatusFilter = .disabled
            }
            BackupScopeToggle(
                regularCount: regularCount,
                copyCount: copyCount,
                selectedBackupScope: $selectedBackupScope
            )
            Spacer()
        }
    }

    private func isCopyJob(_ job: VeeamJob) -> Bool {
        job.jobType.localizedCaseInsensitiveContains("copy")
    }
}

private struct FilterChipWithLegend: View {
    let legend: String
    let label: String
    let color: Color
    var selectedTextColor: Color = .white
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.textScaleFactor) private var textScaleFactor

    var body: some View {
        VStack(spacing: 2) {
            FilterChip(label: label, color: color, selectedTextColor: selectedTextColor, isSelected: isSelected, action: action)
            Text(legend)
                .font(Font.scaledSystem(size: 8, weight: .semibold, scale: textScaleFactor))
                .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(Theme.textSecondary))
        }
        .help(legendTooltip)
    }

    private var legendTooltip: String {
        switch legend {
        case "ALL": return "Show all jobs for the selected scope."
        case "RUN": return "Show only jobs currently running."
        case "OK": return "Show only jobs whose latest run result is success."
        case "WRN": return "Show only jobs whose latest run finished with a warning."
        case "FAIL": return "Show only jobs whose latest run failed or returned an error."
        case "DIS": return "Show only jobs that are disabled."
        default: return "Filter jobs by status."
        }
    }
}

private enum BackupScope {
    case all
    case regular
    case copy
}

private struct FilterChip: View {
    let label: String
    let color: Color
    var selectedTextColor: Color = .white
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.textScaleFactor) private var textScaleFactor

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Font.scaledText(.caption2, scale: textScaleFactor, weight: .bold).monospacedDigit())
                .foregroundStyle(isSelected ? selectedTextColor : color)
                .frame(width: 24 * textScaleFactor, height: 24 * textScaleFactor)
                .background((isSelected ? color : color.opacity(0.14)), in: Circle())
            .overlay(
                Circle()
                    .stroke(color.opacity(isSelected ? 0.0 : 0.28), lineWidth: 1)
            )
            .shadow(color: isSelected ? color.opacity(0.35) : .clear, radius: isSelected ? 3 : 0, y: 1)
        }
        .buttonStyle(.plain)
        .help("Show jobs for this status")
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

private struct BackupScopeToggle: View {
    let regularCount: Int
    let copyCount: Int
    @Binding var selectedBackupScope: BackupScope

    var body: some View {
        Picker("Backup Scope", selection: $selectedBackupScope) {
            Text("ALL").tag(BackupScope.all)
            Text("BACKUP \(regularCount)").tag(BackupScope.regular)
            Text("COPY \(copyCount)").tag(BackupScope.copy)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 310)
        .help("Choose which job types to show: all jobs, only backup jobs, or only backup copy jobs.")
    }
}

private struct SummaryChip: View {
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(label)
                .font(.caption2.monospacedDigit())
                .fontWeight(.semibold)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

private struct ReportReadyToastView: View {
    let textScaleFactor: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.brand)
            Text("Report generated and opened")
                .font(Font.scaledText(.subheadline, scale: textScaleFactor, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 0.5)
        )
        .shadow(
            color: Theme.shadowElevated.color,
            radius: Theme.shadowElevated.radius,
            x: Theme.shadowElevated.x,
            y: Theme.shadowElevated.y
        )
    }
}
