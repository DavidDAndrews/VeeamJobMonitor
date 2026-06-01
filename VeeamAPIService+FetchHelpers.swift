import Foundation
import Combine
import Security
#if canImport(AppKit)
import AppKit
#endif

extension VeeamAPIService {
    // MARK: - Private fetch helpers

    func fetchLatestSession(for job: VeeamJob, token: String, decoder: JSONDecoder) async -> SessionRecord? {
        let matching = await fetchMatchingSessions(for: job, token: token, decoder: decoder)
        return selectLatestSession(for: job, from: matching)
    }

    func selectLatestSession(for job: VeeamJob, from matching: [SessionRecord]) -> SessionRecord? {
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

    func newestSession(in sessions: [SessionRecord]) -> SessionRecord? {
        sessions.max { lhs, rhs in
            let lhsDate = lhs.endTime ?? lhs.creationTime ?? .distantPast
            let rhsDate = rhs.endTime ?? rhs.creationTime ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    func isActiveSession(state: String?, result: String?) -> Bool {
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

    func fetchMatchingSessions(for job: VeeamJob, token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        let sessions = await ensureAllSessionsCached(token: token, decoder: decoder)
        return matchingSessions(for: job, in: sessions)
    }

    func matchingSessions(for job: VeeamJob, in sessions: [SessionRecord]) -> [SessionRecord] {
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

    func isBackupCopyJob(_ job: VeeamJob) -> Bool {
        let typeText = (job.type ?? "").lowercased()
        let jobTypeText = job.jobType.lowercased()
        let nameText = job.name.lowercased()
        return typeText.contains("copy")
            || jobTypeText.contains("copy")
            || nameText.contains("-bcj")
    }

    func fetchAllSessions(token: String, decoder: JSONDecoder) async -> [SessionRecord] {
        await fetchSessionsPaged(path: "/api/v1/sessions", token: token, decoder: decoder, extraQueryItems: [])
    }

    func fetchSessionsPaged(
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

    func decodeSessionPage(data: Data, decoder: JSONDecoder) -> [SessionRecord] {
        if let typed = try? decoder.decode(SessionsResponse.self, from: data).data {
            return typed
        }
        if let generic = try? decoder.decode(GenericSessionsResponse.self, from: data) {
            return generic.data.compactMap { makeSessionRecord(from: $0) }
        }
        return []
    }

    func makeSessionRecord(from object: [String: AnyCodableValue]) -> SessionRecord? {
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

    func extractDate(from object: [String: AnyCodableValue], keys: [String]) -> Date? {
        guard let raw = extractString(from: object, matching: keys) else {
            return nil
        }
        return parseAPIDate(raw)
    }

    func parseAPIDate(_ raw: String) -> Date? {
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

    func iso8601UTCString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    func runJobAction(
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

            guard isSuccessfulJobAction(http.statusCode, actionPath: actionPath) else {
                let message = extractAPIErrorMessage(from: data) ?? "Could not \(actionName) job."
                if isJobAlreadyActiveOnServerError(message, statusCode: http.statusCode) {
                    await refreshJobsAfterJobAlreadyActive()
                    return
                }
                errorMessage = formatJobActionErrorMessage(message, actionName: actionName, statusCode: http.statusCode)
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

    func refreshJobsWithFollowUp() async {
        // Some VBR state transitions are eventually consistent right after enable/disable.
        // Do two short follow-up refreshes so UI status catches up immediately.
        try? await Task.sleep(nanoseconds: 750_000_000)
        await fetchJobs(reloadBackupInventory: false)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await fetchJobs(reloadBackupInventory: false)
    }

    func runStartActiveFullJob(jobID: String) async {
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

            guard isSuccessfulJobAction(http.statusCode, actionPath: "start") else {
                let message = extractAPIErrorMessage(from: data) ?? "Could not start active full."
                if isJobAlreadyActiveOnServerError(message, statusCode: http.statusCode) {
                    await refreshJobsAfterJobAlreadyActive()
                    return
                }
                errorMessage = formatJobActionErrorMessage(message, actionName: "start active full", statusCode: http.statusCode)
                return
            }

            await fetchJobs(reloadBackupInventory: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isSuccessfulJobAction(_ statusCode: Int, actionPath: String) -> Bool {
        var accepted = Set([200, 202, 204])
        if actionPath == "start" {
            accepted.insert(201)
        }
        return accepted.contains(statusCode)
    }

    func isJobAlreadyActiveOnServerError(_ message: String?, statusCode: Int) -> Bool {
        guard statusCode == 400, let message = message?.lowercased() else { return false }
        return message.contains("already in the system running tasks queue")
            || message.contains("already running")
            || message.contains("is already being executed")
            || message.contains("already started")
    }

    func formatJobActionErrorMessage(_ message: String, actionName: String, statusCode: Int) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Could not \(actionName) job (HTTP \(statusCode))."
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return "Could not \(actionName) job (HTTP \(statusCode))."
        }
        return "\(trimmed) (HTTP \(statusCode))"
    }

    func refreshJobsAfterJobAlreadyActive() async {
        await fetchJobs(reloadBackupInventory: false)
        await refreshJobsWithFollowUp()
    }

    func extractAPIErrorMessage(from data: Data) -> String? {
        if let apiError = try? JSONDecoder().decode(VeeamErrorResponse.self, from: data) {
            if let errors = apiError.errors?
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .filter({ !$0.isEmpty }),
               !errors.isEmpty {
                return errors.joined(separator: " ")
            }

            if let message = apiError.message?.trimmingCharacters(in: .whitespacesAndNewlines),
               !message.isEmpty {
                return message
            }
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = object["errors"] as? [String] {
            let messages = errors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !messages.isEmpty {
                return messages.joined(separator: " ")
            }
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           !raw.hasPrefix("{"),
           !raw.hasPrefix("[") {
            return raw
        }

        return nil
    }

    func loginRequest(
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

    func makeLoginRequest(
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

    func fetchJobStates(
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
    func fetchJobConfig(token: String, decoder: JSONDecoder, jobID: String) async -> JobConfig? {
        guard let url = URL(string: "\(serverURL)/api/v1/jobs/\(jobID)") else { return nil }
        guard let (data, response) = try? await session.data(for: authorisedRequest(url: url, token: token)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let config = try? decoder.decode(JobConfigResponse.self, from: data).data else {
            return nil
        }
        return config
    }

    func fetchJobConfigs(
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

    func fetchBackupRecords(token: String, decoder: JSONDecoder) async -> [BackupRecord]? {
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

    func fetchBackupObjects(token: String, decoder: JSONDecoder) async -> [BackupObject]? {
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

    func fetchRestorePoints(token: String, decoder: JSONDecoder) async -> [RestorePointRecord]? {
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

    func authorisedRequest(url: URL, token: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(apiVersion,         forHTTPHeaderField: "x-api-version")
        return r
    }

    /// Exchanges the stored refresh token for a fresh access token.
    /// Returns true and updates `authToken`/`refreshToken`/`tokenExpiresAt` on success.
    func refreshAccessToken() async -> Bool {
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
    func reloginWithStoredCredentials() async -> Bool {
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
    func performAuthorized(
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

    func makeLoginErrorMessage(statusCode: Int, data: Data) -> String {
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

    func parseMFAChallenge(from data: Data, statusCode: Int) -> MFAChallenge? {
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

    func makeConnectionErrorMessage(_ error: Error, serverURL: String) -> String {
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

    func bestSupportedVersion(from data: Data) -> String? {
        guard let message = String(data: data, encoding: .utf8) else { return nil }

        let matches = Self.supportedApiVersions.filter { version in
            message.contains("v\(version)") || message.contains(version)
        }

        return matches.first
    }

    // MARK: - Schedule description

    func stateScheduleDescription(
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
    func scheduleDescription(
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

    func cleanedNextRunPolicy(_ value: String?) -> String? {
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

    func backupInventory(
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

    func candidateObjectNames(for state: JobState, config: JobConfig?) -> Set<String> {
        var names: Set<String> = [canonicalObjectName(state.name)]
        config?.virtualMachines?.includes.forEach { included in
            if let name = included.name {
                names.insert(canonicalObjectName(name))
            }
        }
        return names
    }

    func canonicalObjectName(_ value: String) -> String {
        value
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? value.lowercased()
    }

    func driveSummary(from virtualMachines: JobConfig.VirtualMachines?) -> String? {
        guard let diskSelection = virtualMachines?.excludes?.disks?.first else { return nil }

        if diskSelection.disksToProcess?.lowercased() == "alldisks" {
            return "All Drives"
        }

        let count = diskSelection.disks?.count ?? 0
        guard count > 0 else { return nil }
        return count == 1 ? "1 Drive" : "\(count) Drives"
    }

    func fallbackVMStorageSize(from restorePoints: [RestorePointRecord]) -> String? {
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

    func buildBackupPoints(
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

    func backupPointStatus(for point: RestorePointRecord) -> String {
        point.malwareStatus == "Clean" ? "OK" : (point.malwareStatus ?? "Unknown")
    }

    func gfsFlags(
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

    func inferredGFSFlags(
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

    func fetchBackupPointMetadataByRestorePointID(
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

    func fetchBackupPointMetadata(
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

    func ingestBackupFileMetadata(
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

    func mergeBackupPointMetadata(
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

    func isVbmFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".vbm")
    }

    func resolveBackupSet(
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

    func displayName(forBackupSetPath raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        if let last = normalized.split(separator: "/").last {
            return String(last)
        }
        return raw
    }

    func inferBackupSetName(from backupFileName: String, backupID: String) -> String {
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

    func normalizedBackupSetName(from backupFileName: String, backupID: String) -> String {
        inferBackupSetName(from: backupFileName, backupID: backupID)
    }

    func extractRestorePointIDs(from object: [String: AnyCodableValue]) -> [String] {
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

    func extractImmutabilityDate(from object: [String: AnyCodableValue]) -> Date? {
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

    func parseAnyValueDate(_ value: AnyCodableValue) -> Date? {
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

    func parseFlexibleDate(_ raw: String) -> Date? {
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

    func compactGFSFlags(from periods: [String]) -> [String] {
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

    func isRetainedWeeklyFull(
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

    func monthName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date).lowercased()
    }

    func isRetainedMonthlyFull(
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

    func isRetainedYearlyFull(
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

    func retainedPoint(
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
    func formatScheduleTime(_ timeStr: String?) -> String? {
        guard let timeStr else { return nil }
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return timeStr }
        let h = parts[0], m = parts[1]
        let displayH = h == 0 ? 12 : (h > 12 ? h - 12 : h)
        return String(format: "%d:%02d %@", displayH, m, h >= 12 ? "PM" : "AM")
    }

    func normalisedJobIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "urn:veeam:Job:", with: "")
            .replacingOccurrences(of: "urn:uuid:", with: "")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .lowercased()
    }

}
