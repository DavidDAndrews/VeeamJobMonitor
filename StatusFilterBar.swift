import SwiftUI

// MARK: - Status Summary Bar

struct StatusSummaryBar: View {
    let jobs: [VeeamJob]
    let filteredByScopeAndSearch: [VeeamJob]
    @Binding var selectedStatusFilter: StatusFilter
    @Binding var selectedBackupScope: BackupScope

    struct Counts {
        var running = 0
        var success = 0
        var warning = 0
        var failed = 0
        var disabled = 0
        var regularJobs = 0
        var copyJobs = 0
    }

    var counts: Counts {
        var totals = Counts()
        for job in filteredByScopeAndSearch {
            switch jobResultBucket(for: job) {
            case .running: totals.running += 1
            case .success: totals.success += 1
            case .warning: totals.warning += 1
            case .failed: totals.failed += 1
            case .disabled: totals.disabled += 1
            case .unknown: break
            }
        }
        for job in jobs {
            if job.isCopyJob {
                totals.copyJobs += 1
            } else {
                totals.regularJobs += 1
            }
        }
        return totals
    }

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
                label: "\(counts.running)",
                color: Theme.statusRunning,
                isSelected: selectedStatusFilter == .running
            ) {
                selectedStatusFilter = .running
            }
            FilterChipWithLegend(
                legend: "OK",
                label: "\(counts.success)",
                color: Theme.statusSuccess,
                isSelected: selectedStatusFilter == .success
            ) {
                selectedStatusFilter = .success
            }
            FilterChipWithLegend(
                legend: "WRN",
                label: "\(counts.warning)",
                color: Theme.statusWarning,
                isSelected: selectedStatusFilter == .warning
            ) {
                selectedStatusFilter = .warning
            }
            FilterChipWithLegend(
                legend: "FAIL",
                label: "\(counts.failed)",
                color: Theme.statusFailed,
                isSelected: selectedStatusFilter == .failed
            ) {
                selectedStatusFilter = .failed
            }
            FilterChipWithLegend(
                legend: "DIS",
                label: "\(counts.disabled)",
                color: Theme.statusDisabled,
                isSelected: selectedStatusFilter == .disabled
            ) {
                selectedStatusFilter = .disabled
            }
            BackupScopeToggle(
                regularCount: counts.regularJobs,
                copyCount: counts.copyJobs,
                selectedBackupScope: $selectedBackupScope
            )
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .themeGlassPanel(cornerRadius: Theme.Radius.medium, material: .thinMaterial)
    }
}

struct FilterChipWithLegend: View {
    let legend: String
    let label: String
    let color: Color
    var selectedTextColor: Color = .white
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.textScaleFactor) var textScaleFactor

    var body: some View {
        VStack(spacing: 2) {
            FilterChip(label: label, color: color, selectedTextColor: selectedTextColor, isSelected: isSelected, action: action)
            Text(legend)
                .font(Font.scaledSystem(size: 8, weight: .semibold, scale: textScaleFactor))
                .foregroundStyle(isSelected ? AnyShapeStyle(color) : AnyShapeStyle(Theme.textSecondary))
        }
        .help(legendTooltip)
    }

    var legendTooltip: String {
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

enum BackupScope {
    case all
    case regular
    case copy
}

struct FilterChip: View {
    let label: String
    let color: Color
    var selectedTextColor: Color = .white
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.textScaleFactor) var textScaleFactor

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

struct BackupScopeToggle: View {
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

struct ReportReadyToastView: View {
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
        .themeGlassPanel(cornerRadius: 10, material: .regularMaterial, fallbackSurface: Theme.surfaceElevated)
        .themeShadow(Theme.shadowElevated)
    }
}
