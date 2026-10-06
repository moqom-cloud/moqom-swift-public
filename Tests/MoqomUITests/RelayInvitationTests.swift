// Reading a link that carries a relay address, a certificate and a credential,
// through the public API only. A link that parses to something partial is worse
// than one that fails, so most of these are refusals.

import Foundation
import MoqomKit
import Testing

@Suite("Relay invitations")
struct RelayInvitationTests {
    private let hash = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    private let otherHash = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

    @Test("a link survives being written and read back")
    func roundTrip() throws {
        let invitation = RelayInvitation(
            endpoint: RelayEndpoint(host: "relay.example.com", port: 443),
            certificateHashes: [hash],
            token: Data("header.payload.signature".utf8)
        )

        let url = try #require(invitation.url(scheme: "moqom"))
        let read = try #require(RelayInvitation(url))

        #expect(read.endpoint.host == invitation.endpoint.host)
        #expect(read.endpoint.port == invitation.endpoint.port)
        #expect(read.token == invitation.token)
        // Base64 contains `+`, `/` and `=`, all of which mean something in a query.
        #expect(read.certificateHashes == [hash])
    }

    @Test("a link with no relay in it is refused")
    func noRelay() {
        #expect(RelayInvitation(URL(string: "moqom://join?token=abc")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=")!) == nil)
    }

    @Test("a port that is not a port is refused rather than ignored")
    func badPort() {
        #expect(RelayInvitation(URL(string: "moqom://join?relay=relay.example:https")!) == nil)
        #expect(RelayInvitation(URL(string: "moqom://join?relay=relay.example:99999")!) == nil)
    }

    @Test("a relay with no port named gets 443")
    func defaultPort() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=relay.example")!))
        #expect(read.endpoint.host == "relay.example")
        #expect(read.endpoint.port == 443)
    }

    @Test("an IPv6 literal keeps its colons")
    func addressWithColons() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=[2001:db8::1]")!))
        #expect(read.endpoint.host == "[2001:db8::1]")
        #expect(read.endpoint.port == 443)
    }

    @Test("more than one certificate can be trusted, for a rotation")
    func severalHashes() throws {
        let url = URL(string: "moqom://join?relay=r.example&cert=\(hash)&cert=\(otherHash)")!
        let read = try #require(RelayInvitation(url))
        #expect(read.certificateHashes.count == 2)
    }

    @Test("a link with no credential is a link to a relay that asks for none")
    func noToken() throws {
        let read = try #require(RelayInvitation(URL(string: "moqom://join?relay=r.example")!))
        #expect(read.token.isEmpty)
        #expect(read.url(scheme: "moqom")?.absoluteString.contains("token") == false)
    }

    @Test("a link can name a token service instead of carrying a token")
    func carriesAService() throws {
        let invitation = RelayInvitation(
            endpoint: RelayEndpoint(host: "relay.example.com", port: 443),
            certificateHashes: [hash],
            tokenService: TokenService(
                endpoint: RelayEndpoint(host: "api.moqom.cloud", port: 443),
                certificateHashes: [otherHash],
                credential: "0f1e2d3c"
            )
        )

        let url = try #require(invitation.url(scheme: "moqom"))
        let read = try #require(RelayInvitation(url))
        let service = try #require(read.tokenService)

        #expect(service.endpoint.host == "api.moqom.cloud")
        #expect(service.endpoint.port == 443)
        #expect(service.credential == "0f1e2d3c")
        // The relay's and the service's certificates stay apart.
        #expect(service.certificateHashes == [otherHash])
        #expect(read.certificateHashes == [hash])
    }

    @Test("a service that is named has to parse")
    func badService() {
        #expect(RelayInvitation(URL(string: "moqom://join?relay=r.example&join=c.example:https")!) == nil)
    }

    @Test("the scheme is the application's to choose")
    func anyScheme() throws {
        let read = try #require(RelayInvitation(URL(string: "https://example.com/j?relay=r.example:8443")!))
        #expect(read.endpoint.port == 8443)
    }
}
