import Foundation
import Security

nonisolated enum WindowsAgentTrustError: LocalizedError, Equatable {
    case missingBundledRoot
    case invalidBundledRoot

    var errorDescription: String? {
        switch self {
        case .missingBundledRoot: "DeckAgent-Local-Root.cer is missing from the app bundle."
        case .invalidBundledRoot: "DeckAgent-Local-Root.cer is not a valid X.509 certificate."
        }
    }
}

/// Strictly anchors Windows Agent TLS to the one public CA shipped with DeckApp.
/// The SSL policy continues to perform normal hostname/IP SAN and validity checks.
nonisolated final class WindowsAgentTrustPolicy: @unchecked Sendable {
    static let resourceName = "DeckAgent-Local-Root"
    static let resourceExtension = "cer"

    private let rootCertificate: SecCertificate

    init(certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw WindowsAgentTrustError.invalidBundledRoot
        }
        rootCertificate = certificate
    }

    convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(
            forResource: Self.resourceName,
            withExtension: Self.resourceExtension
        ) else { throw WindowsAgentTrustError.missingBundledRoot }
        try self.init(certificateData: Data(contentsOf: url))
    }

    func evaluate(serverTrust: SecTrust, host: String, verificationDate: Date? = nil) -> Bool {
        guard !host.isEmpty else { return false }
        let sslPolicy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(serverTrust, sslPolicy) == errSecSuccess,
              SecTrustSetAnchorCertificates(serverTrust, [rootCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess else { return false }
        if let verificationDate, SecTrustSetVerifyDate(serverTrust, verificationDate as CFDate) != errSecSuccess {
            return false
        }

        var error: CFError?
        // With `AnchorCertificatesOnly`, a successful result can terminate only
        // at the single bundled CA. SecTrust may omit that anchor from the
        // returned chain, so checking `chain.last` would reject valid servers.
        return SecTrustEvaluateWithError(serverTrust, &error)
    }
}

nonisolated final class WindowsAgentURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let trustPolicy: WindowsAgentTrustPolicy?

    init(bundle: Bundle = .main) {
        trustPolicy = try? WindowsAgentTrustPolicy(bundle: bundle)
        super.init()
    }

    init(certificateData: Data) throws {
        trustPolicy = try WindowsAgentTrustPolicy(certificateData: certificateData)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trustPolicy,
              let serverTrust = challenge.protectionSpace.serverTrust,
              trustPolicy.evaluate(serverTrust: serverTrust, host: challenge.protectionSpace.host) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}

nonisolated enum WindowsAgentURLSessionFactory {
    static func make(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: WindowsAgentURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    static func make(
        configuration: URLSessionConfiguration,
        certificateData: Data
    ) throws -> URLSession {
        URLSession(
            configuration: configuration,
            delegate: try WindowsAgentURLSessionDelegate(certificateData: certificateData),
            delegateQueue: nil
        )
    }
}
