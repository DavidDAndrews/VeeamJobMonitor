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
    if job.isRunning {
        return .running
    }
    if job.isDisabled {
        return .disabled
    }

    let result = job.resultText.lowercased()
    if result == "success" {
        return .success
    }
    if result == "warning" || result.contains("warning") {
        return .warning
    }
    if result.contains("fail") || result.contains("error") {
        return .failed
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

