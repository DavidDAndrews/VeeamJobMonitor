import Foundation
import Combine
import Security
#if canImport(AppKit)
import AppKit
#endif

struct StoredConnection: Codable {
    let serverURL: String
    let username: String
    let password: String
    let friendlyName: String?
}

// MARK: - Service

@MainActor
final class VeeamAPIService: ObservableObject {
    @Published var jobs: [VeeamJob] = []
    @Published var isAuthenticated = false
    /// Login / authentication activity. Job refresh and job actions use the dedicated flags below.
    @Published var isLoading = false
    @Published var isRefreshingJobs = false
    @Published var isPerformingAction = false
    @Published var isGeneratingReport = false
    @Published var loadingProgressPercent = 0
    @Published var errorMessage: String?
    @Published var mfaRequired = false
    @Published var mfaPromptMessage: String?
    @Published var requiresVBRTokenLogin = false

    var serverURL: String = ""
    var currentServerFriendlyName: String?
    var authToken: String?
    var refreshToken: String?
    var tokenExpiresAt: Date?
    var pendingLoginContext: PendingLoginContext?
    /// Populated from /api/v1/serverInfo after the server URL is known.
    /// Falls back to the preferred version if detection fails.
    var detectedApiVersion: String = "1.3-rev1"

    var apiVersion: String {
        detectedApiVersion.isEmpty ? Self.preferredApiVersion : detectedApiVersion
    }

    static let preferredApiVersion  = "1.3-rev1"
    static let fallbackApiVersion   = "1.2-rev0"
    static let supportedApiVersions = [
        "1.3-rev1",
        "1.3-rev0",
        "1.2-rev1",
        "1.2-rev0",
        "1.1-rev2",
        "1.1-rev1",
        "1.1-rev0",
        "1.0-rev2",
        "1.0-rev1"
    ]
    static let keychainService   = "bz.andrews.VeeamMonitor"
    static let keychainConnectionPrefix = "connection:"
    static let defaultsConnectionHistoryKey = "savedConnectionHistory"
    static let jobConfigFetchConcurrency = 12
    static let backupMetadataFetchConcurrency = 12
    static let jobRunLogFetchConcurrency = 8

    struct JobFetchCache {
        var statesByID: [String: JobState] = [:]
        var backupRecords: [BackupRecord] = []
        var backupObjects: [BackupObject] = []
        var restorePoints: [RestorePointRecord] = []
        var backupPointMetadataByRestorePointID: [String: BackupPointMetadata] = [:]
        var jobNamesByIdentifier: [String: String] = [:]
        var configsByID: [String: JobConfig] = [:]

        var hasBackupInventory: Bool {
            !backupRecords.isEmpty || !restorePoints.isEmpty
        }
    }

    var jobFetchCache = JobFetchCache()
    var jobConfigBackgroundTask: Task<Void, Never>?

    /// Cached session list reused across log-summary fetches within a load cycle.
    var cachedAllSessions: [SessionRecord]?
    var latestLogSummaryByJobID: [String: JobRunLogSummary] = [:]
    var fetchedLatestLogSummaryJobIDs: Set<String> = []
    var contextualLogSummaryByKey: [String: JobRunLogSummary] = [:]
    var fetchedContextualLogSummaryKeys: Set<String> = []
    var logSummaryBySessionID: [String: JobRunLogSummary] = [:]
    var inFlightLatestLogSummaryTasks: [String: Task<JobRunLogSummary?, Never>] = [:]

    struct PendingLoginContext {
        let serverURL: String
        let username: String
        let password: String
        let friendlyName: String?
        let challengeToken: String?
    }

    var session: URLSession = {
        // Ephemeral config avoids persistent sqlite-backed URL cache/cookie stores,
        // which can produce DetachedSignatures logging noise in sandboxed apps.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: PinningTrustDelegate(), delegateQueue: nil)
    }()

    /// Warms saved-connection keychain reads during the splash screen.
    func prepareForLaunch() {
        _ = savedConnectionURLs()
        _ = loadSavedCredentials()
    }

    var connectedServerDisplayName: String {
        if let friendly = currentServerFriendlyName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !friendly.isEmpty {
            return friendly.uppercased()
        }
        if !serverURL.isEmpty,
           let savedFriendly = loadSavedCredentials(for: serverURL)?.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !savedFriendly.isEmpty {
            return savedFriendly.uppercased()
        }
        guard !serverURL.isEmpty else { return "Not Connected" }
        if let url = URL(string: serverURL), let host = url.host, !host.isEmpty {
            return host
        }
        return serverURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    /// Lightweight connectivity probe used by the login form.
    /// Returns true when the host is reachable over HTTP(S), regardless of auth status code.
    func canReachServer(_ serverURL: String) async -> Bool {
        await checkServerReachability(serverURL) == .reachable
    }

    func checkServerReachability(_ serverURL: String, definitive: Bool = false) async -> ReachabilityStatus {
        if definitive {
            return await checkServerReachabilityForLogin(serverURL)
        }

        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let normalized = normalisedServerURL(trimmed)
        if let status = await ServerReachabilityProbe.shared.check(serverURL: trimmed, normalized: normalized) {
            return status
        }
        // Superseded by a newer probe; treat as still checking for callers that need a definite answer.
        return .checking
    }

    /// Definitive reachability check for login — not dropped when the UI schedules a newer probe.
    func checkServerReachabilityForLogin(_ serverURL: String) async -> ReachabilityStatus {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let normalized = normalisedServerURL(trimmed)
        return await ServerReachabilityProbe.shared.checkForLogin(serverURL: trimmed, normalized: normalized)
    }
}
