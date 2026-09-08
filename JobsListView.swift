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

            return matchesJobNameOrDescriptionSearch(job)
        }
    }

    /// True when search is empty or the query is contained in the job name or description (case-insensitive).
    private func matchesJobNameOrDescriptionSearch(_ job: VeeamJob) -> Bool {
        job.matchesNameOrDescriptionSearch(searchText)
    }

    private func reconcileSelectionAfterFilter() {
        guard let selectedJobID else { return }
        if filteredJobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        self.selectedJobID = filteredJobs.first?.id
    }

    private var filteredJobs: [VeeamJob] {
        let base = scopeAndSearchFilteredJobs.filter { matchesResultFilter($0) }
        return base.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch leftPaneSort {
            case .jobName:
                comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
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
        .onChange(of: searchText) { _, newValue in
            reconcileSelectionAfterFilter()
            let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            Task { await api.ensureAllJobConfigsLoaded() }
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
            Text("Job Search")
                .font(Font.scaledText(.title3, scale: textScaleFactor, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            JobsSidebarSearchField(text: $searchText)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

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
        } else if let id = selectedJobID, let job = filteredJobs.first(where: { $0.id == id }) {
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
            JobsPrimaryToolbarCluster(
                isRefreshing: api.isRefreshingJobs,
                jobsEmpty: api.jobs.isEmpty,
                onRefresh: refresh,
                onExport: { Task { await exportHTMLReport() } },
                onShare: { Task { await shareHTMLReport() } }
            )
        }
        ToolbarItem(placement: .automatic) {
            JobsUtilityToolbarCluster(
                canDecreaseTextScale: canDecreaseTextScale,
                canIncreaseTextScale: canIncreaseTextScale,
                canResetTextScale: canResetTextScale,
                isDarkModeEnabled: isDarkModeEnabled,
                onDecreaseTextScale: decreaseTextScale,
                onResetTextScale: resetTextScale,
                onIncreaseTextScale: increaseTextScale,
                onToggleDarkMode: { isDarkModeEnabled.toggle() },
                onLogout: { api.logout() },
                onQuit: { NSApp.terminate(nil) }
            )
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
        handleTextScaleChanged()
    }

    private func increaseTextScale() {
        guard canIncreaseTextScale else { return }
        storedTextScaleFactor = TextScalePreference.increased(from: storedTextScaleFactor)
        handleTextScaleChanged()
    }

    private func resetTextScale() {
        guard canResetTextScale else { return }
        storedTextScaleFactor = TextScalePreference.defaultFactor
        handleTextScaleChanged()
    }

    private func handleTextScaleChanged() {
        ensureWindowFitsSidebarToolbarFloor()
        applySidebarWidthForTextScale()
    }

    private static let sidebarColumnMaxWidth: CGFloat = 2400
    /// Upper bound for automatic sidebar sizing so the detail pane keeps room on laptop displays.
    private static let sidebarAutomaticIdealCap: CGFloat = 440

    private var sidebarColumnMinWidth: CGFloat {
        Self.sidebarColumnMinimumWidth(for: textScaleFactor)
    }

    private static func sidebarColumnMinimumWidth(for textScale: CGFloat) -> CGFloat {
        JobsToolbarLayout.minimumWidth(for: textScale)
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
                    .disabled(job.isRunning)
                Button("Start Active Full") { Task { await api.startActiveFullJob(job) } }
                    .disabled(job.isRunning)
                Button("Stop Job") { Task { await api.stopJob(job) } }
                    .disabled(!job.isRunning)
                Button("Retry Job") { Task { await api.retryJob(job) } }
                Divider()
                Button("Enable Job") { Task { await api.enableJob(job) } }
                Button("Disable Job") { Task { await api.disableJob(job) } }
            }
            .help("Job: \(job.name). Current result: \(job.resultText). Right-click for job actions.")
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

    /// One-shot auto-resize after jobs load; uses job names only (not descriptions).
    private func scheduleInitialSidebarWidthAfterConfigs() {
        guard !hasAppliedInitialSidebarWidth, !userHasManuallyResizedSidebar, !api.jobs.isEmpty else { return }

        initialSidebarWidthTask?.cancel()
        initialSidebarWidthTask = Task { @MainActor in
            applyContentBasedSidebarWidth(markInitialApplied: false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, !userHasManuallyResizedSidebar else { return }
            applyContentBasedSidebarWidth(markInitialApplied: true)
        }
    }

    private func applySidebarWidthForTextScale() {
        guard !api.jobs.isEmpty, !userHasManuallyResizedSidebar else { return }
        applyContentBasedSidebarWidth(markInitialApplied: false)
    }

    /// Expands the outer window when a saved frame is narrower than the sidebar plus detail pane minimum.
    private func ensureWindowFitsSidebarToolbarFloor() {
        let sidebarFloor = max(sidebarIdealWidth, sidebarColumnMinWidth)
        let detailMinimum: CGFloat = 520
        let requiredWidth = sidebarFloor + detailMinimum

        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            guard window.frame.width < requiredWidth - 0.5 else { return }

            var frame = window.frame
            frame.size.width = requiredWidth
            window.setFrame(frame, display: true, animate: false)
        }
    }

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

    /// Content width clamped to toolbar floor and a laptop-friendly cap so the detail pane stays usable.
    private static func resolvedSidebarWidth(for jobs: [VeeamJob], textScale: CGFloat) -> CGFloat {
        let floor = JobsToolbarLayout.minimumWidth(for: textScale)
        let nameBased = contentBasedSidebarWidth(for: jobs, textScale: textScale)
        let capped = min(nameBased, compactSidebarIdealCap(textScale: textScale))
        return max(capped, floor)
    }

    private static func compactSidebarIdealCap(textScale: CGFloat) -> CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1280
        let fractionCap = screenWidth * 0.40
        return max(JobsToolbarLayout.minimumWidth(for: textScale), min(sidebarAutomaticIdealCap, fractionCap))
    }

    /// Width for the widest single-line job name and status badge (no description line).
    private static func contentBasedSidebarWidth(for jobs: [VeeamJob], textScale: CGFloat = 1.0) -> CGFloat {
        guard !jobs.isEmpty else { return 320 }

        let titleFont = sidebarMeasurementFont(style: .callout, weight: .medium, textScale: textScale)
        let badgeFont = sidebarMeasurementFont(style: .caption2, weight: .semibold, textScale: textScale)

        let maxTitleWidth = jobs.map {
            ($0.name as NSString).size(withAttributes: [.font: titleFont]).width
        }.max() ?? 200

        let maxBadgeWidth = jobs.map { job in
            let badgeText = job.isRunning ? job.runningStatusText : job.resultText
            let textWidth = (badgeText as NSString).size(withAttributes: [.font: badgeFont]).width
            return textWidth + (9 * textScale) + 4 + (Theme.Spacing.sm * 2)
        }.max() ?? 88

        let chromeWidth: CGFloat = 18 + (Theme.Spacing.md * 2) + 24 + maxBadgeWidth + 16
        return maxTitleWidth + chromeWidth
    }

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
            return !job.isCopyJob
        case .copy:
            return job.isCopyJob
        }
    }
}

