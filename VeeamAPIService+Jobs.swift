import Foundation
import Combine
import Security
#if canImport(AppKit)
import AppKit
#endif

extension VeeamAPIService {
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

    func scheduleBackgroundJobConfigLoad(for states: [JobState]) {
        jobConfigBackgroundTask?.cancel()
        jobConfigBackgroundTask = Task {
            await loadMissingJobConfigs(for: states)
        }
    }

    func loadMissingJobConfigs(for states: [JobState]) async {
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

    func applyAllCachedConfigsToJobs() {
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

    func clearJobFetchCache() {
        jobFetchCache = JobFetchCache()
        clearLogSummaryCache()
    }

    func clearLogSummaryCache() {
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

    func storeLatestLogSummaryCache(jobID: String, summary: JobRunLogSummary?) {
        fetchedLatestLogSummaryJobIDs.insert(jobID)
        if let summary {
            latestLogSummaryByJobID[jobID] = summary
        } else {
            latestLogSummaryByJobID.removeValue(forKey: jobID)
        }
    }

    func contextualLogSummaryCacheKey(jobID: String, referenceDate: Date) -> String {
        "\(jobID)|\(Int(referenceDate.timeIntervalSince1970))"
    }

    func ensureAllSessionsCached(token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        if let cachedAllSessions {
            return cachedAllSessions
        }
        let sessions = await fetchAllSessions(token: token, decoder: decoder)
        cachedAllSessions = sessions
        return sessions
    }

    func applyJobConfig(to state: JobState, config: JobConfig?) {
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
    func replaceJob(at index: Int, with job: VeeamJob) {
        var updated = jobs
        updated[index] = job
        jobs = updated
    }

    /// Prefers per-job config description when present; otherwise uses `/jobs/states` description.
    func resolvedJobDescription(config: JobConfig?, state: JobState) -> String? {
        let candidates = [config?.description, state.description]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func buildVeeamJob(
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
            if let status = state.status, VeeamJob.isActiveJobStatus(status) {
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
            jobDescription: resolvedJobDescription(config: config, state: state),
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

    func parseProcessingRateBytesPerSecond(_ text: String?) -> Double? {
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

    struct SessionProgressFetchTarget {
        let normalizedJobID: String
        let sessionID: String
    }

    func fetchSessionProgressForRunningJobs(
        states: [JobState],
        token: String,
        decoder: JSONDecoder
    ) async -> [String: Int] {
        let activeProgress = await fetchActiveSessionProgressLookup(states: states, token: token, decoder: decoder)
        var result: [String: Int] = [:]

        var sessionTargets: [SessionProgressFetchTarget] = []
        var fallbackStates: [JobState] = []

        for state in states {
            guard state.status?.lowercased() == "running" else { continue }
            let directProgress = max(state.progressPercent ?? 0, state.sessionProgress?.progressPercent ?? 0)
            if directProgress > 0 {
                continue
            }

            let normalizedJobID = normalisedJobIdentifier(state.id)
            if let sessionID = state.sessionId, !sessionID.isEmpty {
                sessionTargets.append(SessionProgressFetchTarget(normalizedJobID: normalizedJobID, sessionID: sessionID))
            } else {
                fallbackStates.append(state)
            }
        }

        if !sessionTargets.isEmpty {
            let fetched = await fetchSessionProgressPercents(
                targets: sessionTargets,
                token: token,
                decoder: decoder,
                maxConcurrent: Self.jobRunLogFetchConcurrency
            )
            for (jobID, progress) in fetched {
                result[jobID] = progress
            }
        }

        func applyActiveProgressFallback(for normalizedJobID: String, jobName: String) {
            guard result[normalizedJobID] == nil else { return }
            if let progress = activeProgress.byJobID[normalizedJobID] {
                result[normalizedJobID] = progress
                return
            }
            let normalizedJobName = normalizedJobNameKey(jobName)
            if let progress = activeProgress.byJobName[normalizedJobName] {
                result[normalizedJobID] = progress
            }
        }

        for state in fallbackStates {
            applyActiveProgressFallback(for: normalisedJobIdentifier(state.id), jobName: state.name)
        }

        for target in sessionTargets {
            guard result[target.normalizedJobID] == nil,
                  let state = states.first(where: { normalisedJobIdentifier($0.id) == target.normalizedJobID }) else {
                continue
            }
            applyActiveProgressFallback(for: target.normalizedJobID, jobName: state.name)
        }

        return result
    }

    func fetchSessionProgressPercents(
        targets: [SessionProgressFetchTarget],
        token: String,
        decoder: JSONDecoder,
        maxConcurrent: Int
    ) async -> [String: Int] {
        guard !targets.isEmpty else { return [:] }

        var result: [String: Int] = [:]
        var iterator = targets.makeIterator()

        await withTaskGroup(of: (String, Int)?.self) { group in
            func enqueueNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    guard let progress = await self.fetchSessionProgressPercent(
                        sessionID: target.sessionID,
                        token: token,
                        decoder: decoder
                    ) else {
                        return nil
                    }
                    return (target.normalizedJobID, progress)
                }
            }

            for _ in 0..<min(maxConcurrent, targets.count) {
                enqueueNext()
            }

            for await pair in group {
                if let (jobID, progress) = pair {
                    result[jobID] = progress
                }
                enqueueNext()
            }
        }

        return result
    }

    func fetchSessionProgressPercent(
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

    func fetchActiveSessionProgressLookup(
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

    func fetchActiveSessionProgressLookup(
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

    func normalizedJobNameKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    func inferJobNameFromSessionName(_ raw: String) -> String? {
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

    func extractProgressPercent(from object: [String: AnyCodableValue]) -> Int? {
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

    func extractPercentFromText(_ text: String) -> Int? {
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

    func extractString(from object: [String: AnyCodableValue], matching keys: [String]) -> String? {
        let lowered = Set(keys.map { $0.lowercased() })
        for (k, v) in object {
            if lowered.contains(k.lowercased()), case .string(let s) = v {
                return s
            }
        }
        return nil
    }

    func validatedNextRun(lastRun: Date?, nextRun: Date?) -> Date? {
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

    func resolveLatestJobRunLogSummaryUncached(for job: VeeamJob) async -> JobRunLogSummary? {
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

    func resolveLatestJobRunLogSummary(
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

    func storeContextualLogSummaryCache(key: String, summary: JobRunLogSummary?) {
        fetchedContextualLogSummaryKeys.insert(key)
        if let summary {
            contextualLogSummaryByKey[key] = summary
        } else {
            contextualLogSummaryByKey.removeValue(forKey: key)
        }
    }

    func sessionMatchScore(summary: JobRunLogSummary, referenceDate: Date, isCopyJob: Bool) -> Int {
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

    func isSameLocalDay(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    var copySessionDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }

    var copySessionDateFormatterTwoDigitYear: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }

    var copySessionTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm"
        return formatter
    }

    func fetchJobRunLogSummary(
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

}
