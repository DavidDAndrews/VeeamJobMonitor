import SwiftUI
import AppKit

// MARK: - Job Detail

struct JobDetailView: View {
    let job: VeeamJob
    @ObservedObject var api: VeeamAPIService
    @State private var selectedPointName: String?
    @State private var selectedPointDisks: [RestorePointDiskInfo] = []
    @State private var showDisksSheet = false
    @State private var disksLoading = false
    @State private var latestRunLogSummary: JobRunLogSummary?
    @State private var selectedRunLogSummary: JobRunLogSummary?
    @State private var selectedContextPointID: String?
    @State private var logSummaryLoading = false
    @State private var selectionLoadToken: UUID?
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        VStack(spacing: 0) {
            ConnectedToServerHeader(serverDisplayName: api.connectedServerDisplayName)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selectedContextPointID != nil {
                    HStack {
                        Spacer()
                        Button {
                            clearSelectedPointContext()
                        } label: {
                            Label("Back to Latest Run", systemImage: "arrow.uturn.backward.circle")
                                .font(Font.scaledText(.subheadline, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.brandTint, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small)
                                .stroke(Theme.brand.opacity(0.40), lineWidth: 1)
                        )
                        .help("Clear the selected restore-point context and show the latest run data.")
                    }
                }

                // Hero header card
                HStack(spacing: 16) {
                    JobHeroStatusCircle(style: headerStatusStyle, isRunning: job.isRunning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.displayName)
                            .font(Font.scaledText(.title2, scale: textScaleFactor, weight: .bold, baselineOffset: detailTextBonus))
                            .lineLimit(2)
                        if let selectedContextPointID,
                           let point = job.backupPoints.first(where: { $0.id == selectedContextPointID }) {
                            Text("Viewing context from restore point: \(BackupPointDateFormatter.shared.string(from: point.creationTime))")
                                .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Label(job.jobType, systemImage: "externaldrive")
                                .font(Font.scaledText(.subheadline, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                .foregroundStyle(.secondary)
                            if !job.enabled {
                                Label("Disabled", systemImage: "pause.circle")
                                    .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                    .foregroundStyle(Theme.statusDisabled)
                            }
                        }
                        if hasHeaderMetadata {
                            HStack(spacing: 8) {
                                if let vmStorageSize = job.vmStorageSize {
                                    HeaderChip(label: "VM Size \(vmStorageSize)")
                                }
                                if let totalStorageUsed = job.totalStorageUsedText {
                                    HeaderChip(label: "Total Storage Used: \(totalStorageUsed)")
                                }
                                ForEach(backupPointSummaryChips, id: \.self) { label in
                                    HeaderChip(label: label)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                }
                .padding(16)
                .background(headerStatusStyle.color.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.large))

                // Status section
                SectionHeader(title: "Status")
                EqualWidthInfoCardRow {
                    InfoCard(title: "Last Result", value: resultCardText, valueColor: resultColor,
                             icon: resultIcon,
                             explanation: "Shows how the most recent run finished. Success means the job completed normally, Warning means it finished but needs attention, Failed means it did not complete, and Disabled means the job is turned off.")
                    InfoCard(title: "Job Runtime",
                             value: jobRuntimeDisplay.valueText,
                             subtitle: jobRuntimeDisplay.subtitleText,
                             valueColor: job.isRunning ? Theme.statusRunning : Theme.textPrimary,
                             icon: "clock",
                             explanation: "Shows how long the job has been running, or how long the last run took from start to finish. When a job is running, elapsed time and estimated total runtime are projected from live Veeam session progress.",
                             runningProgressPercent: jobRuntimeDisplay.progressPercent.map { Int($0.rounded()) })
                    InfoCard(title: "Job Status",
                             value: statusText,
                             valueColor: statusColor,
                             icon: statusIcon,
                             explanation: "Shows what the job is doing right now. Running means work is in progress, Stopped means no run is active, and Disabled means the job is not allowed to run until re-enabled.")
                }

                SectionHeader(title: "Performance")
                EqualWidthInfoCardRow {
                    InfoCard(title: "Processing Rate",
                             value: processingRateText,
                             valueColor: processingRateColor,
                             icon: "speedometer",
                             explanation: "Average backup speed during the current or latest run. Higher values usually mean better performance, while lower values can point to storage, network, or source-side slowdown.")
                    InfoCard(title: "Processed Size",
                             value: processedSizeText,
                             icon: "internaldrive",
                             explanation: "Total amount of source data that the job evaluated during the run. This includes everything the job scanned and processed before transfer and storage optimizations.")
                    InfoCard(title: "Read Size",
                             value: readSizeText,
                             icon: "arrow.down.circle",
                             explanation: "How much data was read from the original source systems during this run. This reflects source-side read workload before backup data is optimized.")
                    InfoCard(title: "Transferred Size",
                             value: transferredSizeText,
                             icon: "arrow.left.arrow.right.circle",
                             explanation: "How much data was actually sent across to the backup target. This is typically smaller than read size because compression and deduplication reduce the amount transferred.")
                    InfoCard(title: "Dedup Rate",
                             value: dedupRateText,
                             valueColor: dedupRateColor,
                             icon: "chart.line.downtrend.xyaxis",
                             explanation: "Shows how much data reduction was achieved before data was written to backup storage. Higher percentages mean more savings from deduplication and compression.")
                }

                SectionHeader(title: "Latest Run Log Summary")
                JobRunLogSummaryCard(summary: activeRunLogSummary, isLoading: logSummaryLoading)

                // Schedule section
                SectionHeader(title: "Schedule")
                EqualWidthInfoCardRow {
                    InfoCard(title: "Last Run",
                             value: contextualLastRunDate.map { DetailDateFormatter.shared.string(from: $0) } ?? "—",
                             subtitle: contextualLastRunDate.map { relativeString($0) })
                    InfoCard(title: "Next Run",
                             value: nextRunText,
                             subtitle: job.nextRun.map { relativeString($0) }
                                    ?? (nextRunText == "Disabled" ? nil : (job.scheduleDescription != nil ? "Scheduled" : nil)),
                             valueColor: nextRunColor)
                }

                SectionHeader(title: "Backup Points")
                BackupPointsCard(
                    points: job.backupPoints,
                    selectedPointID: selectedContextPointID,
                    onSelectPoint: { point in
                        Task { await selectBackupPointContext(point) }
                    },
                    onViewDisks: { point in
                        Task { await loadDisks(for: point) }
                    }
                )

                Spacer()
            }
            .padding(20)
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $showDisksSheet) {
            RestorePointDisksSheet(
                pointName: selectedPointName ?? "Restore Point",
                disks: selectedPointDisks,
                isLoading: disksLoading
            )
            .appTextScale(textScaleFactor, detailTextBonus: 2)
        }
        .task(id: job.id) {
            await api.loadJobConfigDetails(for: job.id)
            await loadLatestRunLogSummary()
        }
    }

    private func loadLatestRunLogSummary() async {
        let token = UUID()
        selectionLoadToken = token
        let currentJob = api.jobs.first(where: { $0.id == job.id }) ?? job

        if api.hasCachedLatestJobRunLogSummary(for: currentJob.id) {
            latestRunLogSummary = api.cachedLatestJobRunLogSummary(for: currentJob.id)
            selectedRunLogSummary = nil
            selectedContextPointID = nil
            logSummaryLoading = false
            return
        }

        logSummaryLoading = true
        let latest = await api.fetchLatestJobRunLogSummary(for: currentJob)
        guard selectionLoadToken == token else { return }
        latestRunLogSummary = latest
        selectedRunLogSummary = nil
        selectedContextPointID = nil
        logSummaryLoading = false
    }

    private func selectBackupPointContext(_ point: VeeamBackupPoint) async {
        let token = UUID()
        selectionLoadToken = token
        selectedContextPointID = point.id
        // Clear old data immediately; rebuild only from selected restore-point context.
        selectedRunLogSummary = nil
        logSummaryLoading = true
        let summary = await api.fetchJobRunLogSummary(for: job, near: point.creationTime)
        guard selectionLoadToken == token else { return }
        selectedRunLogSummary = summary
        logSummaryLoading = false
    }

    private func clearSelectedPointContext() {
        selectionLoadToken = UUID()
        selectedContextPointID = nil
        selectedRunLogSummary = nil
    }

    private func loadDisks(for point: VeeamBackupPoint) async {
        selectedPointName = point.name
        disksLoading = true
        showDisksSheet = true
        do {
            selectedPointDisks = try await api.fetchRestorePointDisks(restorePointID: point.id)
        } catch {
            api.errorMessage = error.localizedDescription
            selectedPointDisks = []
        }
        disksLoading = false
    }

    private func relativeString(_ date: Date) -> String {
        RelativeTimeFormatter.shared.localizedString(for: date, relativeTo: Date())
    }

    private var resultCardText: String {
        if let contextResult = activeRunLogSummary?.result, !contextResult.isEmpty {
            return contextResult.capitalized
        }
        return job.isRunning ? job.runningStatusText : job.resultText
    }

    private var headerStatusStyle: StatusStyle {
        jobResultBucket(for: job).style
    }

    private var resultStyle: StatusStyle {
        if job.isRunning { return Theme.style(for: .running) }
        let text = resultCardText.lowercased()
        if text.hasPrefix("running") { return Theme.style(for: .running) }
        if text.contains("success") { return Theme.style(for: .success) }
        if text.contains("fail") || text.contains("error") { return Theme.style(for: .failed) }
        if text.contains("warning") { return Theme.style(for: .warning) }
        if text.contains("disabled") { return Theme.style(for: .disabled) }
        return Theme.style(for: .unknown)
    }

    private var resultColor: Color { resultStyle.color }

    private var resultIcon: String { resultStyle.icon }

    private var statusText: String {
        if let state = activeRunLogSummary?.state, !state.isEmpty {
            return state.capitalized
        }
        if job.isRunning {
            return "Running (\(max(job.progressPercent ?? 0, 0))%)"
        }
        if isDisabledStatus {
            return "Disabled"
        }

        return job.status?.capitalized ?? "Active"
    }

    private var statusColor: Color {
        if isDisabledStatus {
            return Theme.statusDisabled
        }

        switch job.status?.lowercased() {
        case "running":
            return Theme.statusRunning
        case "inactive":
            return Theme.statusUnknown
        default:
            return Theme.textPrimary
        }
    }

    private var statusIcon: String {
        if isDisabledStatus { return "pause.circle.fill" }
        switch job.status?.lowercased() {
        case "running": return "arrow.triangle.2.circlepath.circle.fill"
        case "inactive": return "moon.circle.fill"
        default: return "bolt.circle.fill"
        }
    }

    private var jobRuntimeDisplay: JobRuntimeDisplayInfo {
        guard let duration = runtimeSeconds else {
            return JobRuntimeDisplayInfo(valueText: "—", subtitleText: nil, progressPercent: nil)
        }
        return JobRuntimeEstimation.displayInfo(
            elapsedSeconds: duration,
            isRunning: job.isRunning,
            progressPercent: job.progressPercent
        )
    }

    private var runtimeSeconds: TimeInterval? {
        let start: Date?
        let end: Date?

        if let summary = activeRunLogSummary {
            start = summary.startedAt
            end = summary.endedAt ?? (job.isRunning ? Date() : nil)
        } else {
            start = job.lastRun
            end = job.isRunning ? Date() : nil
        }

        guard let start else { return nil }
        let effectiveEnd = end ?? Date()
        return max(effectiveEnd.timeIntervalSince(start), 0)
    }

    private var rawThroughputBytesPerSecond: Double? {
        if let summary = activeRunLogSummary,
           let fromLogs = throughputBytesPerSecondFromLogEntries(summary.entries) {
            return fromLogs
        }
        // When a restore-point context is selected, avoid stale job-level snapshot
        // values and prefer context-derived metrics.
        if !isRestorePointContextActive, let bps = job.processingRateBytesPerSecond, bps > 0 {
            return bps
        }
        if let transferred = resolvedTransferredSizeBytes,
           transferred > 0,
           let runtimeSeconds,
           runtimeSeconds > 0 {
            return Double(transferred) / runtimeSeconds
        }
        guard let vmStorageBytes = parsedSizeInBytes(job.vmStorageSize),
              let runtimeSeconds,
              runtimeSeconds > 0 else {
            return nil
        }
        return Double(vmStorageBytes) / runtimeSeconds
    }

    private func formattedThroughput(_ bps: Double) -> String {
        let kbps = bps / 1024
        let mbps = kbps / 1024
        let gbps = mbps / 1024

        if gbps >= 1 {
            return String(format: "%.2f GB/SEC", gbps)
        }
        if mbps >= 1 {
            return String(format: "%.1f MB/SEC", mbps)
        }
        return String(format: "%.0f KB/SEC", kbps)
    }

    private func throughputColor(_ bps: Double?) -> Color {
        guard let bps else { return Theme.statusUnknown }
        let mbps = bps / 1_048_576
        switch mbps {
        case ..<1:
            return Theme.statusFailed
        case 1..<40:
            return Theme.statusWarning
        case 40..<100:
            return Theme.statusSuccess
        default:
            return Theme.statusRunning
        }
    }

    private var processingRateText: String {
        guard let bps = rawThroughputBytesPerSecond else { return "—" }
        return formattedThroughput(bps)
    }

    private var processingRateColor: Color {
        throughputColor(rawThroughputBytesPerSecond)
    }

    private var processedSizeText: String {
        guard let bytes = resolvedProcessedSizeBytes, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var readSizeText: String {
        guard let bytes = resolvedReadSizeBytes, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var transferredSizeText: String {
        guard let bytes = resolvedTransferredSizeBytes, bytes >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var dedupRateFraction: Double? {
        guard let read = resolvedReadSizeBytes,
              let transferred = resolvedTransferredSizeBytes,
              read > 0,
              transferred >= 0 else {
            return nil
        }
        let reduction = 1.0 - (Double(transferred) / Double(read))
        return min(max(reduction, 0), 1)
    }

    private var resolvedProcessedSizeBytes: Int64? {
        if let summary = activeRunLogSummary {
            if let parsed = parseNamedSizeFromLogEntries(summary.entries, label: "processed"), parsed > 0 {
                return parsed
            }
            if let parsed = parseReadSizeSumFromLogEntries(summary.entries), parsed > 0 {
                return parsed
            }
        }
        if let bytes = job.processedSizeBytes, bytes > 0 {
            return bytes
        }
        if let selectedContextPointID,
           let point = job.backupPoints.first(where: { $0.id == selectedContextPointID }),
           let pointBytes = point.backupSizeBytes,
           pointBytes > 0 {
            return pointBytes
        }
        return nil
    }

    private var resolvedReadSizeBytes: Int64? {
        if let summary = activeRunLogSummary {
            if let parsed = parseNamedSizeFromLogEntries(summary.entries, label: "read"), parsed > 0 {
                return parsed
            }
            if let parsed = parseReadSizeSumFromLogEntries(summary.entries), parsed > 0 {
                return parsed
            }
        }
        if let bytes = job.readSizeBytes, bytes > 0 {
            return bytes
        }
        if let selectedContextPointID,
           let point = job.backupPoints.first(where: { $0.id == selectedContextPointID }),
           let pointBytes = point.backupSizeBytes,
           pointBytes > 0 {
            return pointBytes
        }
        return nil
    }

    private var resolvedTransferredSizeBytes: Int64? {
        if let summary = activeRunLogSummary {
            if let parsed = parseNamedSizeFromLogEntries(summary.entries, label: "transferred"), parsed > 0 {
                return parsed
            }
        }
        // Useful copy-job fallback: selected restore point size approximates transferred amount.
        if let selectedContextPointID,
           let point = job.backupPoints.first(where: { $0.id == selectedContextPointID }),
           let pointBytes = point.backupSizeBytes,
           pointBytes > 0 {
            return pointBytes
        }
        if let bytes = job.transferredSizeBytes, bytes > 0 {
            return bytes
        }
        return nil
    }

    private var isRestorePointContextActive: Bool {
        selectedContextPointID != nil
    }

    private var dedupRateText: String {
        guard let rate = dedupRateFraction else { return "—" }
        return String(format: "%.1f%%", rate * 100)
    }

    private var dedupRateColor: Color {
        guard let rate = dedupRateFraction else { return Theme.statusUnknown }
        switch rate {
        case ..<0.20:
            return Theme.statusFailed
        case 0.20..<0.60:
            return Theme.statusWarning
        case 0.60..<0.80:
            return Theme.statusSuccess
        default:
            return Theme.statusRunning
        }
    }

    private func parsedSizeInBytes(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        guard let numberPart = parts.first, let value = Double(numberPart) else { return nil }
        let unit = (parts.dropFirst().first.map(String.init) ?? "B").uppercased()

        let multiplier: Double
        switch unit {
        case "KB", "KIB":
            multiplier = 1_024
        case "MB", "MIB":
            multiplier = 1_048_576
        case "GB", "GIB":
            multiplier = 1_073_741_824
        case "TB", "TIB":
            multiplier = 1_099_511_627_776
        case "PB", "PIB":
            multiplier = 1_125_899_906_842_624
        default:
            multiplier = 1
        }

        let bytes = value * multiplier
        guard bytes.isFinite, bytes >= 0 else { return nil }
        return Int64(bytes.rounded())
    }

    private func throughputBytesPerSecondFromLogEntries(_ entries: [JobRunLogEntry]) -> Double? {
        var best: Double?
        for entry in entries {
            let source = entry.message.lowercased()
            // Typical Veeam action samples:
            // "Hard disk 1 (...) 55.2 GB read at 63 MB/s [CBT]"
            // "Hard disk 2 (...) 1.1 TB read at 11 MB/s"
            guard let range = source.range(of: #"read at\s+([0-9]+(?:\.[0-9]+)?)\s*([kmg])b/s"#, options: .regularExpression) else {
                continue
            }
            let chunk = String(source[range])
            guard let match = chunk.range(of: #"([0-9]+(?:\.[0-9]+)?)\s*([kmg])b/s"#, options: .regularExpression) else {
                continue
            }
            let body = String(chunk[match])
            let parts = body.replacingOccurrences(of: "/s", with: "").split(separator: " ", omittingEmptySubsequences: true)
            if parts.count < 2 { continue }
            guard let value = Double(parts[0]) else { continue }
            let unitPrefix = parts[1].lowercased()

            let bytesPerSecond: Double
            if unitPrefix.hasPrefix("kb") {
                bytesPerSecond = value * 1024
            } else if unitPrefix.hasPrefix("mb") {
                bytesPerSecond = value * 1_048_576
            } else if unitPrefix.hasPrefix("gb") {
                bytesPerSecond = value * 1_073_741_824
            } else {
                continue
            }

            best = max(best ?? 0, bytesPerSecond)
        }
        return best
    }

    private func parseNamedSizeFromLogEntries(_ entries: [JobRunLogEntry], label: String) -> Int64? {
        let pattern = "\(NSRegularExpression.escapedPattern(for: label))\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)\\s*([kmgpt]b)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        var best: Int64?
        for entry in entries {
            let text = entry.message
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges >= 3,
                  let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]) else {
                continue
            }

            let unit = String(text[unitRange]).uppercased()
            let bytes = Int64((value * unitMultiplier(unit)).rounded())
            if bytes > 0 {
                best = max(best ?? 0, bytes)
            }
        }
        return best
    }

    private func parseReadSizeSumFromLogEntries(_ entries: [JobRunLogEntry]) -> Int64? {
        guard let regex = try? NSRegularExpression(
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*([kmgpt]b)\s+read at"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        var total: Double = 0
        var found = false
        for entry in entries {
            let text = entry.message
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            for match in matches where match.numberOfRanges >= 3 {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text),
                      let value = Double(text[valueRange]) else {
                    continue
                }
                let unit = String(text[unitRange]).uppercased()
                total += value * unitMultiplier(unit)
                found = true
            }
        }

        guard found else { return nil }
        return Int64(total.rounded())
    }

    private func unitMultiplier(_ unit: String) -> Double {
        switch unit {
        case "KB":
            return 1_024
        case "MB":
            return 1_048_576
        case "GB":
            return 1_073_741_824
        case "TB":
            return 1_099_511_627_776
        case "PB":
            return 1_125_899_906_842_624
        default:
            return 1
        }
    }

    private var nextRunText: String {
        if isDisabledStatus {
            return "Disabled"
        }

        if let nextRun = job.nextRun {
            return DetailDateFormatter.shared.string(from: nextRun)
        }

        if let scheduleDescription = job.scheduleDescription {
            if scheduleDescription.localizedCaseInsensitiveContains("As New Restore Points Appear") {
                return "Next run on next backup-point appearance"
            }
            return scheduleDescription
        }

        return "—"
    }

    private var nextRunColor: Color {
        nextRunText == "Disabled" ? Theme.statusDisabled : Theme.textPrimary
    }

    private var isDisabledStatus: Bool {
        !job.enabled || job.status?.lowercased() == "disabled"
    }

    private var hasHeaderMetadata: Bool {
        job.vmStorageSize != nil || !backupPointSummaryChips.isEmpty
    }

    private var activeRunLogSummary: JobRunLogSummary? {
        if selectedContextPointID != nil {
            return selectedRunLogSummary
        }
        return latestRunLogSummary
    }

    private var contextualLastRunDate: Date? {
        if let summaryStart = activeRunLogSummary?.startedAt {
            return summaryStart
        }
        if let selectedContextPointID,
           let point = job.backupPoints.first(where: { $0.id == selectedContextPointID }) {
            return point.creationTime
        }
        return job.lastRun
    }

    private var backupPointSummaryChips: [String] {
        let fullCount = countBackupPoints(matching: ["full"])
        let syntheticFullCount = countBackupPoints(matching: ["syntheticfull", "synthetic full"])
        let incrementalCount = countBackupPoints(matching: ["increment"])
        let reverseIncrementalCount = countBackupPoints(matching: ["reverseincrement", "reverse incremental"])

        var chips: [String] = []
        if fullCount > 0 { chips.append("\(fullCount) Full\(fullCount == 1 ? "" : "s")") }
        if syntheticFullCount > 0 { chips.append("\(syntheticFullCount) Synthetic") }
        if incrementalCount > 0 { chips.append("\(incrementalCount) Incremental\(incrementalCount == 1 ? "" : "s")") }
        if reverseIncrementalCount > 0 { chips.append("\(reverseIncrementalCount) Reverse Inc") }
        return chips
    }

    private func countBackupPoints(matching typeKeys: Set<String>) -> Int {
        job.backupPoints.filter { point in
            typeKeys.contains(point.type.replacingOccurrences(of: " ", with: "").lowercased())
        }.count
    }
}

private struct JobRunLogSummaryCard: View {
    let summary: JobRunLogSummary?
    let isLoading: Bool
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    private var successCount: Int {
        (summary?.entries ?? []).filter { classifyStatus($0) == .success }.count
    }
    private var warningCount: Int {
        (summary?.entries ?? []).filter { classifyStatus($0) == .warning }.count
    }
    private var retryCount: Int {
        (summary?.entries ?? []).filter { classifyStatus($0) == .retry }.count
    }
    private var failedCount: Int {
        (summary?.entries ?? []).filter { classifyStatus($0) == .failed }.count
    }

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading latest job run messages...")
                        .font(Font.scaledText(.callout, scale: textScaleFactor, baselineOffset: detailTextBonus))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            } else if let summary {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        HeaderChip(label: "State: \(summary.state.capitalized)")
                        HeaderChip(label: "Result: \(summary.result.capitalized)")
                        if let startedAt = summary.startedAt {
                            HeaderChip(label: "Started: \(DetailDateFormatter.shared.string(from: startedAt))")
                        }
                        if let endedAt = summary.endedAt {
                            HeaderChip(label: "Ended: \(DetailDateFormatter.shared.string(from: endedAt))")
                        }
                    }

                    HStack(spacing: 8) {
                        logCountBadge(text: "Success \(successCount)", color: Theme.statusSuccess)
                        logCountBadge(text: "Warning \(warningCount)", color: Theme.statusWarning)
                        logCountBadge(text: "Retry \(retryCount)", color: Theme.statusRunning)
                        logCountBadge(text: "Failed \(failedCount)", color: Theme.statusFailed)
                    }

                    if summary.entries.isEmpty {
                        Text("No messages returned for this session.")
                            .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(summary.entries.prefix(40)) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: icon(for: entry))
                                        .foregroundStyle(color(for: entry))
                                        .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                        .frame(width: 14 * textScaleFactor, alignment: .center)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let when = entry.updateTime ?? entry.startTime {
                                            Text(DetailDateFormatter.shared.string(from: when))
                                                .font(Font.scaledText(.caption2, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(entry.message)
                                            .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                if entry.id != summary.entries.prefix(40).last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(10)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
            } else {
                Text("No recent run log messages found for this job.")
                    .font(Font.scaledText(.callout, scale: textScaleFactor, baselineOffset: detailTextBonus))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .stroke(Theme.separator, lineWidth: 0.5)
                    )
            }
        }
    }

    private enum EntryClass {
        case success
        case warning
        case retry
        case failed
        case info
    }

    private func classifyStatus(_ entry: JobRunLogEntry) -> EntryClass {
        let source = "\(entry.status) \(entry.message)".lowercased()
        if source.contains("fail") || source.contains("error") {
            return .failed
        }
        if source.contains("retry") {
            return .retry
        }
        if source.contains("warning") || source.contains("rpo violation") {
            return .warning
        }
        if source.contains("success") || source.contains("finished") || source.contains("processed") {
            return .success
        }
        return .info
    }

    private func icon(for entry: JobRunLogEntry) -> String {
        switch classifyStatus(entry) {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .retry: return "arrow.clockwise.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for entry: JobRunLogEntry) -> Color {
        switch classifyStatus(entry) {
        case .success: return Theme.statusSuccess
        case .warning: return Theme.statusWarning
        case .retry: return Theme.statusRunning
        case .failed: return Theme.statusFailed
        case .info: return Theme.statusUnknown
        }
    }

    private func logCountBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(Font.scaledText(.caption2, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Detail sub-views

private struct JobHeroStatusCircle: View {
    let style: StatusStyle
    let isRunning: Bool
    @State private var pulse = false
    @State private var spinRing = false
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    private let size: CGFloat = 52

    var body: some View {
        ZStack {
            if isRunning {
                Circle()
                    .stroke(style.color.opacity(0.35), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(pulse ? 1.2 : 0.9)
                    .opacity(pulse ? 0 : 0.75)
            }

            Circle()
                .fill(style.color.opacity(0.15))
                .frame(width: size, height: size)

            if isRunning {
                Circle()
                    .trim(from: 0.1, to: 0.78)
                    .stroke(
                        style.color.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: size - 6, height: size - 6)
                    .rotationEffect(.degrees(spinRing ? 360 : 0))
            }

            Image(systemName: style.icon)
                .font(Font.scaledSystem(size: 24, weight: .semibold, scale: textScaleFactor, baselineOffset: detailTextBonus))
                .foregroundStyle(style.color)
        }
        .frame(width: size, height: size)
        .onAppear { syncAnimation() }
        .onChange(of: isRunning) { _, _ in syncAnimation() }
    }

    private func syncAnimation() {
        pulse = false
        spinRing = false
        guard isRunning else { return }
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            pulse = true
        }
        withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
            spinRing = true
        }
    }
}

private struct ConnectedToServerHeader: View {
    let serverDisplayName: String
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("Connected To:")
                .font(Font.scaledText(.footnote, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
                .foregroundStyle(Theme.textSecondary)
            Text(serverDisplayName)
                .font(Font.scaledText(.callout, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
                .foregroundStyle(Theme.brand)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .help("Connected to \(serverDisplayName)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected to \(serverDisplayName)")
    }
}

private struct SectionHeader: View {
    let title: String
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        Text(title)
            .font(Font.scaledText(.footnote, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
            .tracking(0.5)
            .padding(.top, 4)
            .help("\(title) section.")
    }
}

/// Lays out info cards in a single row with equal width; taller cards grow vertically while tops stay aligned.
private struct EqualWidthInfoCardRow<Content: View>: View {
    private let spacing: CGFloat = 10
    @ViewBuilder private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            content
        }
    }
}

private struct InfoCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var valueColor: Color = Theme.textPrimary
    var icon: String? = nil
    var explanation: String? = nil
    /// When set (running jobs), renders a horizontal progress bar under the runtime value.
    var runningProgressPercent: Int? = nil
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    private var clampedProgress: Double? {
        guard let runningProgressPercent else { return nil }
        return min(max(Double(runningProgressPercent), 0), 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .top, spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                        .foregroundStyle(valueColor)
                }
                Text(value)
                    .font(Font.scaledText(.callout, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
                    .foregroundStyle(valueColor)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let subtitle {
                Text(subtitle)
                    .font(Font.scaledText(.caption2, scale: textScaleFactor, baselineOffset: detailTextBonus))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let clampedProgress {
                JobRuntimeProgressBar(percent: clampedProgress)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .themeShadow(Theme.shadowSubtle)
        .help(explanation ?? "\(title): \(value)")
    }
}

private struct JobRuntimeProgressBar: View {
    let percent: Double
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    private var barHeight: CGFloat { max(6, 7 * textScaleFactor) }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let fillWidth = geometry.size.width * (percent / 100.0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.statusRunning.opacity(0.14))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Theme.statusRunning,
                                    Color(hex: 0x3B82F6),
                                    Color(hex: 0x93C5FD)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(fillWidth, percent > 0 ? barHeight : 0))
                        .shadow(color: Theme.statusRunning.opacity(0.35), radius: 2, x: 0, y: 1)
                }
            }
            .frame(height: barHeight)
            .animation(.easeOut(duration: 0.35), value: percent)

            Text("\(Int(percent.rounded()))%")
                .font(Font.scaledText(.caption2, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus).monospacedDigit())
                .foregroundStyle(Theme.statusRunning)
                .frame(minWidth: 30, alignment: .trailing)
                .contentTransition(.numericText(value: percent))
                .animation(.easeOut(duration: 0.2), value: percent)
        }
    }
}

private struct HeaderChip: View {
    let label: String
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        Text(label)
            .font(Font.scaledText(.caption2, scale: textScaleFactor, weight: .medium, baselineOffset: detailTextBonus))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surfaceSecondary, in: Capsule())
            .overlay(Capsule().stroke(Theme.separator, lineWidth: 0.5))
            .foregroundStyle(Theme.textSecondary)
    }
}

private struct BackupPointsCard: View {
    let points: [VeeamBackupPoint]
    let selectedPointID: String?
    let onSelectPoint: (VeeamBackupPoint) -> Void
    let onViewDisks: (VeeamBackupPoint) -> Void
    @State private var sortColumn: SortColumn = .date
    @State private var sortAscending: Bool = false
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    private enum SortColumn {
        case recoveryPoint
        case date
        case backupSize
        case type
        case status
        case retention
        case expiration
        case repository
    }

    private var groupedPoints: [(setName: String, points: [VeeamBackupPoint])] {
        let grouped = Dictionary(grouping: points) { point in
            point.backupSetName ?? "UnknownBackupSet.VBM"
        }
        return grouped
            .map { key, value in
                (setName: key, points: sortedPoints(value))
            }
            .sorted { lhs, rhs in
                let lhsNewest = lhs.points.first?.creationTime ?? .distantPast
                let rhsNewest = rhs.points.first?.creationTime ?? .distantPast
                return lhsNewest > rhsNewest
            }
    }

    var body: some View {
        if groupedPoints.isEmpty {
            Text("No backup points found for this job.")
                .font(Font.scaledText(.callout, scale: textScaleFactor, baselineOffset: detailTextBonus))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .stroke(Theme.separator, lineWidth: 0.5)
                )
        } else {
            VStack(spacing: 10) {
                ForEach(groupedPoints, id: \.setName) { group in
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                                .foregroundStyle(Theme.brand)
                            Text(groupTitle(for: group))
                                .font(Font.scaledText(.subheadline, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.brandTint)

                        HStack(spacing: 0) {
                            sortableHeader("Recovery Point", width: 360, column: .recoveryPoint)
                            sortableHeader("Date", width: 160, column: .date)
                            sortableHeader("Backup Size", width: 120, column: .backupSize)
                            sortableHeader("Type", width: 110, column: .type)
                            sortableHeader("Status", width: 70, column: .status)
                            sortableHeader("Retention", width: 80, column: .retention)
                            sortableHeader("Expiration", width: 140, column: .expiration)
                            sortableHeader("Repository", width: 180, column: .repository)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.surfaceSecondary)

                        ForEach(Array(group.points.enumerated()), id: \.element.id) { index, point in
                            BackupPointRow(
                                point: point,
                                isSelected: selectedPointID == point.id,
                                onSelect: onSelectPoint,
                                onViewDisks: onViewDisks
                            )
                                .padding(.leading, 12)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Theme.separator)
                                        .frame(width: 2)
                                }

                            if index < group.points.count - 1 {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium)
                            .stroke(Theme.separator, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }
            }
        }
    }

    private func groupTitle(for group: (setName: String, points: [VeeamBackupPoint])) -> String {
        let machineName = group.points.first?.name ?? displayMachineName(from: group.setName)
        let startDate = group.points.map(\.creationTime).min() ?? .distantPast
        let endDate = group.points.map(\.creationTime).max() ?? .distantPast
        return "\(machineName) - (\(groupDateText(from: startDate)) --> \(groupDateText(from: endDate))) - \(group.points.count) Restore Points"
    }

    private func displayMachineName(from backupSetName: String) -> String {
        backupSetName.replacingOccurrences(of: "\\.[Vv][Bb][Mm]$", with: "", options: .regularExpression)
    }

    private func groupDateText(from date: Date) -> String {
        Self.groupDateFormatter.string(from: date).uppercased()
    }

    private static let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MMM-dd"
        return formatter
    }()

    private func sortedPoints(_ input: [VeeamBackupPoint]) -> [VeeamBackupPoint] {
        input.sorted(by: { lhs, rhs in
            let ordered: Bool = switch sortColumn {
            case .recoveryPoint:
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .date:
                lhs.creationTime < rhs.creationTime
            case .backupSize:
                (lhs.backupSizeBytes ?? -1) < (rhs.backupSizeBytes ?? -1)
            case .type:
                lhs.type.localizedCaseInsensitiveCompare(rhs.type) == .orderedAscending
            case .status:
                lhs.status.localizedCaseInsensitiveCompare(rhs.status) == .orderedAscending
            case .retention:
                (lhs.gfsText ?? "").localizedCaseInsensitiveCompare(rhs.gfsText ?? "") == .orderedAscending
            case .expiration:
                (lhs.expirationDate ?? .distantPast) < (rhs.expirationDate ?? .distantPast)
            case .repository:
                (lhs.repositoryName ?? "").localizedCaseInsensitiveCompare(rhs.repositoryName ?? "") == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        })
    }

    private func sortableHeader(_ title: String, width: CGFloat, column: SortColumn) -> some View {
        Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = (column != .date)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(Font.scaledSystem(size: 9, weight: .semibold, scale: textScaleFactor, baselineOffset: detailTextBonus))
                }
            }
            .font(Font.scaledText(.caption, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct BackupPointRow: View {
    let point: VeeamBackupPoint
    let isSelected: Bool
    let onSelect: (VeeamBackupPoint) -> Void
    let onViewDisks: (VeeamBackupPoint) -> Void
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        HStack(spacing: 0) {
            cell(point.name, width: 360)
            cell(BackupPointDateFormatter.shared.string(from: point.creationTime), width: 160)
            cell(point.backupSizeText, width: 120)
            cell(displayType, width: 110)
            cell(point.status, width: 70)
            retentionCell
            cell(point.expirationText, width: 140)
            cell(point.repositoryName ?? "—", width: 180)
        }
        .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.brand.opacity(0.18) : rowBackgroundColor)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.brand.opacity(0.85), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(point)
        }
        .help("Click to load this restore point run context in the right pane.")
        .contextMenu {
            Button("Load This Restore Point Context") {
                onSelect(point)
            }
            Button("View Restore Point Disks") {
                onViewDisks(point)
            }
        }
    }

    private var displayType: String {
        switch point.type.replacingOccurrences(of: " ", with: "").lowercased() {
        case "full":
            return "Full"
        case "syntheticfull":
            return "Synthetic Full"
        case "reverseincrement", "reverseincremental":
            return "Reverse Inc"
        case "increment", "incremental":
            return "Increment"
        default:
            return point.type
        }
    }

    private var rowBackgroundColor: Color {
        switch point.type.replacingOccurrences(of: " ", with: "").lowercased() {
        case "full", "syntheticfull":
            return Theme.statusSuccess.opacity(0.10)
        case "increment", "incremental", "reverseincrement", "reverseincremental":
            return Theme.statusRunning.opacity(0.08)
        default:
            return .clear
        }
    }

    private var retentionCell: some View {
        let retentionColor: Color = point.gfsText == nil ? Theme.textSecondary : Theme.statusRunning
        return Text(point.gfsText ?? "—")
            .frame(width: 80, alignment: .leading)
            .foregroundStyle(retentionColor)
            .fontWeight(point.gfsText == nil ? .regular : .semibold)
    }

    private func cell(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct RestorePointDisksSheet: View {
    let pointName: String
    let disks: [RestorePointDiskInfo]
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScaleFactor) private var textScaleFactor
    @Environment(\.detailTextBonus) private var detailTextBonus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore Point Disks")
                .font(Font.scaledText(.title3, scale: textScaleFactor, weight: .semibold, baselineOffset: detailTextBonus))
            Text(pointName)
                .font(Font.scaledText(.subheadline, scale: textScaleFactor, baselineOffset: detailTextBonus))
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView("Loading disks...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if disks.isEmpty {
                ContentUnavailableView("No Disk Data", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(disks) { disk in
                    HStack {
                        Text(disk.name)
                        Spacer()
                        Text(disk.type).foregroundStyle(.secondary)
                        Text(disk.capacityText).foregroundStyle(.secondary)
                        Text(disk.state).foregroundStyle(.secondary)
                    }
                    .font(Font.scaledText(.caption, scale: textScaleFactor, baselineOffset: detailTextBonus))
                }
                .listStyle(.inset)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 420)
    }
}

