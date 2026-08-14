import Foundation
import Security

@main
struct WindowsAgentTrustValidation {
    static func main() throws {
        guard CommandLine.arguments.count >= 6 else {
            throw ValidationError.usage
        }
        let anchorData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let leafData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
        let host = CommandLine.arguments[4]
        let expected = CommandLine.arguments[5] == "true"
        let verificationDate = CommandLine.arguments.count > 6
            ? Date(timeIntervalSince1970: try requiredTimestamp(CommandLine.arguments[6]))
            : nil

        guard let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else {
            throw ValidationError.invalidFixture
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(
            leaf,
            SecPolicyCreateBasicX509(),
            &trust
        ) == errSecSuccess, let trust else { throw ValidationError.invalidFixture }

        let policy = try WindowsAgentTrustPolicy(certificateData: anchorData)
        let accepted = policy.evaluate(
            serverTrust: trust,
            host: host,
            verificationDate: verificationDate
        )
        if accepted != expected {
            let result = SecTrustCopyResult(trust).map { $0 as NSDictionary } ?? [:]
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
            var evaluationError: CFError?
            let rawEvaluation = SecTrustEvaluateWithError(trust, &evaluationError)
            let diagnostics = "Trust diagnostics: \(result)\nEvaluated chain count: \(chain.count)\nRaw evaluation: \(rawEvaluation), error: \(String(describing: evaluationError))\n"
            FileHandle.standardError.write(Data(diagnostics.utf8))
        }
        precondition(accepted == expected, "Expected trust=\(expected), received \(accepted) for \(host)")

        let agentSession = try WindowsAgentURLSessionFactory.make(
            configuration: .ephemeral,
            certificateData: anchorData
        )
        precondition(agentSession !== URLSession.shared)
        precondition(!(URLSession.shared.delegate is WindowsAgentURLSessionDelegate))
        agentSession.invalidateAndCancel()
        print("Windows Agent trust result \(accepted) matched expectation for \(host); shared HTTPS session is unaffected.")
    }

    private static func requiredTimestamp(_ value: String) throws -> TimeInterval {
        guard let timestamp = TimeInterval(value) else { throw ValidationError.usage }
        return timestamp
    }
}

private enum ValidationError: Error {
    case usage
    case invalidFixture
}
