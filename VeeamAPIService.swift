import Foundation
import Combine
import Security
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

private struct StoredConnection: Codable {
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

    private var serverURL: String = ""
    private var currentServerFriendlyName: String?
    private var authToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?
    private var pendingLoginContext: PendingLoginContext?
    /// Populated from /api/v1/serverInfo after the server URL is known.
    /// Falls back to the preferred version if detection fails.
    private var detectedApiVersion: String = "1.3-rev1"

    private var apiVersion: String {
        detectedApiVersion.isEmpty ? Self.preferredApiVersion : detectedApiVersion
    }

    private static let preferredApiVersion  = "1.3-rev1"
    private static let fallbackApiVersion   = "1.2-rev0"
    private static let supportedApiVersions = [
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
    private static let keychainService   = "bz.andrews.VeeamMonitor"
    private static let keychainConnectionPrefix = "connection:"
    private static let defaultsConnectionHistoryKey = "savedConnectionHistory"
    private static let jobConfigFetchConcurrency = 12
    private static let backupMetadataFetchConcurrency = 12
    private static let jobRunLogFetchConcurrency = 8

    private struct JobFetchCache {
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

    private var jobFetchCache = JobFetchCache()
    private var jobConfigBackgroundTask: Task<Void, Never>?

    /// Cached session list reused across log-summary fetches within a load cycle.
    private var cachedAllSessions: [SessionRecord]?
    private var latestLogSummaryByJobID: [String: JobRunLogSummary] = [:]
    private var fetchedLatestLogSummaryJobIDs: Set<String> = []
    private var contextualLogSummaryByKey: [String: JobRunLogSummary] = [:]
    private var fetchedContextualLogSummaryKeys: Set<String> = []
    private var logSummaryBySessionID: [String: JobRunLogSummary] = [:]
    private var inFlightLatestLogSummaryTasks: [String: Task<JobRunLogSummary?, Never>] = [:]

    private struct PendingLoginContext {
        let serverURL: String
        let username: String
        let password: String
        let friendlyName: String?
        let challengeToken: String?
    }

    private var session: URLSession = {
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
    private func checkServerReachabilityForLogin(_ serverURL: String) async -> ReachabilityStatus {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let normalized = normalisedServerURL(trimmed)
        return await ServerReachabilityProbe.shared.checkForLogin(serverURL: trimmed, normalized: normalized)
    }

    // MARK: - Login

    func login(serverURL: String, username: String, password: String, friendlyName: String? = nil) async {
        await login(
            serverURL: serverURL,
            username: username,
            password: password,
            friendlyName: friendlyName,
            mfaCode: nil,
            mfaToken: nil
        )
    }

    func submitMFA(code: String) async {
        guard let pendingLoginContext else {
            errorMessage = "MFA session expired. Please sign in again."
            mfaRequired = false
            mfaPromptMessage = nil
            return
        }
        await login(
            serverURL: pendingLoginContext.serverURL,
            username: pendingLoginContext.username,
            password: pendingLoginContext.password,
            friendlyName: pendingLoginContext.friendlyName,
            mfaCode: code,
            mfaToken: pendingLoginContext.challengeToken
        )
    }

    func loginWithVBRToken(
        serverURL: String,
        friendlyName: String?,
        vbrToken: String
    ) async {
        self.serverURL = normalisedServerURL(serverURL)
        let requestedFriendly = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentServerFriendlyName = (requestedFriendly?.isEmpty == false) ? requestedFriendly?.uppercased() : nil
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "\(self.serverURL)/api/oauth2/token") else {
            errorMessage = "Invalid server URL"; return
        }

        if await checkServerReachabilityForLogin(self.serverURL) != .reachable {
            errorMessage = ServerReachability.unreachableMessage(for: self.serverURL)
            return
        }

        do {
            let request = makeLoginRequest(
                url: url,
                username: "",
                password: "",
                apiVersion: apiVersion,
                grantMode: .vbrToken,
                mfaCode: nil,
                mfaToken: vbrToken
            )
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Invalid server response."
                return
            }
            guard http.statusCode == 200 else {
                errorMessage = makeLoginErrorMessage(statusCode: http.statusCode, data: data)
                return
            }
            detectedApiVersion = apiVersion
            applyTokenResponse(try JSONDecoder().decode(VeeamTokenResponse.self, from: data))
            saveConnectionHistoryEntry(self.serverURL)
            isAuthenticated = true
            mfaRequired = false
            mfaPromptMessage = nil
            requiresVBRTokenLogin = false
            pendingLoginContext = nil
        } catch {
            errorMessage = makeConnectionErrorMessage(error, serverURL: self.serverURL)
        }
    }

    /// Stores the access token plus optional refresh token / expiry from an OAuth token response.
    private func applyTokenResponse(_ token: VeeamTokenResponse) {
        authToken = token.accessToken
        if let refresh = token.refreshToken, !refresh.isEmpty {
            refreshToken = refresh
        }
        if let expiresIn = token.expiresIn {
            tokenExpiresAt = Date().addingTimeInterval(Double(expiresIn))
        } else {
            tokenExpiresAt = nil
        }
    }

    private func login(
        serverURL: String,
        username: String,
        password: String,
        friendlyName: String? = nil,
        mfaCode: String?,
        mfaToken: String?
    ) async {
        self.serverURL = normalisedServerURL(serverURL)
        let requestedFriendly = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentServerFriendlyName = (requestedFriendly?.isEmpty == false) ? requestedFriendly?.uppercased() : nil
        isLoading = true
        errorMessage = nil
        requiresVBRTokenLogin = false
        defer { isLoading = false }

        guard let url = URL(string: "\(self.serverURL)/api/oauth2/token") else {
            errorMessage = "Invalid server URL"; return
        }

        if await checkServerReachabilityForLogin(self.serverURL) != .reachable {
            errorMessage = ServerReachability.unreachableMessage(for: self.serverURL)
            return
        }

        do {
            let result = try await loginRequest(
                url: url,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                mfaCode: mfaCode,
                mfaToken: mfaToken
            )

            guard result.response.statusCode == 200 else {
                if let challenge = parseMFAChallenge(from: result.data, statusCode: result.response.statusCode) {
                    pendingLoginContext = PendingLoginContext(
                        serverURL: self.serverURL,
                        username: username,
                        password: password,
                        friendlyName: friendlyName,
                        challengeToken: challenge.token
                    )
                    mfaRequired = true
                    mfaPromptMessage = challenge.message ?? "MFA is required. Enter your one-time verification code."
                    requiresVBRTokenLogin = (challenge.message ?? "").lowercased().contains("not currently supported")
                    errorMessage = nil
                    return
                }
                errorMessage = makeLoginErrorMessage(statusCode: result.response.statusCode, data: result.data)
                return
            }
            detectedApiVersion = result.apiVersion
            applyTokenResponse(try JSONDecoder().decode(VeeamTokenResponse.self, from: result.data))
            if currentServerFriendlyName == nil {
                currentServerFriendlyName = loadSavedCredentials(for: self.serverURL)?.friendlyName
            }
            saveCredentials(serverURL: self.serverURL, username: username, password: password, friendlyName: friendlyName)
            if currentServerFriendlyName == nil {
                currentServerFriendlyName = loadSavedCredentials(for: self.serverURL)?.friendlyName
            }
            isAuthenticated = true
            mfaRequired = false
            mfaPromptMessage = nil
            pendingLoginContext = nil
        } catch {
            errorMessage = makeConnectionErrorMessage(error, serverURL: self.serverURL)
        }
    }

    func logout() {
        authToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        isAuthenticated = false
        jobs = []
        errorMessage = nil
        currentServerFriendlyName = nil
        jobConfigBackgroundTask?.cancel()
        jobConfigBackgroundTask = nil
        clearJobFetchCache()
    }

    // MARK: - Jobs

    /// Loads per-job configuration on demand and merges config-derived fields into the job list.
    func loadJobConfigDetails(for jobID: String, force: Bool = false) async {
        guard authToken != nil else { return }

        let normalizedID = normalisedJobIdentifier(jobID)
        guard let state = jobFetchCache.statesByID[normalizedID] else { return }

        let config: JobConfig?
        if !force, let cached = jobFetchCache.configsByID[normalizedID] {
            config = cached
        } else {
            guard let token = authToken else { return }
            let decoder = makeDecoder()
            guard let fetched = await fetchJobConfig(token: token, decoder: decoder, jobID: state.id) else {
                return
            }
            jobFetchCache.configsByID[normalizedID] = fetched
            config = fetched
        }

        applyJobConfig(to: state, config: config)
    }

    /// Ensures every loaded job has config metadata (including descriptions) before rendering reports.
    func ensureAllJobConfigsLoaded() async {
        if let task = jobConfigBackgroundTask {
            await task.value
            jobConfigBackgroundTask = nil
        }

        let states = Array(jobFetchCache.statesByID.values)
        guard !states.isEmpty else { return }
        await loadMissingJobConfigs(for: states)
    }

    private func scheduleBackgroundJobConfigLoad(for states: [JobState]) {
        jobConfigBackgroundTask?.cancel()
        jobConfigBackgroundTask = Task {
            await loadMissingJobConfigs(for: states)
        }
    }

    private func loadMissingJobConfigs(for states: [JobState]) async {
        guard let token = authToken else { return }

        let missingJobIDs = states.compactMap { state -> String? in
            let normalizedID = normalisedJobIdentifier(state.id)
            return jobFetchCache.configsByID[normalizedID] == nil ? state.id : nil
        }
        guard !missingJobIDs.isEmpty else { return }

        let decoder = makeDecoder()
        let configs = await fetchJobConfigs(token: token, decoder: decoder, jobIDs: missingJobIDs)
        guard !Task.isCancelled else { return }

        for config in configs {
            jobFetchCache.configsByID[normalisedJobIdentifier(config.id)] = config
        }

        applyAllCachedConfigsToJobs()
    }

    private func applyAllCachedConfigsToJobs() {
        guard !jobs.isEmpty else { return }

        jobs = jobs.map { job in
            let normalizedID = normalisedJobIdentifier(job.id)
            guard let state = jobFetchCache.statesByID[normalizedID],
                  let config = jobFetchCache.configsByID[normalizedID] else {
                return job
            }

            var sessionProgressByJobID: [String: Int] = [:]
            if job.isRunning, let progress = job.progressPercent {
                sessionProgressByJobID[normalizedID] = progress
            }

            return buildVeeamJob(
                from: state,
                config: config,
                jobNamesByIdentifier: jobFetchCache.jobNamesByIdentifier,
                sessionProgressByJobID: sessionProgressByJobID,
                backupRecords: jobFetchCache.backupRecords,
                backupObjects: jobFetchCache.backupObjects,
                restorePoints: jobFetchCache.restorePoints,
                backupPointMetadataByRestorePointID: jobFetchCache.backupPointMetadataByRestorePointID
            )
        }
    }

    func fetchJobs(reloadBackupInventory: Bool = true) async {
        guard authToken != nil else { return }

        // Proactively refresh an expired access token before the large paginated fetch,
        // because most of those fetchers use best-effort `try?` and would silently drop data.
        if let expiry = tokenExpiresAt, expiry <= Date() {
            _ = await refreshAccessToken()
        }
        guard let token = authToken else { return }

        let shouldReloadBackupInventory = reloadBackupInventory || !jobFetchCache.hasBackupInventory
        jobConfigBackgroundTask?.cancel()
        jobConfigBackgroundTask = nil
        if shouldReloadBackupInventory {
            clearJobFetchCache()
        } else {
            jobFetchCache.statesByID = [:]
        }

        isRefreshingJobs = true
        loadingProgressPercent = 0
        errorMessage = nil
        defer {
            isRefreshingJobs = false
            loadingProgressPercent = 100
        }

        let decoder = makeDecoder()
        func updateProgress(_ value: Int) {
            loadingProgressPercent = min(max(value, 0), 100)
        }

        let states = await fetchJobStates(token: token, decoder: decoder) { statesProgress in
            // Job-state paging is the biggest part of initial loading, so it carries most weight.
            updateProgress(Int((statesProgress * 0.60 * 100.0).rounded()))
        }

        guard let states else { return }   // error already set by fetchJobStates

        let backupRecords: [BackupRecord]
        let backupObjects: [BackupObject]
        let restorePoints: [RestorePointRecord]
        let backupPointMetadataByRestorePointID: [String: BackupPointMetadata]

        if shouldReloadBackupInventory {
            updateProgress(65)

            async let fetchedBackupRecords = fetchBackupRecords(token: token, decoder: decoder)
            async let fetchedBackupObjects = fetchBackupObjects(token: token, decoder: decoder)
            async let fetchedRestorePoints = fetchRestorePoints(token: token, decoder: decoder)

            backupRecords = await fetchedBackupRecords ?? []
            backupObjects = await fetchedBackupObjects ?? []
            restorePoints = await fetchedRestorePoints ?? []
            updateProgress(85)

            backupPointMetadataByRestorePointID = await fetchBackupPointMetadataByRestorePointID(
                token: token,
                decoder: decoder,
                backupIDs: Set(backupRecords.map(\.id))
            )
            updateProgress(95)

            jobFetchCache.backupRecords = backupRecords
            jobFetchCache.backupObjects = backupObjects
            jobFetchCache.restorePoints = restorePoints
            jobFetchCache.backupPointMetadataByRestorePointID = backupPointMetadataByRestorePointID
        } else {
            updateProgress(85)
            backupRecords = jobFetchCache.backupRecords
            backupObjects = jobFetchCache.backupObjects
            restorePoints = jobFetchCache.restorePoints
            backupPointMetadataByRestorePointID = jobFetchCache.backupPointMetadataByRestorePointID
            updateProgress(95)
        }

        let jobNamesByIdentifier = states.reduce(into: jobFetchCache.jobNamesByIdentifier) { result, state in
            result[normalisedJobIdentifier(state.id)] = state.name
        }
        for state in states {
            jobFetchCache.statesByID[normalisedJobIdentifier(state.id)] = state
        }
        jobFetchCache.jobNamesByIdentifier = jobNamesByIdentifier

        let sessionProgressByJobID = await fetchSessionProgressForRunningJobs(
            states: states,
            token: token,
            decoder: decoder
        )
        jobs = states.map { state in
            let normalizedJobID = normalisedJobIdentifier(state.id)
            let cachedConfig = jobFetchCache.configsByID[normalizedJobID]
            return buildVeeamJob(
                from: state,
                config: cachedConfig,
                jobNamesByIdentifier: jobNamesByIdentifier,
                sessionProgressByJobID: sessionProgressByJobID,
                backupRecords: backupRecords,
                backupObjects: backupObjects,
                restorePoints: restorePoints,
                backupPointMetadataByRestorePointID: backupPointMetadataByRestorePointID
            )
        }
        updateProgress(100)
        scheduleBackgroundJobConfigLoad(for: states)
    }

    private func clearJobFetchCache() {
        jobFetchCache = JobFetchCache()
        clearLogSummaryCache()
    }

    private func clearLogSummaryCache() {
        cachedAllSessions = nil
        latestLogSummaryByJobID = [:]
        fetchedLatestLogSummaryJobIDs = []
        contextualLogSummaryByKey = [:]
        fetchedContextualLogSummaryKeys = []
        logSummaryBySessionID = [:]
        for task in inFlightLatestLogSummaryTasks.values {
            task.cancel()
        }
        inFlightLatestLogSummaryTasks = [:]
    }

    func hasCachedLatestJobRunLogSummary(for jobID: String) -> Bool {
        fetchedLatestLogSummaryJobIDs.contains(jobID)
    }

    func cachedLatestJobRunLogSummary(for jobID: String) -> JobRunLogSummary? {
        latestLogSummaryByJobID[jobID]
    }

    private func storeLatestLogSummaryCache(jobID: String, summary: JobRunLogSummary?) {
        fetchedLatestLogSummaryJobIDs.insert(jobID)
        if let summary {
            latestLogSummaryByJobID[jobID] = summary
        } else {
            latestLogSummaryByJobID.removeValue(forKey: jobID)
        }
    }

    private func contextualLogSummaryCacheKey(jobID: String, referenceDate: Date) -> String {
        "\(jobID)|\(Int(referenceDate.timeIntervalSince1970))"
    }

    private func ensureAllSessionsCached(token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        if let cachedAllSessions {
            return cachedAllSessions
        }
        let sessions = await fetchAllSessions(token: token, decoder: decoder)
        cachedAllSessions = sessions
        return sessions
    }

    private func applyJobConfig(to state: JobState, config: JobConfig?) {
        let normalizedID = normalisedJobIdentifier(state.id)
        guard let index = jobs.firstIndex(where: { normalisedJobIdentifier($0.id) == normalizedID }) else {
            return
        }

        var sessionProgressByJobID: [String: Int] = [:]
        if jobs[index].isRunning, let progress = jobs[index].progressPercent {
            sessionProgressByJobID[normalizedID] = progress
        }

        replaceJob(
            at: index,
            with: buildVeeamJob(
                from: state,
                config: config,
                jobNamesByIdentifier: jobFetchCache.jobNamesByIdentifier,
                sessionProgressByJobID: sessionProgressByJobID,
                backupRecords: jobFetchCache.backupRecords,
                backupObjects: jobFetchCache.backupObjects,
                restorePoints: jobFetchCache.restorePoints,
                backupPointMetadataByRestorePointID: jobFetchCache.backupPointMetadataByRestorePointID
            )
        )
    }

    /// Reassigns the jobs array so `@Published` emits (in-place subscript writes do not).
    private func replaceJob(at index: Int, with job: VeeamJob) {
        var updated = jobs
        updated[index] = job
        jobs = updated
    }

    private func buildVeeamJob(
        from state: JobState,
        config: JobConfig?,
        jobNamesByIdentifier: [String: String],
        sessionProgressByJobID: [String: Int],
        backupRecords: [BackupRecord],
        backupObjects: [BackupObject],
        restorePoints: [RestorePointRecord],
        backupPointMetadataByRestorePointID: [String: BackupPointMetadata]
    ) -> VeeamJob {
        let normalizedJobID = normalisedJobIdentifier(state.id)
        let isEnabled = config?.isDisabled.map { !$0 } ?? state.isEnabled
        let normalizedNextRun = validatedNextRun(lastRun: state.lastRun, nextRun: state.nextRun)
        let directProgress = max(state.progressPercent ?? 0, state.sessionProgress?.progressPercent ?? 0)
        let fallbackProgress = sessionProgressByJobID[normalizedJobID] ?? 0
        let resolvedProgress: Int? = {
            if state.status?.lowercased() == "running" {
                let best = max(directProgress, fallbackProgress)
                return best > 0 ? best : 0
            }
            let best = max(directProgress, fallbackProgress)
            return best > 0 ? best : nil
        }()
        let inventory = backupInventory(
            for: state,
            config: config,
            backupRecords: backupRecords,
            backupObjects: backupObjects,
            restorePoints: restorePoints,
            backupPointMetadataByRestorePointID: backupPointMetadataByRestorePointID
        )

        return VeeamJob(
            id: state.id,
            name: state.name,
            jobDescription: config?.description,
            type: state.type,
            status: state.status,
            lastResult: state.lastResult,
            lastRun: state.lastRun,
            nextRun: normalizedNextRun,
            isEnabled: isEnabled,
            scheduleDescription: stateScheduleDescription(
                for: state,
                config: config?.schedule,
                jobNamesByIdentifier: jobNamesByIdentifier
            ),
            vmStorageSize: inventory.vmStorageSize,
            repositoryName: state.repositoryName,
            objectsCount: state.objectsCount,
            progressPercent: resolvedProgress,
            processingRateBytesPerSecond: parseProcessingRateBytesPerSecond(state.sessionProgress?.processingRate),
            processedSizeBytes: state.sessionProgress?.processedSize,
            readSizeBytes: state.sessionProgress?.readSize,
            transferredSizeBytes: state.sessionProgress?.transferredSize,
            driveSummary: inventory.driveSummary,
            backupPoints: inventory.backupPoints
        )
    }

    private func parseProcessingRateBytesPerSecond(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*([kmg])?b(?:/s|ps|/sec)"#
        guard let range = text.lowercased().range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(text.lowercased()[range])
        let components = match.replacingOccurrences(of: " ", with: "")
        let valuePattern = #"([0-9]+(?:\.[0-9]+)?)([kmg])?b"#
        guard let valueRange = components.range(of: valuePattern, options: .regularExpression) else {
            return nil
        }
        let valueChunk = String(components[valueRange])
        var numberText = ""
        var unit: Character?
        for ch in valueChunk {
            if ch.isNumber || ch == "." {
                numberText.append(ch)
            } else if ch == "k" || ch == "m" || ch == "g" {
                unit = ch
                break
            }
        }
        guard let value = Double(numberText) else { return nil }
        switch unit {
        case "k": return value * 1_024
        case "m": return value * 1_048_576
        case "g": return value * 1_073_741_824
        default: return value
        }
    }

    /// Lightweight poll used by UI timers: checks running-job progress and only
    /// performs a full job refresh if one or more running percentages changed.
    func refreshJobsIfRunningProgressChanged() async {
        guard let token = authToken else { return }
        let runningJobs = jobs.filter { $0.isRunning }
        guard !runningJobs.isEmpty else { return }

        let runningJobIDs = Set(runningJobs.map { normalisedJobIdentifier($0.id) })
        let runningJobNames = Set(runningJobs.map { normalizedJobNameKey($0.name) })
        let decoder = makeDecoder()
        let activeProgress = await fetchActiveSessionProgressLookup(
            runningJobIDs: runningJobIDs,
            runningJobNames: runningJobNames,
            token: token,
            decoder: decoder
        )

        let hasChange = runningJobs.contains { job in
            let idKey = normalisedJobIdentifier(job.id)
            let nameKey = normalizedJobNameKey(job.name)
            let latest = max(activeProgress.byJobID[idKey] ?? 0, activeProgress.byJobName[nameKey] ?? 0)
            let current = job.progressPercent ?? 0
            return latest > 0 && latest != current
        }

        if hasChange {
            await fetchJobs(reloadBackupInventory: false)
        }
    }

    func fetchLatestJobRunLogSummaries(
        for jobs: [VeeamJob],
        maxConcurrent: Int? = nil,
        onProgress: ((Int) -> Void)? = nil
    ) async -> [String: JobRunLogSummary?] {
        guard !jobs.isEmpty else { return [:] }
        guard let token = authToken else { return [:] }

        var summariesByJobID: [String: JobRunLogSummary?] = [:]
        summariesByJobID.reserveCapacity(jobs.count)
        var jobsToFetch: [VeeamJob] = []
        jobsToFetch.reserveCapacity(jobs.count)
        var completed = 0
        let total = jobs.count

        for job in jobs {
            if fetchedLatestLogSummaryJobIDs.contains(job.id) {
                summariesByJobID[job.id] = latestLogSummaryByJobID[job.id]
                completed += 1
                onProgress?(Int((Double(completed) / Double(total) * 85.0).rounded()))
            } else {
                jobsToFetch.append(job)
            }
        }

        guard !jobsToFetch.isEmpty else { return summariesByJobID }

        let decoder = makeDecoder()
        _ = await ensureAllSessionsCached(token: token, decoder: decoder)
        let concurrencyLimit = max(1, min(maxConcurrent ?? Self.jobRunLogFetchConcurrency, jobsToFetch.count))
        var iterator = jobsToFetch.makeIterator()

        await withTaskGroup(of: (String, JobRunLogSummary?).self) { group in
            for _ in 0..<concurrencyLimit {
                guard let job = iterator.next() else { break }
                group.addTask {
                    let summary = await self.fetchLatestJobRunLogSummary(for: job)
                    return (job.id, summary)
                }
            }

            for await (jobID, summary) in group {
                summariesByJobID[jobID] = summary
                completed += 1
                onProgress?(Int((Double(completed) / Double(total) * 85.0).rounded()))
                if let job = iterator.next() {
                    group.addTask {
                        let summary = await self.fetchLatestJobRunLogSummary(for: job)
                        return (job.id, summary)
                    }
                }
            }
        }

        return summariesByJobID
    }

    private func fetchSessionProgressForRunningJobs(
        states: [JobState],
        token: String,
        decoder: JSONDecoder
    ) async -> [String: Int] {
        let activeProgress = await fetchActiveSessionProgressLookup(states: states, token: token, decoder: decoder)
        var result: [String: Int] = [:]
        for state in states {
            guard state.status?.lowercased() == "running" else { continue }
            let directProgress = max(state.progressPercent ?? 0, state.sessionProgress?.progressPercent ?? 0)
            if directProgress > 0 {
                continue
            }
            let normalizedJobID = normalisedJobIdentifier(state.id)
            if let sessionID = state.sessionId, !sessionID.isEmpty,
               let progress = await fetchSessionProgressPercent(sessionID: sessionID, token: token, decoder: decoder) {
                result[normalizedJobID] = progress
                continue
            }

            if let progress = activeProgress.byJobID[normalizedJobID] {
                result[normalizedJobID] = progress
                continue
            }

            let normalizedJobName = normalizedJobNameKey(state.name)
            if let progress = activeProgress.byJobName[normalizedJobName] {
                result[normalizedJobID] = progress
            }
        }
        return result
    }

    private func fetchSessionProgressPercent(
        sessionID: String,
        token: String,
        decoder: JSONDecoder
    ) async -> Int? {
        guard let url = URL(string: "\(serverURL)/api/v1/sessions/\(sessionID)"),
              let (data, response) = try? await session.data(for: authorisedRequest(url: url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        if let sessionRecord = try? decoder.decode(SessionRecord.self, from: data),
           let p = sessionRecord.progressPercent {
            return p
        }
        if let raw = try? decoder.decode([String: AnyCodableValue].self, from: data) {
            return extractProgressPercent(from: raw)
        }
        return nil
    }

    private func fetchActiveSessionProgressLookup(
        states: [JobState],
        token: String,
        decoder: JSONDecoder
    ) async -> (byJobID: [String: Int], byJobName: [String: Int]) {
        let runningStates = states.filter { $0.status?.lowercased() == "running" }
        let runningJobIDs = Set(runningStates.map { normalisedJobIdentifier($0.id) })
        let runningJobNames = Set(runningStates.map { normalizedJobNameKey($0.name) })
        return await fetchActiveSessionProgressLookup(
            runningJobIDs: runningJobIDs,
            runningJobNames: runningJobNames,
            token: token,
            decoder: decoder
        )
    }

    private func fetchActiveSessionProgressLookup(
        runningJobIDs: Set<String>,
        runningJobNames: Set<String>,
        token: String,
        decoder: JSONDecoder
    ) async -> (byJobID: [String: Int], byJobName: [String: Int]) {

        guard var components = URLComponents(string: "\(serverURL)/api/v1/sessions") else {
            return ([:], [:])
        }
        components.queryItems = [
            URLQueryItem(name: "skip", value: "0"),
            URLQueryItem(name: "limit", value: "1000")
        ]
        guard let url = components.url,
              let (data, response) = try? await session.data(for: authorisedRequest(url: url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return ([:], [:])
        }

        var mapByID: [String: Int] = [:]
        var mapByName: [String: Int] = [:]

        func shouldInclude(_ state: String?) -> Bool {
            let s = state?.lowercased() ?? ""
            // Copy sessions are sometimes reported with different active states than
            // regular backup sessions. Keep this permissive and rely on running-job
            // id/name matching to avoid stale session contamination.
            if s.isEmpty { return true }
            return s != "stopped" && s != "success" && s != "failed" && s != "warning"
        }

        func update(_ map: inout [String: Int], key: String, progress: Int) {
            if let existing = map[key] {
                map[key] = max(existing, progress)
            } else {
                map[key] = progress
            }
        }

        if let sessions = try? decoder.decode(SessionsResponse.self, from: data).data {
            for session in sessions {
                guard shouldInclude(session.state) else { continue }
                guard let progress = session.progressPercent else {
                    continue
                }
                var matched = false
                if let jobID = session.jobId, !jobID.isEmpty {
                    let normalizedJobID = normalisedJobIdentifier(jobID)
                    if runningJobIDs.contains(normalizedJobID) {
                        update(&mapByID, key: normalizedJobID, progress: progress)
                        matched = true
                    }
                }
                if let sessionName = session.name,
                   let inferredJobName = inferJobNameFromSessionName(sessionName) {
                    let normalizedName = normalizedJobNameKey(inferredJobName)
                    if runningJobNames.contains(normalizedName) {
                        update(&mapByName, key: normalizedName, progress: progress)
                        matched = true
                    }
                }
                if !matched, let sessionName = session.name {
                    // Extra guard path: partial contains match for copy sessions
                    // where names include source object suffixes.
                    let normalizedSessionName = normalizedJobNameKey(sessionName)
                    if let matchedName = runningJobNames.first(where: { normalizedSessionName.contains($0) }) {
                        update(&mapByName, key: matchedName, progress: progress)
                    }
                }
            }
        }

        // Fallback for session payload variants (often seen with copy-job sessions).
        if let generic = try? decoder.decode(GenericSessionsResponse.self, from: data) {
            for session in generic.data {
                guard shouldInclude(extractString(from: session, matching: ["state"])) else { continue }
                guard let progress = extractProgressPercent(from: session) else {
                    continue
                }
                var matched = false
                if let jobID = extractString(from: session, matching: ["jobid", "jobuid", "jobidstring"]),
                   !jobID.isEmpty {
                    let normalizedJobID = normalisedJobIdentifier(jobID)
                    if runningJobIDs.contains(normalizedJobID) {
                        update(&mapByID, key: normalizedJobID, progress: progress)
                        matched = true
                    }
                }
                if let sessionName = extractString(from: session, matching: ["name", "sessionname"]),
                   let inferredJobName = inferJobNameFromSessionName(sessionName) {
                    let normalizedName = normalizedJobNameKey(inferredJobName)
                    if runningJobNames.contains(normalizedName) {
                        update(&mapByName, key: normalizedName, progress: progress)
                        matched = true
                    }
                }
                if !matched,
                   let sessionName = extractString(from: session, matching: ["name", "sessionname"]) {
                    let normalizedSessionName = normalizedJobNameKey(sessionName)
                    if let matchedName = runningJobNames.first(where: { normalizedSessionName.contains($0) }) {
                        update(&mapByName, key: matchedName, progress: progress)
                    }
                }
            }
        }
        return (mapByID, mapByName)
    }

    private func normalizedJobNameKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func inferJobNameFromSessionName(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Health-check sessions are typically named like:
        // "HealthCheck <JobName>\\<ObjectName>" or "Health Check <JobName> ..."
        // Strip the health-check prefix so inferred job matching can bind to real job names.
        let lowered = value.lowercased()
        if lowered.hasPrefix("healthcheck ") {
            value = String(value.dropFirst("healthcheck ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if lowered.hasPrefix("health check ") {
            value = String(value.dropFirst("health check ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Handle backslash separator (common in health check sessions)
        // e.g., "OPADSV0001.BCJ-OPBDSV0001\OPADSV0001" -> "OPADSV0001.BCJ-OPBDSV0001"
        if let backslash = value.firstIndex(of: "\\") {
            let prefix = String(value[..<backslash]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }

        // Handle forward slash separator
        if let slash = value.firstIndex(of: "/") {
            let prefix = String(value[..<slash]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }

        // Handle parenthesis (e.g., "JobName (Incremental)")
        if let paren = value.firstIndex(of: "(") {
            let prefix = String(value[..<paren]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { return prefix }
        }

        // Return the full name after prefix stripping
        return value
    }

    private func extractProgressPercent(from object: [String: AnyCodableValue]) -> Int? {
        var candidates: [Int] = []

        func visit(_ value: AnyCodableValue, keyHint: String?) {
            switch value {
            case .int(let v):
                if let keyHint, keyHint.contains("progress"), (0...100).contains(v) {
                    candidates.append(v)
                }
            case .double(let v):
                let intVal = Int(v.rounded())
                if let keyHint, keyHint.contains("progress"), (0...100).contains(intVal) {
                    candidates.append(intVal)
                }
            case .string(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if let keyHint, keyHint.contains("progress"),
                   let n = Int(trimmed),
                   (0...100).contains(n) {
                    candidates.append(n)
                }
                // Copy-job sessions often expose status text like "10% completed"
                // instead of numeric progress fields.
                if let percentFromText = extractPercentFromText(trimmed),
                   let keyHint,
                   (keyHint.contains("status") || keyHint.contains("result") || keyHint.contains("message") || keyHint.contains("progress")) {
                    candidates.append(percentFromText)
                }
            case .object(let o):
                for (k, v) in o {
                    visit(v, keyHint: k.lowercased())
                }
            case .array(let a):
                for v in a {
                    visit(v, keyHint: keyHint)
                }
            default:
                break
            }
        }

        for (k, v) in object {
            visit(v, keyHint: k.lowercased())
        }

        if let bestPositive = candidates.filter({ $0 > 0 }).max() {
            return bestPositive
        }
        return candidates.first
    }

    private func extractPercentFromText(_ text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d{1,3})\\s*%", options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Int(text[valueRange]),
              (0...100).contains(value) else {
            return nil
        }
        return value
    }

    private func extractString(from object: [String: AnyCodableValue], matching keys: [String]) -> String? {
        let lowered = Set(keys.map { $0.lowercased() })
        for (k, v) in object {
            if lowered.contains(k.lowercased()), case .string(let s) = v {
                return s
            }
        }
        return nil
    }

    private func validatedNextRun(lastRun: Date?, nextRun: Date?) -> Date? {
        guard let nextRun else { return nil }
        guard let lastRun else { return nextRun }
        return nextRun > lastRun ? nextRun : nil
    }

    func startJob(_ job: VeeamJob) async { await runJobAction(jobID: job.id, actionPath: "start", actionName: "start") }
    func startActiveFullJob(_ job: VeeamJob) async { await runStartActiveFullJob(jobID: job.id) }
    func stopJob(_ job: VeeamJob) async { await runJobAction(jobID: job.id, actionPath: "stop", actionName: "stop") }
    func retryJob(_ job: VeeamJob) async { await runJobAction(jobID: job.id, actionPath: "retry", actionName: "retry") }
    func enableJob(_ job: VeeamJob) async { await runJobAction(jobID: job.id, actionPath: "enable", actionName: "enable", ensureStateRefresh: true) }
    func disableJob(_ job: VeeamJob) async { await runJobAction(jobID: job.id, actionPath: "disable", actionName: "disable", ensureStateRefresh: true) }

    func fetchRestorePointDisks(restorePointID: String) async throws -> [RestorePointDiskInfo] {
        guard authToken != nil else {
            throw NSError(domain: "VeeamAPIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        guard let url = URL(string: "\(serverURL)/api/v1/restorePoints/\(restorePointID)/disks") else {
            throw URLError(.badURL)
        }

        let decoder = makeDecoder()
        let (data, http) = try await performAuthorized { token in
            authorisedRequest(url: url, token: token)
        }
        guard http.statusCode == 200 else {
            throw NSError(
                domain: "VeeamAPIService",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch restore point disks (HTTP \(http.statusCode))."]
            )
        }

        let records = try decoder.decode(RestorePointDisksResponse.self, from: data).data
        return records.map { record in
            RestorePointDiskInfo(
                id: record.uid,
                name: record.name ?? "Disk",
                type: record.type ?? "Unknown",
                capacityBytes: record.capacity ?? 0,
                state: record.state ?? "Unknown"
            )
        }
    }

    func fetchLatestJobRunLogSummary(for job: VeeamJob) async -> JobRunLogSummary? {
        if fetchedLatestLogSummaryJobIDs.contains(job.id) {
            return latestLogSummaryByJobID[job.id]
        }
        if let existingTask = inFlightLatestLogSummaryTasks[job.id] {
            return await existingTask.value
        }

        let task = Task { @MainActor in
            await self.resolveLatestJobRunLogSummaryUncached(for: job)
        }
        inFlightLatestLogSummaryTasks[job.id] = task
        let result = await task.value
        inFlightLatestLogSummaryTasks[job.id] = nil
        storeLatestLogSummaryCache(jobID: job.id, summary: result)
        return result
    }

    private func resolveLatestJobRunLogSummaryUncached(for job: VeeamJob) async -> JobRunLogSummary? {
        guard let token = authToken else { return nil }
        let decoder = makeDecoder()
        let allSessions = await ensureAllSessionsCached(token: token, decoder: decoder)
        return await resolveLatestJobRunLogSummary(
            for: job,
            allSessions: allSessions,
            token: token,
            decoder: decoder
        )
    }

    private func resolveLatestJobRunLogSummary(
        for job: VeeamJob,
        allSessions: [SessionRecord],
        token: String,
        decoder: JSONDecoder
    ) async -> JobRunLogSummary? {
        let matching = matchingSessions(for: job, in: allSessions)
        guard let latestSession = selectLatestSession(for: job, from: matching) else {
            return nil
        }
        return await fetchJobRunLogSummary(for: job, session: latestSession, token: token, decoder: decoder)
    }

    func fetchJobRunLogSummary(for job: VeeamJob, near referenceDate: Date) async -> JobRunLogSummary? {
        let cacheKey = contextualLogSummaryCacheKey(jobID: job.id, referenceDate: referenceDate)
        if fetchedContextualLogSummaryKeys.contains(cacheKey) {
            return contextualLogSummaryByKey[cacheKey]
        }

        guard let token = authToken else { return nil }
        let decoder = makeDecoder()
        let sessions = await ensureAllSessionsCached(token: token, decoder: decoder)
        let matching = matchingSessions(for: job, in: sessions)
        guard !matching.isEmpty else {
            storeContextualLogSummaryCache(key: cacheKey, summary: nil)
            return nil
        }
        let expectsCopySession = isBackupCopyJob(job)

        // For backup copy jobs, sessions run AFTER the restore point was created (often days/weeks later).
        // The restore point creationTime is from the SOURCE backup job, not the copy job session.
        // Therefore, we cannot use temporal proximity filtering for copy jobs.
        let sortedCandidates: [SessionRecord]
        
        if expectsCopySession {
            // For copy jobs: inspect ALL sessions and rely entirely on log content matching.
            // Copy sessions run after points are created, so temporal filtering is counterproductive.
            sortedCandidates = matching.sorted { lhs, rhs in
                // Sort by session start time (most recent first) to prioritize newer sessions
                // in the validation window, but we'll still check older ones if needed.
                let lhsDate = lhs.creationTime ?? lhs.endTime ?? .distantPast
                let rhsDate = rhs.creationTime ?? rhs.endTime ?? .distantPast
                return lhsDate > rhsDate
            }
        } else {
            // For regular backup jobs: use temporal proximity filtering.
            let futureTolerance: TimeInterval = 10 * 60 // 10 minutes
            let nonFutureSessions = matching.filter { session in
                let anchor = session.creationTime ?? session.endTime ?? .distantPast
                return anchor <= referenceDate.addingTimeInterval(futureTolerance)
            }
            let candidatePool = nonFutureSessions.isEmpty ? matching : nonFutureSessions

            sortedCandidates = candidatePool.sorted { lhs, rhs in
                let lhsDate = lhs.creationTime ?? lhs.endTime ?? .distantPast
                let rhsDate = rhs.creationTime ?? rhs.endTime ?? .distantPast
                return abs(lhsDate.timeIntervalSince(referenceDate)) < abs(rhsDate.timeIntervalSince(referenceDate))
            }
        }

        // For copy jobs, scan more sessions since temporal sorting is unreliable.
        let validationWindow = expectsCopySession ? min(sortedCandidates.count, 30) : min(sortedCandidates.count, 12)
        var bestSummary: JobRunLogSummary?
        var bestScore = Int.min

        for candidate in sortedCandidates.prefix(validationWindow) {
            guard let summary = await fetchJobRunLogSummary(for: job, session: candidate, token: token, decoder: decoder) else {
                continue
            }
            let score = sessionMatchScore(summary: summary, referenceDate: referenceDate, isCopyJob: expectsCopySession)
            if score > bestScore {
                bestScore = score
                bestSummary = summary
            }
            // For copy jobs, require explicit log content match (score >= 5).
            // For regular jobs, allow temporal match (score >= 10).
            let requiredScore = expectsCopySession ? 5 : 10
            if score >= requiredScore {
                storeContextualLogSummaryCache(key: cacheKey, summary: summary)
                return summary
            }
        }

        // Return best match found, or nil if no reasonable match exists.
        // For copy jobs, require a minimum positive score to avoid false matches.
        let resolvedSummary: JobRunLogSummary?
        if let bestSummary {
            if expectsCopySession && bestScore < 2 {
                // No confident match found for copy job - return nil rather than guessing.
                resolvedSummary = nil
            } else {
                resolvedSummary = bestSummary
            }
        } else {
            resolvedSummary = nil
        }

        storeContextualLogSummaryCache(key: cacheKey, summary: resolvedSummary)
        return resolvedSummary
    }

    private func storeContextualLogSummaryCache(key: String, summary: JobRunLogSummary?) {
        fetchedContextualLogSummaryKeys.insert(key)
        if let summary {
            contextualLogSummaryByKey[key] = summary
        } else {
            contextualLogSummaryByKey.removeValue(forKey: key)
        }
    }

    private func sessionMatchScore(summary: JobRunLogSummary, referenceDate: Date, isCopyJob: Bool) -> Int {
        var score = 0

        // For backup copy jobs, temporal matching is unreliable because:
        // - Restore point creationTime = when SOURCE backup created it
        // - Session creationTime = when COPY job ran (often days/weeks later)
        // Therefore, we rely primarily on log message content for copy jobs.
        
        if !isCopyJob {
            // Regular backup jobs: use temporal proximity scoring
            if let startedAt = summary.startedAt {
                if isSameLocalDay(startedAt, referenceDate) {
                    score += 12
                } else {
                    score -= 8
                }
                if startedAt > referenceDate.addingTimeInterval(10 * 60) {
                    score -= 12
                }
                let delta = abs(startedAt.timeIntervalSince(referenceDate))
                switch delta {
                case ..<900:      score += 6   // 15 min
                case ..<3600:     score += 4   // 1 hour
                case ..<21600:    score += 2   // 6 hours
                default:          break
                }
            }
        }

        // Log content matching (used for both job types, but especially critical for copy jobs)
        let shortDate = copySessionDateFormatter.string(from: referenceDate).lowercased()
        let shortDate2DigitYear = copySessionDateFormatterTwoDigitYear.string(from: referenceDate).lowercased()
        let timeToken = copySessionTimeFormatter.string(from: referenceDate).lowercased()

        for entry in summary.entries {
            let message = entry.message.lowercased()
            
            // Check for restore point copy operations mentioning the specific date/time
            let isCopyRestoreMessage = message.contains("copying restore point") 
                || message.contains("restore point")
                || message.contains("processing")
            
            let hasDateToken = message.contains(shortDate) || message.contains(shortDate2DigitYear)
            
            if hasDateToken {
                score += 3  // Increased from 2
            }
            
            if isCopyRestoreMessage && hasDateToken {
                score += 8  // Increased from 5
                if message.contains(timeToken) {
                    score += 8  // Increased from 5
                }
            }
        }

        return score
    }

    private func isSameLocalDay(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    private var copySessionDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }

    private var copySessionDateFormatterTwoDigitYear: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }

    private var copySessionTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm"
        return formatter
    }

    private func fetchJobRunLogSummary(
        for job: VeeamJob,
        session sessionRecord: SessionRecord,
        token: String,
        decoder: JSONDecoder
    ) async -> JobRunLogSummary? {
        if let cached = logSummaryBySessionID[sessionRecord.id] {
            return cached
        }

        guard let sessionID = sessionRecord.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let logsURL = URL(string: "\(serverURL)/api/v1/sessions/\(sessionID)/logs") else {
            return nil
        }

        var request = authorisedRequest(url: logsURL, token: token)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let logResponse = try? decoder.decode(SessionLogsResponse.self, from: data) else {
            return nil
        }

        let entries = logResponse.records.compactMap { record -> JobRunLogEntry? in
            let title = record.title?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let description = record.description?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            let additional = record.additionalInfo?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""

            var parts: [String] = []
            if !title.isEmpty { parts.append(title) }
            if !description.isEmpty { parts.append(description) }
            if !additional.isEmpty { parts.append(additional) }
            let message = parts.joined(separator: " — ")
            guard !message.isEmpty else { return nil }

            let stableID = "\(record.id ?? -1)-\(Int((record.updateTime ?? record.startTime ?? .distantPast).timeIntervalSince1970))-\(message.prefix(20))"
            return JobRunLogEntry(
                id: stableID,
                status: (record.status ?? "info").lowercased(),
                startTime: record.startTime,
                updateTime: record.updateTime,
                message: message
            )
        }

        let summary = JobRunLogSummary(
            sessionID: sessionRecord.id,
            sessionName: sessionRecord.name ?? job.name,
            sessionType: sessionRecord.sessionType ?? job.jobType,
            startedAt: sessionRecord.creationTime,
            endedAt: sessionRecord.endTime,
            state: sessionRecord.state ?? "Unknown",
            result: sessionRecord.result?.result ?? "Unknown",
            entries: entries
        )
        logSummaryBySessionID[sessionRecord.id] = summary
        return summary
    }

    // MARK: - Private fetch helpers

    private func fetchLatestSession(for job: VeeamJob, token: String, decoder: JSONDecoder) async -> SessionRecord? {
        let matching = await fetchMatchingSessions(for: job, token: token, decoder: decoder)
        return selectLatestSession(for: job, from: matching)
    }

    private func selectLatestSession(for job: VeeamJob, from matching: [SessionRecord]) -> SessionRecord? {
        guard !matching.isEmpty else { return nil }

        // For running jobs (especially Backup Copy), prefer an active session.
        // Otherwise runtime can be computed from an older completed session.
        if job.isRunning {
            let activeCandidates = matching.filter { isActiveSession(state: $0.state, result: $0.result?.result) }
            if let newestActive = newestSession(in: activeCandidates) {
                return newestActive
            }
        }

        // If the job exposes a lastRun anchor, choose the nearest matching session.
        if let referenceDate = job.lastRun {
            let nearest = matching.min { lhs, rhs in
                let lhsDate = lhs.creationTime ?? lhs.endTime ?? .distantPast
                let rhsDate = rhs.creationTime ?? rhs.endTime ?? .distantPast
                return abs(lhsDate.timeIntervalSince(referenceDate)) < abs(rhsDate.timeIntervalSince(referenceDate))
            }
            if let nearest {
                return nearest
            }
        }

        return newestSession(in: matching)
    }

    private func newestSession(in sessions: [SessionRecord]) -> SessionRecord? {
        sessions.max { lhs, rhs in
            let lhsDate = lhs.endTime ?? lhs.creationTime ?? .distantPast
            let rhsDate = rhs.endTime ?? rhs.creationTime ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func isActiveSession(state: String?, result: String?) -> Bool {
        let stateText = (state ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resultText = (result ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let terminalStates: Set<String> = [
            "stopped", "success", "failed", "warning", "finished", "completed", "done", "idle", "inactive"
        ]
        let terminalResults: Set<String> = [
            "success", "failed", "warning", "canceled", "stopped", "none"
        ]

        if !stateText.isEmpty && terminalStates.contains(stateText) {
            return false
        }
        if !resultText.isEmpty && terminalResults.contains(resultText) {
            return false
        }
        return true
    }

    private func fetchMatchingSessions(for job: VeeamJob, token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        let sessions = await ensureAllSessionsCached(token: token, decoder: decoder)
        return matchingSessions(for: job, in: sessions)
    }

    private func matchingSessions(for job: VeeamJob, in sessions: [SessionRecord]) -> [SessionRecord] {
        let normalizedJobID = normalisedJobIdentifier(job.id)
        let normalizedJobName = normalizedJobNameKey(job.name)
        let expectsCopySession = isBackupCopyJob(job)

        let filtered = sessions.filter { session in
            if expectsCopySession {
                // Prevent false positives: do not bind regular backup sessions
                // to copy jobs (this was causing 5/21 selected point -> 5/22 backup run logs).
                let typeText = (session.sessionType ?? "").lowercased()
                let nameText = normalizedJobNameKey(session.name ?? "")
                let looksLikeCopy = typeText.contains("copy")
                    || nameText.contains("-bcj")
                    || nameText.contains("\\")
                if !looksLikeCopy {
                    return false
                }
            }

            if let jobID = session.jobId, !jobID.isEmpty,
               normalisedJobIdentifier(jobID) == normalizedJobID {
                return true
            }
            if let sessionName = session.name {
                let inferred = normalizedJobNameKey(inferJobNameFromSessionName(sessionName) ?? sessionName)
                if inferred == normalizedJobName {
                    return true
                }

                // Copy-job session names frequently include source object names:
                // "<JobName>\\<VMName> (Incremental)".
                // Accept containment match so selecting backup points can resolve
                // the correct session context for runtime/log detail.
                let normalizedSessionName = normalizedJobNameKey(sessionName)
                if normalizedSessionName.contains(normalizedJobName) {
                    return true
                }
            }
            return false
        }

        // Keep newest-first for deterministic "latest"/nearest behavior.
        return filtered.sorted { lhs, rhs in
            let lhsDate = lhs.creationTime ?? lhs.endTime ?? .distantPast
            let rhsDate = rhs.creationTime ?? rhs.endTime ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func isBackupCopyJob(_ job: VeeamJob) -> Bool {
        let typeText = (job.type ?? "").lowercased()
        let jobTypeText = job.jobType.lowercased()
        let nameText = job.name.lowercased()
        return typeText.contains("copy")
            || jobTypeText.contains("copy")
            || nameText.contains("-bcj")
    }

    private func fetchAllSessions(token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        await fetchSessionsPaged(path: "/api/v1/sessions", token: token, decoder: decoder, extraQueryItems: [])
    }

    private func fetchSessionsPaged(
        path: String = "/api/v1/sessions",
        token: String,
        decoder: JSONDecoder,
        extraQueryItems: [URLQueryItem]
    ) async -> [SessionRecord] {
        guard var components = URLComponents(string: "\(serverURL)\(path)") else {
            return []
        }

        let pageSize = 1000
        let maxPages = 20
        var skip = 0
        var page = 0
        var all: [SessionRecord] = []
        var seenIDs = Set<String>()

        while page < maxPages {
            components.queryItems = [
                URLQueryItem(name: "skip", value: "\(skip)"),
                URLQueryItem(name: "limit", value: "\(pageSize)")
            ] + extraQueryItems

            guard let url = components.url,
                  let (data, response) = try? await session.data(for: authorisedRequest(url: url, token: token)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                break
            }

            let pageData = decodeSessionPage(data: data, decoder: decoder)
            if pageData.isEmpty { break }

            for record in pageData where !seenIDs.contains(record.id) {
                seenIDs.insert(record.id)
                all.append(record)
            }

            if let decoded = try? decoder.decode(SessionsResponse.self, from: data),
               let pagination = decoded.pagination {
                let fetchedSoFar = pagination.skip + pagination.count
                if fetchedSoFar >= pagination.total {
                    break
                }
                skip = fetchedSoFar
            } else {
                if pageData.count < pageSize {
                    break
                }
                skip += pageData.count
            }

            page += 1
        }

        return all
    }

    private func decodeSessionPage(data: Data, decoder: JSONDecoder) -> [SessionRecord] {
        if let typed = try? decoder.decode(SessionsResponse.self, from: data).data {
            return typed
        }
        if let generic = try? decoder.decode(GenericSessionsResponse.self, from: data) {
            return generic.data.compactMap { makeSessionRecord(from: $0) }
        }
        return []
    }

    private func makeSessionRecord(from object: [String: AnyCodableValue]) -> SessionRecord? {
        guard let id = extractString(from: object, matching: ["id", "sessionid", "uid"]),
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let name = extractString(from: object, matching: ["name", "sessionname"])
        let jobID = extractString(from: object, matching: ["jobid", "jobuid"])
        let sessionType = extractString(from: object, matching: ["sessiontype", "type"])
        let status = extractString(from: object, matching: ["status"])
        let state = extractString(from: object, matching: ["state"])
        let progress = extractProgressPercent(from: object)
        let start = extractDate(from: object, keys: ["creationtime", "starttime"])
        let end = extractDate(from: object, keys: ["endtime", "stoptime"])
        let resultText = extractString(from: object, matching: ["result"])
        let result = resultText.map { SessionResultRecord(result: $0, message: nil) }

        return SessionRecord(
            id: id,
            name: name,
            jobId: jobID,
            sessionType: sessionType,
            creationTime: start,
            endTime: end,
            status: status,
            state: state,
            progressPercent: progress,
            result: result
        )
    }

    private func extractDate(from object: [String: AnyCodableValue], keys: [String]) -> Date? {
        guard let raw = extractString(from: object, matching: keys) else {
            return nil
        }
        return parseAPIDate(raw)
    }

    private func parseAPIDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: value) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let formats = [
            "M/d/yyyy h:mm:ss a",
            "M/d/yyyy h:mm a",
            "M/d/yyyy H:mm:ss",
            "M/d/yyyy H:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private func iso8601UTCString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func runJobAction(
        jobID: String,
        actionPath: String,
        actionName: String,
        ensureStateRefresh: Bool = false
    ) async {
        guard authToken != nil else {
            errorMessage = "Not authenticated"
            return
        }
        guard let url = URL(string: "\(serverURL)/api/v1/jobs/\(jobID)/\(actionPath)") else {
            errorMessage = "Invalid server URL"
            return
        }

        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }

        do {
            let (data, http) = try await performAuthorized { token in
                var request = authorisedRequest(url: url, token: token)
                request.httpMethod = "POST"
                return request
            }

            guard [200, 202, 204].contains(http.statusCode) else {
                let message = extractAPIErrorMessage(from: data) ?? "Could not \(actionName) job."
                errorMessage = "\(message) (HTTP \(http.statusCode))"
                return
            }

            await fetchJobs(reloadBackupInventory: false)
            if ensureStateRefresh {
                await refreshJobsWithFollowUp()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshJobsWithFollowUp() async {
        // Some VBR state transitions are eventually consistent right after enable/disable.
        // Do two short follow-up refreshes so UI status catches up immediately.
        try? await Task.sleep(nanoseconds: 750_000_000)
        await fetchJobs(reloadBackupInventory: false)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await fetchJobs(reloadBackupInventory: false)
    }

    private func runStartActiveFullJob(jobID: String) async {
        guard authToken != nil else {
            errorMessage = "Not authenticated"
            return
        }
        guard let url = URL(string: "\(serverURL)/api/v1/jobs/\(jobID)/start") else {
            errorMessage = "Invalid server URL"
            return
        }

        isPerformingAction = true
        errorMessage = nil
        defer { isPerformingAction = false }

        do {
            let body = try JSONSerialization.data(withJSONObject: ["performActiveFull": true])
            let (data, http) = try await performAuthorized { token in
                var request = authorisedRequest(url: url, token: token)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                return request
            }

            guard [200, 202, 204].contains(http.statusCode) else {
                let message = extractAPIErrorMessage(from: data) ?? "Could not start active full."
                errorMessage = "\(message) (HTTP \(http.statusCode))"
                return
            }

            await fetchJobs(reloadBackupInventory: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func extractAPIErrorMessage(from data: Data) -> String? {
        if let apiError = try? JSONDecoder().decode(VeeamErrorResponse.self, from: data),
           let message = apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }

        return nil
    }

    private func loginRequest(
        url: URL,
        username: String,
        password: String,
        mfaCode: String?,
        mfaToken: String?
    ) async throws -> LoginAttemptResult {
        var attemptedVersions: [String] = []
        var candidateVersions = [apiVersion, Self.fallbackApiVersion]
        var lastResult: LoginAttemptResult?

        while let version = candidateVersions.first {
            candidateVersions.removeFirst()

            if attemptedVersions.contains(version) {
                continue
            }
            attemptedVersions.append(version)

            let request = makeLoginRequest(
                url: url,
                username: username,
                password: password,
                apiVersion: version,
                grantMode: .password,
                mfaCode: mfaCode,
                mfaToken: mfaToken
            )

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            let result = LoginAttemptResult(data: data, response: http, apiVersion: version)
            lastResult = result

            if http.statusCode == 200 {
                return result
            }

            if http.statusCode == 400,
               let negotiatedVersion = bestSupportedVersion(from: data),
               !attemptedVersions.contains(negotiatedVersion) {
                candidateVersions.insert(negotiatedVersion, at: 0)
            }

            // MFA-capable fallback mode using authorization code grant, if a code was entered.
            if mfaCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
               (http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403) {
                let authCodeRequest = makeLoginRequest(
                    url: url,
                    username: username,
                    password: password,
                    apiVersion: version,
                    grantMode: .authorizationCode,
                    mfaCode: mfaCode,
                    mfaToken: mfaToken
                )
                let (authCodeData, authCodeResponse) = try await session.data(for: authCodeRequest)
                if let authCodeHTTP = authCodeResponse as? HTTPURLResponse {
                    let authCodeResult = LoginAttemptResult(data: authCodeData, response: authCodeHTTP, apiVersion: version)
                    lastResult = authCodeResult
                    if authCodeHTTP.statusCode == 200 {
                        return authCodeResult
                    }
                }
            }
        }

        return lastResult ?? LoginAttemptResult(
            data: Data(),
            response: HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!,
            apiVersion: apiVersion
        )
    }

    private func makeLoginRequest(
        url: URL,
        username: String,
        password: String,
        apiVersion: String,
        grantMode: LoginGrantMode,
        mfaCode: String?,
        mfaToken: String?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "x-api-version")
        let safeCode = (mfaCode ?? "").urlFormEncoded
        let safeToken = (mfaToken ?? "").urlFormEncoded

        let grantType: String
        switch grantMode {
        case .password:
            grantType = "password"
        case .authorizationCode:
            grantType = "authorization_code"
        case .vbrToken:
            grantType = "vbr_token"
        case .refreshToken:
            grantType = "refresh_token"
        }

        // For the refresh_token grant the token travels in the refresh_token field and all
        // other credential fields (including vbr_token) stay empty.
        let isRefresh = (grantMode == .refreshToken)
        let safeRefreshToken = isRefresh ? safeToken : ""
        let safeVBRToken = isRefresh ? "" : safeToken

        // TokenLoginSpec supports all fields below; required fields depend on grant_type.
        // We keep a single payload shape and switch grant_type per flow.
        request.httpBody = "grant_type=\(grantType)&username=\(username.urlFormEncoded)&password=\(password.urlFormEncoded)&refresh_token=\(safeRefreshToken)&code=\(safeCode)&use_short_term_refresh=&vbr_token=\(safeVBRToken)".data(using: .utf8)
        return request
    }

    private func fetchJobStates(
        token: String,
        decoder: JSONDecoder,
        onProgress: ((Double) -> Void)? = nil
    ) async -> [JobState]? {
        guard let baseURL = URL(string: "\(serverURL)/api/v1/jobs/states") else {
            errorMessage = "Invalid server URL"; return nil
        }

        var allStates: [JobState] = []
        var skip = 0
        let pageLimit = 500

        do {
            while true {
                var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
                components?.queryItems = [
                    URLQueryItem(name: "skip", value: String(skip)),
                    URLQueryItem(name: "limit", value: String(pageLimit))
                ]

                guard let requestURL = components?.url else {
                    errorMessage = "Invalid request URL"
                    return nil
                }

                let (data, http) = try await performAuthorized { token in
                    authorisedRequest(url: requestURL, token: token)
                }
                guard http.statusCode == 200 else {
                    errorMessage = "Failed to fetch jobs (HTTP \(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "")"; return nil
                }

                let page = try decoder.decode(JobStatesResponse.self, from: data)
                allStates.append(contentsOf: page.data)
                if let total = page.pagination?.total, total > 0 {
                    onProgress?(min(Double(allStates.count) / Double(total), 1.0))
                } else {
                    // Fallback when pagination metadata is absent.
                    onProgress?(min(Double(allStates.count) / Double(pageLimit), 0.95))
                }

                let count = page.pagination?.count ?? page.data.count
                let total = page.pagination?.total ?? allStates.count
                skip += count

                if count == 0 || skip >= total || page.data.isEmpty {
                    break
                }
            }

            return allStates
        } catch {
            errorMessage = error.localizedDescription; return nil
        }
    }

    /// Fetches per-job configuration details because schedule metadata such as job chaining
    /// may not be present in the collection response.
    private func fetchJobConfig(token: String, decoder: JSONDecoder, jobID: String) async -> JobConfig? {
        guard let url = URL(string: "\(serverURL)/api/v1/jobs/\(jobID)") else { return nil }
        guard let (data, response) = try? await session.data(for: authorisedRequest(url: url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let config = try? decoder.decode(JobConfigResponse.self, from: data).data else {
            return nil
        }
        return config
    }

    private func fetchJobConfigs(
        token: String,
        decoder: JSONDecoder,
        jobIDs: [String],
        maxConcurrent: Int? = nil
    ) async -> [JobConfig] {
        guard !jobIDs.isEmpty else { return [] }

        let concurrencyLimit = max(1, min(maxConcurrent ?? Self.jobConfigFetchConcurrency, jobIDs.count))
        var configs: [JobConfig] = []
        configs.reserveCapacity(jobIDs.count)
        var iterator = jobIDs.makeIterator()

        await withTaskGroup(of: JobConfig?.self) { group in
            for _ in 0..<concurrencyLimit {
                guard let jobID = iterator.next() else { break }
                group.addTask {
                    await self.fetchJobConfig(token: token, decoder: decoder, jobID: jobID)
                }
            }

            for await config in group {
                if let config {
                    configs.append(config)
                }
                if let jobID = iterator.next() {
                    group.addTask {
                        await self.fetchJobConfig(token: token, decoder: decoder, jobID: jobID)
                    }
                }
            }
        }

        return configs
    }

    private func fetchBackupRecords(token: String, decoder: JSONDecoder) async -> [BackupRecord]? {
        guard let url = URL(string: "\(serverURL)/api/v1/backups") else {
            return nil
        }

        var allRecords: [BackupRecord] = []
        var skip = 0
        let pageLimit = 500

        while true {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "limit", value: String(pageLimit))
            ]
            guard let pageURL = components?.url,
                  let (data, response) = try? await session.data(for: authorisedRequest(url: pageURL, token: token)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = try? decoder.decode(BackupRecordsResponse.self, from: data) else {
                return allRecords.isEmpty ? nil : allRecords
            }

            allRecords.append(contentsOf: page.data)
            let count = page.pagination?.count ?? page.data.count
            let total = page.pagination?.total ?? allRecords.count
            skip += count

            if count == 0 || skip >= total || page.data.isEmpty {
                break
            }
        }

        return allRecords
    }

    private func fetchBackupObjects(token: String, decoder: JSONDecoder) async -> [BackupObject]? {
        guard let url = URL(string: "\(serverURL)/api/v1/backupObjects") else {
            return nil
        }

        var allObjects: [BackupObject] = []
        var skip = 0
        let pageLimit = 500

        while true {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "limit", value: String(pageLimit))
            ]
            guard let pageURL = components?.url,
                  let (data, response) = try? await session.data(for: authorisedRequest(url: pageURL, token: token)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = try? decoder.decode(BackupObjectsResponse.self, from: data) else {
                return allObjects.isEmpty ? nil : allObjects
            }

            allObjects.append(contentsOf: page.data)
            let count = page.pagination?.count ?? page.data.count
            let total = page.pagination?.total ?? allObjects.count
            skip += count

            if count == 0 || skip >= total || page.data.isEmpty {
                break
            }
        }

        return allObjects
    }

    private func fetchRestorePoints(token: String, decoder: JSONDecoder) async -> [RestorePointRecord]? {
        guard let url = URL(string: "\(serverURL)/api/v1/restorePoints") else {
            return nil
        }

        var allPoints: [RestorePointRecord] = []
        var skip = 0
        let pageLimit = 500

        while true {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "limit", value: String(pageLimit))
            ]
            guard let pageURL = components?.url,
                  let (data, response) = try? await session.data(for: authorisedRequest(url: pageURL, token: token)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = try? decoder.decode(RestorePointsResponse.self, from: data) else {
                return allPoints.isEmpty ? nil : allPoints
            }

            allPoints.append(contentsOf: page.data)
            let count = page.pagination?.count ?? page.data.count
            let total = page.pagination?.total ?? allPoints.count
            skip += count

            if count == 0 || skip >= total || page.data.isEmpty {
                break
            }
        }

        return allPoints
    }

    private func authorisedRequest(url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(apiVersion,         forHTTPHeaderField: "x-api-version")
        return r
    }

    /// Exchanges the stored refresh token for a fresh access token.
    /// Returns true and updates `authToken`/`refreshToken`/`tokenExpiresAt` on success.
    private func refreshAccessToken() async -> Bool {
        guard let refreshToken, !refreshToken.isEmpty,
              let url = URL(string: "\(serverURL)/api/oauth2/token") else {
            return false
        }

        let request = makeLoginRequest(
            url: url,
            username: "",
            password: "",
            apiVersion: apiVersion,
            grantMode: .refreshToken,
            mfaCode: nil,
            mfaToken: refreshToken
        )

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let token = try? JSONDecoder().decode(VeeamTokenResponse.self, from: data) else {
            return false
        }

        applyTokenResponse(token)
        return true
    }

    /// Re-authenticates using stored username/password credentials for the current server.
    /// Returns true when a new access token was obtained.
    private func reloginWithStoredCredentials() async -> Bool {
        guard let saved = loadSavedCredentials(),
              !saved.username.isEmpty else {
            return false
        }
        await login(serverURL: saved.serverURL, username: saved.username, password: saved.password)
        return isAuthenticated
    }

    /// Central authorized-request helper with 401 recovery.
    /// Sends the request with the current token; on 401 it tries a refresh-token exchange,
    /// then a stored-credential re-login, rebuilding and resending the request once each.
    /// If recovery fails the session is marked unauthenticated and an auth error is thrown.
    private func performAuthorized(
        _ makeRequest: (String) -> URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        guard let token = authToken else {
            isAuthenticated = false
            throw NSError(
                domain: "VeeamAPIService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]
            )
        }

        var (data, response) = try await session.data(for: makeRequest(token))
        guard var http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard http.statusCode == 401 else {
            return (data, http)
        }

        // First recovery attempt: refresh-token exchange.
        if await refreshAccessToken(), let newToken = authToken {
            (data, response) = try await session.data(for: makeRequest(newToken))
            if let retried = response as? HTTPURLResponse {
                http = retried
                if http.statusCode != 401 {
                    return (data, http)
                }
            }
        }

        // Second recovery attempt: stored-credential re-login.
        if await reloginWithStoredCredentials(), let newToken = authToken {
            (data, response) = try await session.data(for: makeRequest(newToken))
            if let retried = response as? HTTPURLResponse {
                http = retried
                if http.statusCode != 401 {
                    return (data, http)
                }
            }
        }

        isAuthenticated = false
        throw NSError(
            domain: "VeeamAPIService",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Authentication expired. Please sign in again."]
        )
    }

    private func makeLoginErrorMessage(statusCode: Int, data: Data) -> String {
        let decoder = JSONDecoder()

        if let apiError = try? decoder.decode(VeeamErrorResponse.self, from: data) {
            let rawMessage = apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = apiError.errorCode ?? "UnknownError"

            if code == "AccessDenied" {
                var lines = ["Authentication failed (HTTP \(statusCode), \(code))."]

                if let rawMessage, !rawMessage.isEmpty {
                    lines.append("Server message: \(rawMessage)")
                }

                lines.append("This message is returned by the Veeam server.")
                lines.append("If the account is not actually locked, verify the username format and that this account has access in Veeam Backup & Replication.")
                return lines.joined(separator: "\n")
            }

            if let rawMessage, !rawMessage.isEmpty {
                return "Login failed (HTTP \(statusCode), \(code)): \(rawMessage)"
            }

            return "Login failed (HTTP \(statusCode), \(code))."
        }

        switch statusCode {
        case 400:
            return "Login request was rejected (HTTP 400). Verify server API version compatibility and request format."
        case 401:
            return "Authentication failed (HTTP 401). Check username, password, and domain format (for example DOMAIN\\username)."
        case 403:
            return "Access forbidden (HTTP 403). This account is authenticated but not authorized for this Veeam API."
        case 404:
            return "Login endpoint not found (HTTP 404). Confirm this is a Veeam server and the URL is correct."
        case 408:
            return "Server timed out (HTTP 408). The Veeam server is reachable but not responding in time."
        case 429:
            return "Too many login attempts (HTTP 429). Wait a moment and try again."
        case 500...599:
            return "Veeam server error (HTTP \(statusCode)). Check Veeam services and server health."
        default:
            break
        }

        let rawBody = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawBody, !rawBody.isEmpty {
            return "Login failed (HTTP \(statusCode)): \(rawBody)"
        }

        return "Login failed (HTTP \(statusCode))."
    }

    private func parseMFAChallenge(from data: Data, statusCode: Int) -> MFAChallenge? {
        guard statusCode == 400 || statusCode == 401 || statusCode == 403 else {
            return nil
        }

        var messageCandidates: [String] = []
        var tokenCandidate: String?

        if let apiError = try? JSONDecoder().decode(VeeamErrorResponse.self, from: data) {
            if let errorCode = apiError.errorCode, !errorCode.isEmpty {
                messageCandidates.append(errorCode)
            }
            if let message = apiError.message, !message.isEmpty {
                messageCandidates.append(message)
            }
        }

        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["message", "error_description", "description", "detail"] {
                if let value = raw[key] as? String, !value.isEmpty {
                    messageCandidates.append(value)
                }
            }
            for key in ["vbr_token", "mfa_token", "challenge_token", "token"] {
                if let value = raw[key] as? String, !value.isEmpty {
                    tokenCandidate = value
                    break
                }
            }
        }

        let combined = messageCandidates.joined(separator: " ").lowercased()
        let likelyMFA = combined.contains("mfa")
            || combined.contains("two-factor")
            || combined.contains("two factor")
            || combined.contains("otp")
            || combined.contains("one-time")
            || combined.contains("verification code")
            || combined.contains("vbr_token")

        guard likelyMFA else { return nil }
        let prompt = messageCandidates.last ?? "MFA is required by the server."
        return MFAChallenge(token: tokenCandidate, message: prompt)
    }

    private func makeConnectionErrorMessage(_ error: Error, serverURL: String) -> String {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut:
                return "Connection timed out while contacting \(serverURL). Verify server reachability and port 9419 firewall access."
            case .cannotFindHost, .dnsLookupFailed:
                return "Server host could not be resolved. Verify the Server IP/hostname."
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "Could not establish a network connection to \(serverURL). Check VPN/network path and firewall rules."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateUntrusted, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                return "TLS/SSL handshake failed while connecting to \(serverURL). Verify HTTPS certificate and server time settings."
            case .badURL:
                return "Invalid server URL format. Verify Server IP Address and protocol."
            case .userAuthenticationRequired:
                return "Authentication is required by the server. Verify credentials and API access permissions."
            default:
                break
            }
        }

        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case 61:
                return "Connection refused by \(serverURL). Port 9419 may be closed or Veeam services are not listening."
            case 60:
                return "Connection timed out to \(serverURL). Check routing/firewall/VPN."
            case 65:
                return "No route to host for \(serverURL). Verify network path and gateway/VPN configuration."
            default:
                break
            }
        }

        return "Connection failed: \(nsError.localizedDescription)"
    }

    private func bestSupportedVersion(from data: Data) -> String? {
        guard let message = String(data: data, encoding: .utf8) else { return nil }

        let matches = Self.supportedApiVersions.filter { version in
            message.contains("v\(version)") || message.contains(version)
        }

        return matches.first
    }

    // MARK: - Schedule description

    private func stateScheduleDescription(
        for state: JobState,
        config: JobConfig.Schedule?,
        jobNamesByIdentifier: [String: String]
    ) -> String? {
        if let nextRunPolicy = cleanedNextRunPolicy(state.nextRunPolicy) {
            return nextRunPolicy
        }

        if let afterJobName = state.runAfterJob?.jobName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !afterJobName.isEmpty {
            return "After \(afterJobName)"
        }

        return scheduleDescription(
            from: config,
            isEnabled: state.isEnabled,
            jobNamesByIdentifier: jobNamesByIdentifier
        )
    }

    /// Converts a Veeam schedule config into a short human-readable string,
    /// used as a fallback when the API hasn't yet computed a concrete nextRun date.
    private func scheduleDescription(
        from schedule: JobConfig.Schedule?,
        isEnabled: Bool?,
        jobNamesByIdentifier: [String: String]
    ) -> String? {
        if isEnabled == false {
            return "Disabled"
        }

        guard let schedule else { return "Manual" }

        if let afterThisJob = schedule.afterThisJob,
           afterThisJob.isEnabled == true,
           let jobName = afterThisJob.jobName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !jobName.isEmpty {
            return "After \(jobName)"
        }

        if let daisyChaining = schedule.optionsDaisyChaining, daisyChaining.enabled == true {
            if let previousJobUID = daisyChaining.previousJobUid {
                let normalisedIdentifier = normalisedJobIdentifier(previousJobUID)
                if let jobName = jobNamesByIdentifier[normalisedIdentifier] {
                    return "After \(jobName)"
                }
            }

            return "After Previous Job"
        }

        if let continuous = schedule.continuous, continuous.isEnabled == true {
            return "As New Restore Points Appear"
        }

        if let continuously = schedule.continuously, continuously.isEnabled == true {
            return "As New Restore Points Appear"
        }

        guard schedule.runAutomatically == true else { return "Manual" }

        if let d = schedule.daily, d.isEnabled == true {
            let t = formatScheduleTime(d.time) ?? ""
            switch d.dailyKind?.lowercased() {
            case "workdays": return "Weekdays at \(t)"
            case "weekends": return "Weekends at \(t)"
            default:         return "Daily at \(t)"
            }
        }
        if let w = schedule.weekly, w.isEnabled == true {
            let days = w.dayOfWeek?.prefix(3).joined(separator: ", ") ?? ""
            let t    = formatScheduleTime(w.time) ?? ""
            return days.isEmpty ? "Weekly at \(t)" : "Weekly (\(days)) at \(t)"
        }
        if let m = schedule.monthly, m.isEnabled == true {
            return "Monthly at \(formatScheduleTime(m.time) ?? "")"
        }
        if let p = schedule.periodically, p.isEnabled == true {
            let freq = p.frequency ?? 1
            let unit = p.frequencyTimeUnit?.lowercased() ?? "hours"
            return "Every \(freq) \(unit)"
        }

        return "Not Scheduled"
    }

    private func cleanedNextRunPolicy(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        if value.hasPrefix("After ["), value.hasSuffix("]"), value.count > 8 {
            value = "After " + String(value.dropFirst("After [".count).dropLast())
        }

        if value.lowercased() == "disabled" {
            return "Disabled"
        }

        return value
    }

    private func backupInventory(
        for state: JobState,
        config: JobConfig?,
        backupRecords: [BackupRecord],
        backupObjects: [BackupObject],
        restorePoints: [RestorePointRecord],
        backupPointMetadataByRestorePointID: [String: BackupPointMetadata]
    ) -> (vmStorageSize: String?, driveSummary: String?, backupPoints: [VeeamBackupPoint]) {
        let jobID = normalisedJobIdentifier(state.id)
        let backupIDs = Set(
            backupRecords
                .filter { normalisedJobIdentifier($0.jobId ?? "") == jobID }
                .map(\.id)
        )
        let objectNames = candidateObjectNames(for: state, config: config)
        let objectPlatformIDs = Set(
            backupObjects
                .filter { objectNames.contains(canonicalObjectName($0.name)) }
                .map(\.id)
        )
        let isCopyJob = (state.type ?? "").lowercased().contains("copy")

        let filteredRestorePoints = restorePoints
            .filter { backupIDs.contains($0.backupId) }
            .filter { point in
                if isCopyJob {
                    return true
                }
                let canonicalPointName = canonicalObjectName(point.name)
                return objectNames.contains(canonicalPointName) || objectPlatformIDs.contains(point.platformId ?? "")
            }
            .sorted { $0.creationTime > $1.creationTime }

        let repositoryNameByBackupID = backupRecords.reduce(into: [String: String]()) { partial, record in
            if let repositoryName = record.repositoryName {
                partial[record.id] = repositoryName
            }
        }

        let backupPoints = buildBackupPoints(
            from: filteredRestorePoints,
            gfsPolicy: config?.storage?.gfsPolicy,
            backupPointMetadataByRestorePointID: backupPointMetadataByRestorePointID,
            repositoryNameByBackupID: repositoryNameByBackupID
        )

        return (
            vmStorageSize: config?.virtualMachines?.includes.first?.size ?? fallbackVMStorageSize(from: filteredRestorePoints),
            driveSummary: driveSummary(from: config?.virtualMachines),
            backupPoints: backupPoints
        )
    }

    private func candidateObjectNames(for state: JobState, config: JobConfig?) -> Set<String> {
        var names: Set<String> = [canonicalObjectName(state.name)]
        config?.virtualMachines?.includes.forEach { included in
            if let name = included.name {
                names.insert(canonicalObjectName(name))
            }
        }
        return names
    }

    private func canonicalObjectName(_ value: String) -> String {
        value
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? value.lowercased()
    }

    private func driveSummary(from virtualMachines: JobConfig.VirtualMachines?) -> String? {
        guard let diskSelection = virtualMachines?.excludes?.disks?.first else { return nil }

        if diskSelection.disksToProcess?.lowercased() == "alldisks" {
            return "All Drives"
        }

        let count = diskSelection.disks?.count ?? 0
        guard count > 0 else { return nil }
        return count == 1 ? "1 Drive" : "\(count) Drives"
    }

    private func fallbackVMStorageSize(from restorePoints: [RestorePointRecord]) -> String? {
        var latestByObject: [String: RestorePointRecord] = [:]

        for point in restorePoints {
            guard let originalSize = point.originalSize, originalSize > 0 else { continue }
            let objectKey = (point.platformId?.isEmpty == false) ? point.platformId! : canonicalObjectName(point.name)
            if let existing = latestByObject[objectKey] {
                if point.creationTime > existing.creationTime {
                    latestByObject[objectKey] = point
                }
            } else {
                latestByObject[objectKey] = point
            }
        }

        let totalBytes = latestByObject.values.reduce(Int64(0)) { partial, point in
            partial + (point.originalSize ?? 0)
        }

        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private func buildBackupPoints(
        from restorePoints: [RestorePointRecord],
        gfsPolicy: JobConfig.Storage.GFSPolicy?,
        backupPointMetadataByRestorePointID: [String: BackupPointMetadata],
        repositoryNameByBackupID: [String: String]
    ) -> [VeeamBackupPoint] {
        let fullRestorePoints = restorePoints
            .filter { $0.type.lowercased() == "full" }
            .sorted { $0.creationTime < $1.creationTime }

        return restorePoints.map { point in
            // For backup copy jobs, backupFiles metadata may not provide per-point sizes.
            // Fall back to the restore point's originalSize (source VM size) when available.
            let backupSize = backupPointMetadataByRestorePointID[point.id]?.backupSizeBytes 
                ?? point.originalSize
            
            return VeeamBackupPoint(
                id: point.id,
                name: point.name,
                creationTime: point.creationTime,
                type: point.type,
                status: backupPointStatus(for: point),
                gfsFlags: gfsFlags(
                    for: point,
                    fullRestorePoints: fullRestorePoints,
                    gfsPolicy: gfsPolicy,
                    backupPointMetadataByRestorePointID: backupPointMetadataByRestorePointID
                ),
                expirationDate: point.expirationDate ?? backupPointMetadataByRestorePointID[point.id]?.immutableUntil,
                backupSizeBytes: backupSize,
                repositoryName: repositoryNameByBackupID[point.backupId],
                backupSetName: backupPointMetadataByRestorePointID[point.id]?.backupSetName
            )
        }
    }

    private func backupPointStatus(for point: RestorePointRecord) -> String {
        point.malwareStatus == "Clean" ? "OK" : (point.malwareStatus ?? "Unknown")
    }

    private func gfsFlags(
        for point: RestorePointRecord,
        fullRestorePoints: [RestorePointRecord],
        gfsPolicy: JobConfig.Storage.GFSPolicy?,
        backupPointMetadataByRestorePointID: [String: BackupPointMetadata]
    ) -> [String] {
        let fileFlags = backupPointMetadataByRestorePointID[point.id]?.gfsFlags ?? []
        let inferredFlags = inferredGFSFlags(
            for: point,
            fullRestorePoints: fullRestorePoints,
            gfsPolicy: gfsPolicy
        )
        let merged = Array(Set(fileFlags + inferredFlags)).sorted()
        return merged
    }

    private func inferredGFSFlags(
        for point: RestorePointRecord,
        fullRestorePoints: [RestorePointRecord],
        gfsPolicy: JobConfig.Storage.GFSPolicy?
    ) -> [String] {
        guard point.type.lowercased() == "full" else { return [] }

        var flags: [String] = []
        let calendar = Calendar.current

        if gfsPolicy?.weekly?.isEnabled == true,
           isRetainedWeeklyFull(point, among: fullRestorePoints, calendar: calendar) {
            flags.append("W")
        }

        if gfsPolicy?.monthly?.isEnabled == true,
           isRetainedMonthlyFull(
            point,
            among: fullRestorePoints,
            desiredTime: gfsPolicy?.monthly?.desiredTime,
            calendar: calendar
           ) {
            flags.append("M")
        }

        if gfsPolicy?.yearly?.isEnabled == true,
           let desiredMonth = gfsPolicy?.yearly?.desiredTime?.lowercased(),
           monthName(for: point.creationTime) == desiredMonth,
           isRetainedYearlyFull(
            point,
            among: fullRestorePoints,
            desiredTime: gfsPolicy?.yearly?.desiredTime,
            calendar: calendar
           ) {
            flags.append("Y")
        }

        return flags
    }

    private func fetchBackupPointMetadataByRestorePointID(
        token: String,
        decoder: JSONDecoder,
        backupIDs: Set<String>,
        maxConcurrent: Int? = nil
    ) async -> [String: BackupPointMetadata] {
        let backupIDList = Array(backupIDs)
        guard !backupIDList.isEmpty else { return [:] }

        let concurrencyLimit = max(1, min(maxConcurrent ?? Self.backupMetadataFetchConcurrency, backupIDList.count))
        var result: [String: BackupPointMetadata] = [:]
        var iterator = backupIDList.makeIterator()

        await withTaskGroup(of: [String: BackupPointMetadata].self) { group in
            for _ in 0..<concurrencyLimit {
                guard let backupID = iterator.next() else { break }
                group.addTask {
                    await self.fetchBackupPointMetadata(
                        for: backupID,
                        token: token,
                        decoder: decoder
                    )
                }
            }

            for await partial in group {
                mergeBackupPointMetadata(into: &result, from: partial)
                if let backupID = iterator.next() {
                    group.addTask {
                        await self.fetchBackupPointMetadata(
                            for: backupID,
                            token: token,
                            decoder: decoder
                        )
                    }
                }
            }
        }

        return result
    }

    private func fetchBackupPointMetadata(
        for backupID: String,
        token: String,
        decoder: JSONDecoder
    ) async -> [String: BackupPointMetadata] {
        var result: [String: BackupPointMetadata] = [:]
        guard let baseURL = URL(string: "\(serverURL)/api/v1/backups/\(backupID)/backupFiles") else {
            return result
        }

        var skip = 0
        let pageLimit = 500

        while true {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "skip", value: String(skip)),
                URLQueryItem(name: "limit", value: String(pageLimit))
            ]

            guard let pageURL = components?.url,
                  let (data, response) = try? await session.data(for: authorisedRequest(url: pageURL, token: token)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let page = try? decoder.decode(BackupFilesResponse.self, from: data) else {
                break
            }

            let genericPage = try? decoder.decode(GenericBackupFilesPage.self, from: data)
            var immutableByRestorePointID: [String: Date] = [:]
            if let genericFiles = genericPage?.data {
                for file in genericFiles {
                    let restorePointIDs = extractRestorePointIDs(from: file)
                    guard !restorePointIDs.isEmpty else { continue }
                    if let immutableDate = extractImmutabilityDate(from: file) {
                        for restorePointID in restorePointIDs {
                            immutableByRestorePointID[restorePointID] = immutableDate
                        }
                    }
                }
            }

            let vbmCandidates = page.data
                .filter { isVbmFile($0.name) }
                .sorted { ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast) }

            for file in page.data {
                ingestBackupFileMetadata(
                    file,
                    vbmCandidates: vbmCandidates,
                    immutableByRestorePointID: immutableByRestorePointID,
                    into: &result
                )
            }

            let count = page.pagination?.count ?? page.data.count
            let total = page.pagination?.total ?? page.data.count
            skip += count
            if count == 0 || skip >= total || page.data.isEmpty {
                break
            }
        }

        return result
    }

    private func ingestBackupFileMetadata(
        _ file: BackupFileRecord,
        vbmCandidates: [BackupFileRecord],
        immutableByRestorePointID: [String: Date],
        into result: inout [String: BackupPointMetadata]
    ) {
        let flags = compactGFSFlags(from: file.gfsPeriods ?? [])
        let resolvedSet = resolveBackupSet(for: file, using: vbmCandidates)
        let restorePointIDs = file.restorePointIds ?? []
        let isMultiPointFile = restorePointIDs.count > 1

        for restorePointID in restorePointIDs {
            var metadata = result[restorePointID] ?? BackupPointMetadata(
                gfsFlags: [],
                immutableUntil: nil,
                backupSizeBytes: nil,
                backupSetName: nil,
                backupSetCreatedAt: nil
            )
            metadata.gfsFlags = Array(Set(metadata.gfsFlags + flags)).sorted()
            if let resolvedSet {
                if let existing = metadata.backupSetCreatedAt {
                    if let candidateDate = resolvedSet.createdAt, candidateDate > existing {
                        metadata.backupSetName = resolvedSet.name
                        metadata.backupSetCreatedAt = candidateDate
                    }
                } else {
                    metadata.backupSetName = resolvedSet.name
                    metadata.backupSetCreatedAt = resolvedSet.createdAt
                }
            } else if metadata.backupSetName == nil {
                metadata.backupSetName = inferBackupSetName(from: file.name, backupID: file.backupId)
            }

            if let backupSize = file.backupSize {
                if metadata.backupSizeBytes == nil {
                    metadata.backupSizeBytes = backupSize
                } else if !isMultiPointFile {
                    metadata.backupSizeBytes = max(metadata.backupSizeBytes!, backupSize)
                }
            }

            let resolvedImmutableUntil = file.immutableUntil ?? immutableByRestorePointID[restorePointID]
            if let immutableUntil = resolvedImmutableUntil {
                if let current = metadata.immutableUntil {
                    if immutableUntil > current {
                        metadata.immutableUntil = immutableUntil
                    }
                } else {
                    metadata.immutableUntil = immutableUntil
                }
            }
            result[restorePointID] = metadata
        }
    }

    private func mergeBackupPointMetadata(
        into target: inout [String: BackupPointMetadata],
        from source: [String: BackupPointMetadata]
    ) {
        for (restorePointID, incoming) in source {
            if var existing = target[restorePointID] {
                existing.gfsFlags = Array(Set(existing.gfsFlags + incoming.gfsFlags)).sorted()
                if let incomingName = incoming.backupSetName {
                    if let existingDate = existing.backupSetCreatedAt,
                       let incomingDate = incoming.backupSetCreatedAt,
                       incomingDate > existingDate {
                        existing.backupSetName = incomingName
                        existing.backupSetCreatedAt = incomingDate
                    } else if existing.backupSetName == nil {
                        existing.backupSetName = incomingName
                        existing.backupSetCreatedAt = incoming.backupSetCreatedAt
                    }
                }
                if let incomingSize = incoming.backupSizeBytes {
                    if existing.backupSizeBytes == nil {
                        existing.backupSizeBytes = incomingSize
                    } else {
                        existing.backupSizeBytes = max(existing.backupSizeBytes!, incomingSize)
                    }
                }
                if let incomingImmutable = incoming.immutableUntil {
                    if let current = existing.immutableUntil {
                        if incomingImmutable > current {
                            existing.immutableUntil = incomingImmutable
                        }
                    } else {
                        existing.immutableUntil = incomingImmutable
                    }
                }
                target[restorePointID] = existing
            } else {
                target[restorePointID] = incoming
            }
        }
    }

    private func isVbmFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".vbm")
    }

    private func resolveBackupSet(
        for file: BackupFileRecord,
        using vbmCandidates: [BackupFileRecord]
    ) -> (name: String, createdAt: Date?)? {
        if isVbmFile(file.name) {
            return (normalizedBackupSetName(from: file.name, backupID: file.backupId), file.creationTime)
        }

        let sameObject = vbmCandidates.filter { candidate in
            guard let fileObject = file.objectId, !fileObject.isEmpty else { return true }
            return candidate.objectId == fileObject
        }

        let candidates = sameObject.isEmpty ? vbmCandidates : sameObject
        guard !candidates.isEmpty else { return nil }

        if let fileTime = file.creationTime {
            let priorOrEqual = candidates.filter { ($0.creationTime ?? .distantPast) <= fileTime }
            if let nearest = priorOrEqual.max(by: { ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast) }) {
                return (normalizedBackupSetName(from: nearest.name, backupID: nearest.backupId), nearest.creationTime)
            }
        }

        let newest = candidates.max(by: { ($0.creationTime ?? .distantPast) < ($1.creationTime ?? .distantPast) }) ?? candidates[0]
        return (normalizedBackupSetName(from: newest.name, backupID: newest.backupId), newest.creationTime)
    }

    private func displayName(forBackupSetPath raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        if let last = normalized.split(separator: "/").last {
            return String(last)
        }
        return raw
    }

    private func inferBackupSetName(from backupFileName: String, backupID: String) -> String {
        let fileName = displayName(forBackupSetPath: backupFileName).trimmingCharacters(in: .whitespacesAndNewlines)
        if fileName.isEmpty {
            return "BackupSet-\(backupID.prefix(8)).VBM"
        }

        let extTrimmed = fileName.replacingOccurrences(of: "\\.[A-Za-z0-9]+$", with: "", options: .regularExpression)

        // Example:
        //   VMName...vm-34D2026-05-20T200019_5818.vib
        // -> VMName...vm-34.vbm
        if let vmChainRange = extTrimmed.range(
            of: "^(.*?\\.vm-[0-9]+)D[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6,}_[A-Fa-f0-9]+$",
            options: .regularExpression
        ) {
            let base = String(extTrimmed[vmChainRange]).replacingOccurrences(
                of: "D[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6,}_[A-Fa-f0-9]+$",
                with: "",
                options: .regularExpression
            )
            return "\(base).vbm"
        }

        // Generic Veeam timestamp suffix collapse:
        //   NameD2026-05-20T200019_5818 -> Name
        let collapsed = extTrimmed.replacingOccurrences(
            of: "D[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6,}_[A-Fa-f0-9]+$",
            with: "",
            options: .regularExpression
        )

        if !collapsed.isEmpty, collapsed != extTrimmed {
            return "\(collapsed).vbm"
        }

        return "\(extTrimmed).vbm"
    }

    private func normalizedBackupSetName(from backupFileName: String, backupID: String) -> String {
        inferBackupSetName(from: backupFileName, backupID: backupID)
    }

    private func extractRestorePointIDs(from object: [String: AnyCodableValue]) -> [String] {
        for (key, value) in object {
            if key.lowercased() == "restorepointids", case .array(let entries) = value {
                return entries.compactMap { entry in
                    if case .string(let id) = entry {
                        return id
                    }
                    return nil
                }
            }
        }
        return []
    }

    private func extractImmutabilityDate(from object: [String: AnyCodableValue]) -> Date? {
        for (key, value) in object {
            let lower = key.lowercased()
            if lower.contains("immut") || lower.contains("lockuntil") || lower.contains("retentionuntil") {
                if let date = parseAnyValueDate(value) {
                    return date
                }
            }

            if case .object(let nested) = value, let nestedDate = extractImmutabilityDate(from: nested) {
                return nestedDate
            }
        }
        return nil
    }

    private func parseAnyValueDate(_ value: AnyCodableValue) -> Date? {
        switch value {
        case .string(let text):
            return parseFlexibleDate(text)
        case .int(let seconds):
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        case .double(let seconds):
            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private func parseFlexibleDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: value) { return date }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        let formats = [
            "M/d/yyyy h:mm:ss a",
            "M/d/yyyy h:mm a",
            "M/d/yyyy",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private func compactGFSFlags(from periods: [String]) -> [String] {
        var flags: [String] = []
        for period in periods {
            switch period.lowercased() {
            case "weekly":
                flags.append("W")
            case "monthly":
                flags.append("M")
            case "quarterly":
                flags.append("Q")
            case "yearly":
                flags.append("Y")
            default:
                continue
            }
        }

        return Array(Set(flags)).sorted()
    }

    private func isRetainedWeeklyFull(
        _ point: RestorePointRecord,
        among fullRestorePoints: [RestorePointRecord],
        calendar: Calendar
    ) -> Bool {
        let targetWeek = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: point.creationTime)
        let weekPoints = fullRestorePoints.filter {
            calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0.creationTime) == targetWeek
        }

        guard let lastPoint = weekPoints.max(by: { $0.creationTime < $1.creationTime }) else {
            return false
        }

        return lastPoint.id == point.id
    }

    private func monthName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date).lowercased()
    }

    private func isRetainedMonthlyFull(
        _ point: RestorePointRecord,
        among fullRestorePoints: [RestorePointRecord],
        desiredTime: String?,
        calendar: Calendar
    ) -> Bool {
        let targetComponents = calendar.dateComponents([.year, .month], from: point.creationTime)
        let monthPoints = fullRestorePoints.filter {
            calendar.dateComponents([.year, .month], from: $0.creationTime) == targetComponents
        }
        guard let retainedPoint = retainedPoint(for: monthPoints, desiredTime: desiredTime) else {
            return false
        }

        return retainedPoint.id == point.id
    }

    private func isRetainedYearlyFull(
        _ point: RestorePointRecord,
        among fullRestorePoints: [RestorePointRecord],
        desiredTime: String?,
        calendar: Calendar
    ) -> Bool {
        let targetYear = calendar.component(.year, from: point.creationTime)
        let yearPoints = fullRestorePoints.filter {
            calendar.component(.year, from: $0.creationTime) == targetYear
        }
        guard let retainedPoint = retainedPoint(for: yearPoints, desiredTime: desiredTime) else {
            return false
        }

        return retainedPoint.id == point.id
    }

    private func retainedPoint(
        for points: [RestorePointRecord],
        desiredTime: String?
    ) -> RestorePointRecord? {
        guard !points.isEmpty else { return nil }

        switch desiredTime?.lowercased() {
        case "last":
            return points.max(by: { $0.creationTime < $1.creationTime })
        default:
            return points.min(by: { $0.creationTime < $1.creationTime })
        }
    }

    /// Parses a Veeam time string like "22:00:00" into "10:00 PM".
    private func formatScheduleTime(_ timeStr: String?) -> String? {
        guard let timeStr else { return nil }
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return timeStr }
        let h = parts[0], m = parts[1]
        let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", displayH, m, h >= 12 ? "PM" : "AM")
    }

    private func normalisedJobIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "urn:veeam:Job:", with: "")
            .replacingOccurrences(of: "urn:uuid:", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .lowercased()
    }

    // MARK: - Date decoder

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let str = try container.decode(String.self)
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised date: \(str)"
                )
            }
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fmt.date(from: trimmed) { return d }
            fmt.formatOptions = [.withInternetDateTime]
            if let d = fmt.date(from: trimmed) { return d }

            let fallbackFormats = [
                "M/d/yyyy h:mm:ss a",
                "M/d/yyyy h:mm a",
                "M/d/yyyy H:mm:ss",
                "M/d/yyyy H:mm"
            ]
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.timeZone = TimeZone.current
            for format in fallbackFormats {
                fallback.dateFormat = format
                if let date = fallback.date(from: trimmed) {
                    return date
                }
            }

            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unrecognised date: \(str)")
        }
        return decoder
    }

    // MARK: - Keychain

    func loadSavedCredentials() -> SavedCredentials? {
        if let mostRecentURL = savedConnectionURLs().first,
           let saved = loadSavedCredentials(for: mostRecentURL) {
            return saved
        }

        return loadLegacyCredentials()
    }

    func loadSavedCredentials(for serverURL: String) -> SavedCredentials? {
        let normalizedURL = normalisedServerURL(serverURL)

        guard let encoded = keychainRead(key: connectionKey(for: normalizedURL)),
              let data = encoded.data(using: .utf8),
              let stored = try? JSONDecoder().decode(StoredConnection.self, from: data) else {
            return nil
        }

        return SavedCredentials(
            serverURL: stored.serverURL,
            username: stored.username,
            password: stored.password,
            friendlyName: stored.friendlyName
        )
    }

    func savedConnectionEntries() -> [SavedConnectionEntry] {
        savedConnectionURLs().compactMap { url in
            guard let saved = loadSavedCredentials(for: url) else { return nil }
            let fallbackName = URL(string: saved.serverURL)?.host ?? saved.serverURL
            let displayName = saved.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedConnectionEntry(
                serverURL: saved.serverURL,
                friendlyName: ((displayName?.isEmpty == false) ? displayName! : fallbackName).uppercased()
            )
        }
    }

    func deleteSavedConnection(serverURL: String) {
        let normalizedURL = normalisedServerURL(serverURL)
        keychainDelete(key: connectionKey(for: normalizedURL))
        let updated = savedConnectionURLs().filter { normalisedServerURL($0) != normalizedURL }
        UserDefaults.standard.set(updated, forKey: Self.defaultsConnectionHistoryKey)
    }

    func savedConnectionURLs() -> [String] {
        guard let urls = UserDefaults.standard.array(forKey: Self.defaultsConnectionHistoryKey) as? [String] else {
            return []
        }

        return urls
    }

    private func saveCredentials(serverURL: String, username: String, password: String, friendlyName: String? = nil) {
        let normalizedURL = normalisedServerURL(serverURL)
        let normalizedFriendly = friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingFriendly = loadSavedCredentials(for: normalizedURL)?.friendlyName
        let resolvedFriendly = ((normalizedFriendly?.isEmpty == false) ? normalizedFriendly : existingFriendly)?.uppercased()
        let stored = StoredConnection(
            serverURL: normalizedURL,
            username: username,
            password: password,
            friendlyName: (resolvedFriendly?.isEmpty == false) ? resolvedFriendly : nil
        )

        guard let data = try? JSONEncoder().encode(stored),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }

        keychainWrite(key: connectionKey(for: normalizedURL), value: payload)
        saveConnectionHistoryEntry(normalizedURL)
        deleteLegacyCredentials()
    }

