import Foundation
import Security
import CryptoKit

// MARK: - TLS

/// Lightweight keychain-backed store for trust-on-first-use certificate fingerprints,
/// keyed by host. Shares the app's generic-password service so entries live alongside
/// saved connections.
struct CertificateTrustStore {
    static let keychainService = "bz.andrews.VeeamMonitor"

    private func account(for host: String) -> String {
        "certpin:\(host)"
    }

    func load(host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account(for: host),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(host: String, hash: String) {
        guard let data = hash.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account(for: host)
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

/// URLSession delegate that pins server certificates using trust-on-first-use.
/// The first time a host is seen, the SHA-256 of its leaf certificate (DER) is stored.
/// Later connections must present the same fingerprint or the challenge is rejected,
/// which surfaces certificate changes / MITM while still supporting self-signed VBR certs.
final class PinningTrustDelegate: NSObject, URLSessionDelegate {
    private let trustStore: CertificateTrustStore

    init(trustStore: CertificateTrustStore = CertificateTrustStore()) {
        self.trustStore = trustStore
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard let fingerprint = Self.leafCertificateFingerprint(for: trust) else {
            // Without a usable certificate we cannot pin; fail closed.
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if let stored = trustStore.load(host: host) {
            if stored == fingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                // Certificate changed since first use; reject to flag possible MITM.
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        } else {
            // First use: remember the fingerprint and trust it.
            trustStore.save(host: host, hash: fingerprint)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// Returns the lowercase hex SHA-256 of the leaf certificate DER, or nil if unavailable.
    private static func leafCertificateFingerprint(for trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
