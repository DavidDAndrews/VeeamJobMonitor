import Foundation

// MARK: - Public model

struct VeeamJob: Identifiable {
    let id: String
    let name: String
    let jobDescription: String?
    let type: String?
    let status: String?         // e.g. "Running", "Inactive", "Disabled"
    let lastResult: String?     // e.g. "Success", "Warning", "Failed", "None"
    let lastRun: Date?
    let nextRun: Date?          // nil when Veeam hasn't scheduled the next run yet
    let isEnabled: Bool?
    let scheduleDescription: String?  // fallback when nextRun is nil, e.g. "Daily at 10:00 PM"
    let vmStorageSize: String?
    let repositoryName: String?
    let objectsCount: Int?
    let progressPercent: Int?
    let processingRateBytesPerSecond: Double?
    let processedSizeBytes: Int64?
    let readSizeBytes: Int64?
    let transferredSizeBytes: Int64?
    let driveSummary: String?
    let backupPoints: [VeeamBackupPoint]

    var isRunning: Bool  { status?.lowercased() == "running" }
    var enabled: Bool    { isEnabled ?? true }
    var jobType: String  { type ?? "Backup" }
    var isDisabled: Bool { !enabled || status?.lowercased() == "disabled" }
    var runningStatusText: String {
        "Running (\(max(progressPercent ?? 0, 0))%)"
    }

    var resultText: String {
        if isDisabled { return "Disabled" }
        if isRunning {
            let progress = max(progressPercent ?? 0, 0)
            return "Running (\(progress)%)"
        }
        guard let r = lastResult, r.lowercased() != "none" else {
            return lastResult == nil ? "Unknown" : "No Runs"
        }
        return r
    }

    var displayName: String {
        guard let jobDescription else { return name }
        let trimmed = jobDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name }
        return "\(name) [\(trimmed)]"
    }

    var totalStorageUsedText: String? {
        let totalBytes = backupPoints.reduce(Int64(0)) { partial, point in
            partial + max(point.backupSizeBytes ?? 0, 0)
        }
        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
}

struct VeeamBackupPoint: Identifiable {
    let id: String
    let name: String
    let creationTime: Date
    let type: String
    let status: String
    let gfsFlags: [String]
    let expirationDate: Date?
    let backupSizeBytes: Int64?
    let repositoryName: String?
    let backupSetName: String?

    var gfsText: String? {
        gfsFlags.isEmpty ? "R" : gfsFlags.joined(separator: " ")
    }

    var expirationText: String {
        if let expirationDate {
            return "Immutable until \(Self.expirationFormatter.string(from: expirationDate))"
        }
        if let gfsText, gfsText != "R" {
            return "GFS Retained"
        }
        return "—"
    }

    var backupSizeText: String {
        guard let backupSizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: backupSizeBytes, countStyle: .file)
    }

    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Saved Credentials

struct SavedCredentials {
    let serverURL: String
    let username: String
    let password: String
    let friendlyName: String?
}

struct SavedConnectionEntry: Identifiable {
    let serverURL: String
    let friendlyName: String
    var id: String { serverURL }
}

struct RestorePointDiskInfo: Identifiable {
    let id: String
    let name: String
    let type: String
    let capacityBytes: Int64
    let state: String

    var capacityText: String {
        ByteCountFormatter.string(fromByteCount: capacityBytes, countStyle: .file)
    }
}

struct JobRunLogEntry: Identifiable {
    let id: String
    let status: String
    let startTime: Date?
    let updateTime: Date?
    let message: String
}

struct JobRunLogSummary {
    let sessionID: String
    let sessionName: String
    let sessionType: String
    let startedAt: Date?
    let endedAt: Date?
    let state: String
    let result: String
    let entries: [JobRunLogEntry]
}

