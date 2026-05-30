import Foundation

// MARK: - Job runtime estimation

struct JobRuntimeDisplayInfo: Equatable {
    let valueText: String
    let subtitleText: String?
    /// When nil, the progress bar is hidden (completed / inactive jobs).
    let progressPercent: Double?
}

enum JobRuntimeEstimation {
    /// Progress below this floor is treated as this value when estimating total runtime,
    /// so a stuck 1% reading does not imply a multi-day job.
    static let minProgressPercentForEstimate: Double = 2
    /// Estimated total runtime cannot exceed this multiple of elapsed time.
    static let maxEstimatedTotalMultiplier: Double = 50
    /// Remaining time below this uses a relative "in …" completion label.
    static let relativeCompletionThreshold: TimeInterval = 2 * 3600

    static func displayInfo(
        elapsedSeconds: TimeInterval,
        isRunning: Bool,
        progressPercent: Int?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> JobRuntimeDisplayInfo {
        let elapsed = max(elapsedSeconds, 0)

        guard isRunning else {
            return JobRuntimeDisplayInfo(
                valueText: formatRuntimeDuration(elapsed),
                subtitleText: nil,
                progressPercent: nil
            )
        }

        let rawProgress = progressPercent ?? 0
        let clampedProgress = min(max(Double(rawProgress), 0), 100)

        if clampedProgress >= 100 {
            return JobRuntimeDisplayInfo(
                valueText: formatRuntimeDuration(elapsed),
                subtitleText: "Run complete",
                progressPercent: 100
            )
        }

        if clampedProgress <= 0 {
            return JobRuntimeDisplayInfo(
                valueText: formatRuntimeDuration(elapsed),
                subtitleText: "Waiting for progress update",
                progressPercent: 0
            )
        }

        let estimatedTotal = estimatedTotalSeconds(elapsed: elapsed, progressPercent: rawProgress)
        let remaining = max(estimatedTotal - elapsed, 0)
        let completionDate = now.addingTimeInterval(remaining)
        let elapsedText = formatHumanReadableDuration(elapsed)
        let totalText = formatHumanReadableDuration(estimatedTotal)
        let completionText = formatEstimatedCompletion(
            remaining: remaining,
            completionDate: completionDate,
            now: now,
            calendar: calendar
        )

        return JobRuntimeDisplayInfo(
            valueText: "\(elapsedText) of \(totalText) Estimated Total",
            subtitleText: "Est Completion: \(completionText)",
            progressPercent: clampedProgress
        )
    }

    /// estimatedTotalSeconds = elapsed / (progress / 100), with safety guards.
    static func estimatedTotalSeconds(elapsed: TimeInterval, progressPercent: Int) -> TimeInterval {
        guard elapsed > 0, progressPercent > 0 else { return max(elapsed, 0) }

        let clampedProgress = min(max(Double(progressPercent), 0), 100)
        let effectiveProgress = max(clampedProgress, minProgressPercentForEstimate)
        let progressFraction = effectiveProgress / 100.0

        var estimatedTotal = elapsed / progressFraction
        estimatedTotal = min(estimatedTotal, elapsed * maxEstimatedTotalMultiplier)
        return max(estimatedTotal, elapsed)
    }

    static func formatRuntimeDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int(duration / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            let hourWord = hours == 1 ? "Hour" : "Hours"
            let minuteWord = minutes == 1 ? "Minute" : "Minutes"
            return "\(hours) \(hourWord) and \(minutes) \(minuteWord) (\(totalMinutes) Mins)"
        }

        let minuteWord = totalMinutes == 1 ? "Minute" : "Minutes"
        return "\(totalMinutes) \(minuteWord) (\(totalMinutes) Mins)"
    }

    /// Human-readable duration for running-job elapsed/total/remaining labels.
    /// Uses Day/Hour/Minute vocabulary with singular/plural forms and "and" between parts.
    static func formatHumanReadableDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int((duration / 60).rounded()), 0)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            let dayWord = days == 1 ? "Day" : "Days"
            let hourWord = hours == 1 ? "Hour" : "Hours"
            let minuteWord = minutes == 1 ? "Minute" : "Minutes"
            if hours > 0 {
                return "\(days) \(dayWord) and \(hours) \(hourWord) and \(minutes) \(minuteWord)"
            }
            return "\(days) \(dayWord) and \(minutes) \(minuteWord)"
        }

        if hours > 0 {
            let hourWord = hours == 1 ? "Hour" : "Hours"
            let minuteWord = minutes == 1 ? "Minute" : "Minutes"
            return "\(hours) \(hourWord) and \(minutes) \(minuteWord)"
        }

        let minuteWord = totalMinutes == 1 ? "Minute" : "Minutes"
        return "\(totalMinutes) \(minuteWord)"
    }

    static func formatEstimatedCompletion(
        remaining: TimeInterval,
        completionDate: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        if remaining < relativeCompletionThreshold {
            return "in \(formatHumanReadableDuration(remaining))"
        }

        if calendar.isDate(completionDate, inSameDayAs: now) {
            return "Today at \(DetailTimeFormatter.shared.string(from: completionDate))"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(completionDate, inSameDayAs: tomorrow) {
            return "Tomorrow at \(DetailTimeFormatter.shared.string(from: completionDate))"
        }

        return DetailDateFormatter.shared.string(from: completionDate)
    }
}
