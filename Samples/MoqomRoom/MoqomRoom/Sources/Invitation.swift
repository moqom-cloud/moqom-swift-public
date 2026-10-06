import Foundation
import MoqomKit

struct Invitation {
    var relay: RelayInvitation

    var credential: Credential?

    init?(_ url: URL) {
        guard let relay = RelayInvitation(url) else { return nil }
        self.relay = relay
        credential = relay.token.isEmpty ? nil : Credential(relay.token)
    }

    var destination: String {
        let where_ = "\(relay.endpoint.host):\(relay.endpoint.port)"
        let trust = relay.certificateHashes.isEmpty
            ? "using ordinary certificate validation"
            : "trusting a certificate it names"
        return "\(where_), \(trust)"
    }

    var identification: String {
        if let service = relay.tokenService, !service.credential.isEmpty {
            return "Enrols this phone with \(service.endpoint.host), which will issue it a"
                + " credential each time it joins."
        }
        guard let credential else {
            return relay.token.isEmpty
                ? "No credential, so this would join as nobody."
                : "The credential in it does not read as a token."
        }
        return credential.summary
    }

    var enrols: Bool { relay.tokenService?.credential.isEmpty == false }

    var isStale: Bool { !enrols && (credential?.hasExpired ?? false) }
}
