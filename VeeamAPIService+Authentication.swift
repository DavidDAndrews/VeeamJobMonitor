import Foundation
import Combine
import Security
#if canImport(AppKit)
import AppKit
#endif

extension VeeamAPIService {
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
    func applyTokenResponse(_ token: VeeamTokenResponse) {
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

    func login(
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

}
