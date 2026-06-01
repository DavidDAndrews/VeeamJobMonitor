import Foundation

// MARK: - Job result classification

enum JobResultBucket {
    case running
    case success
    case warning
    case failed
    case disabled
    case unknown
}

extension JobResultBucket {
    /// Unified color + icon + tint sourced from the shared design tokens.
    var style: StatusStyle { Theme.style(for: self) }
}

func jobResultBucket(for job: VeeamJob) -> JobResultBucket {
    classifyJobResult(isRunning: job.isRunning, isDisabled: job.isDisabled, resultText: job.resultText)
}

func jobResultBucket(for job: VeeamJob, contextResult: String?) -> JobResultBucket {
    let trimmedContext = contextResult?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let resultText = trimmedContext.isEmpty ? job.resultText : trimmedContext
    return classifyJobResult(isRunning: job.isRunning, isDisabled: job.isDisabled, resultText: resultText, fuzzyMatch: true)
}

private func classifyJobResult(isRunning: Bool, isDisabled: Bool, resultText: String, fuzzyMatch: Bool = false) -> JobResultBucket {
    if isRunning {
        return .running
    }
    if isDisabled {
        return .disabled
    }
    return bucketFromResultText(resultText, fuzzyMatch: fuzzyMatch)
}

private func bucketFromResultText(_ resultText: String, fuzzyMatch: Bool) -> JobResultBucket {
    let result = resultText.lowercased()
    if result.hasPrefix("running") {
        return .running
    }
    if fuzzyMatch {
        if result.contains("success") { return .success }
        if result.contains("warning") { return .warning }
        if result.contains("fail") || result.contains("error") { return .failed }
        if result.contains("disabled") { return .disabled }
    } else {
        if result == "success" { return .success }
        if result == "warning" || result.contains("warning") { return .warning }
        if result.contains("fail") || result.contains("error") { return .failed }
        if result.contains("disabled") { return .disabled }
    }
    if result == "unknown" || result == "no runs" {
        return .unknown
    }
    return .unknown
}

enum StatusFilter {
    case all
    case running
    case success
    case warning
    case failed
    case disabled
}
