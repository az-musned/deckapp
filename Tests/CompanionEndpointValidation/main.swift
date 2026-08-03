import Foundation

@main
struct CompanionEndpointValidation {
    static func main() throws {
        let lan = try CompanionEndpoint(address: "192.168.1.50")
        precondition(lan.baseURL.absoluteString == "http://192.168.1.50:8000")
        precondition(lan.route == .localNetwork)

        let localName = try CompanionEndpoint(address: "deck-pc.local:8000")
        precondition(localName.route == .localNetwork)

        let tailscale = try CompanionEndpoint(address: "100.96.12.4:8000")
        precondition(tailscale.route == .privateVPN)

        let tailscaleDNS = try CompanionEndpoint(address: "https://deck-pc.example-tailnet.ts.net")
        precondition(tailscaleDNS.route == .privateVPN)

        do {
            _ = try CompanionEndpoint(address: "https://example.com")
            preconditionFailure("Public Companion address was accepted")
        } catch CompanionEndpointError.publicAddressNotAllowed {
            // Expected.
        }

        do {
            _ = try CompanionButtonLocation(page: 0, row: 0, column: 0)
            preconditionFailure("Invalid page was accepted")
        } catch CompanionButtonLocationError.invalidLocation {
            // Expected.
        }

        print("Companion endpoint validation passed")
    }
}