    private func saveConnectionHistoryEntry(_ serverURL: String) {
        var urls = savedConnectionURLs().filter { $0 != serverURL }
        urls.insert(serverURL, at: 0)
        UserDefaults.standard.set(urls, forKey: Self.defaultsConnectionHistoryKey)
    }

    private func loadLegacyCredentials() -> SavedCredentials? {
        guard let serverURL = keychainRead(key: "serverURL"),
              let username = keychainRead(key: "username"),
              let password = keychainRead(key: "password") else {
            return nil
        }

        let saved = SavedCredentials(serverURL: serverURL, username: username, password: password, friendlyName: nil)
        saveCredentials(serverURL: serverURL, username: username, password: password, friendlyName: nil)
        return saved
    }

    private func deleteLegacyCredentials() {
        keychainDelete(key: "serverURL")
        keychainDelete(key: "username")
        keychainDelete(key: "password")
    }

    private func connectionKey(for serverURL: String) -> String {
        "\(Self.keychainConnectionPrefix)\(serverURL)"
    }

    func normalisedServerURL(_ serverURL: String) -> String {
        var value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.lowercased().hasPrefix("http://") && !value.lowercased().hasPrefix("https://") {
            value = "https://\(value)"
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func keychainWrite(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    private func keychainRead(key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
    }
}
