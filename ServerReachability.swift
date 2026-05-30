import Foundation
import SwiftUI

// MARK: - Reachability status

enum ReachabilityStatus: Equatable {
    case unknown
    case checking
    case reachable
    case unreachable
}

// MARK: - Probe URL + user-facing messages

nonisolated enum ServerReachability {
    static let probeTimeout: TimeInterval = 5
    static let debounceInterval: TimeInterval = 0.45

    /// Builds the root URL used for GET connectivity probes (Veeam REST port 9419).
    static func probeURL(from serverURL: String, normalized: String) -> URL? {
        guard var components = URLComponents(string: normalized),
              let host = components.host, !host.isEmpty else { return nil }
        components.port = 9419
        components.path = "/"
        return components.url
    }

    static func displayHost(from serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "server" }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            if let port = url.port, port != 443 && port != 80 {
                return "\(host):\(port)"
            }
            return host
        }
        if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            return host
        }
        return trimmed
            .replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
    }

    static func unreachableMessage(for serverURL: String) -> String {
        let host = displayHost(from: serverURL)
        return "Cannot reach server at \(host). Check your network connection and ensure VPN is connected if required to reach this host."
    }
}

// MARK: - Connectivity probe

/// Serializes reachability probes and drops superseded results instead of cancelling
/// in-flight URLSession work (which triggers `nw_connection_copy_protocol_metadata` console noise).
actor ServerReachabilityProbe {
    static let shared = ServerReachabilityProbe()

    private var generation = 0
    private var inFlightProbe: Task<ReachabilityStatus, Never>?
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = ServerReachability.probeTimeout
        config.timeoutIntervalForResource = ServerReachability.probeTimeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: PinningTrustDelegate(), delegateQueue: nil)
    }

    /// Returns nil when a newer probe was requested before this one finished (caller should ignore).
    func check(serverURL: String, normalized: String) async -> ReachabilityStatus? {
        generation += 1
        let requestGeneration = generation

        guard let url = ServerReachability.probeURL(from: serverURL, normalized: normalized) else {
            return requestGeneration == generation ? .unreachable : nil
        }

        let status = await runSerializedProbe(to: url)
        return requestGeneration == generation ? status : nil
    }

    /// Always returns a definitive result for login gating; waits for any in-flight probe first.
    func checkForLogin(serverURL: String, normalized: String) async -> ReachabilityStatus {
        if let inFlightProbe {
            _ = await inFlightProbe.value
        }
        generation += 1

        guard let url = ServerReachability.probeURL(from: serverURL, normalized: normalized) else {
            return .unreachable
        }

        return await runSerializedProbe(to: url)
    }

    private func runSerializedProbe(to url: URL) async -> ReachabilityStatus {
        if let inFlightProbe {
            _ = await inFlightProbe.value
        }

        let probe = Task { await performGETProbe(to: url) }
        inFlightProbe = probe
        let status = await probe.value
        inFlightProbe = nil
        return status
    }

    private func performGETProbe(to url: URL) async -> ReachabilityStatus {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ServerReachability.probeTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await session.data(for: request)
            if response is HTTPURLResponse {
                return .reachable
            }
            return .unreachable
        } catch {
            return .unreachable
        }
    }
}

// MARK: - Login form indicator

struct ReachabilityIndicator: View {
    let status: ReachabilityStatus

    var body: some View {
        Group {
            switch status {
            case .unknown:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.textTertiary)
            case .checking:
                ProgressView()
                    .controlSize(.mini)
            case .reachable:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.statusSuccess)
            case .unreachable:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Theme.statusFailed)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .frame(width: 22, height: 22)
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        switch status {
        case .unknown:
            return "Server reachability has not been checked yet."
        case .checking:
            return "Checking whether the Veeam server is reachable on port 9419."
        case .reachable:
            return "Server is reachable on port 9419."
        case .unreachable:
            return "Server is not reachable. Check network connection and VPN if required."
        }
    }
}
