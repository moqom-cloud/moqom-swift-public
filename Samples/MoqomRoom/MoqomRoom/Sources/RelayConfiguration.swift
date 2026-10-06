import Foundation
import MoqomCore
import MoqomKit
import MoqomLoopback

struct JoinService: Hashable {
    var host: String
    var port: UInt16

    var certificateHashes: [String]

    var credential: String

    static let development = JoinService(
        host: BuildSetting.string("MOQOMJoinHost") ?? "api.moqom.cloud",
        port: BuildSetting.port("MOQOMJoinPort") ?? 443,
        certificateHashes: [],
        credential: ""
    )

    var isUsable: Bool { !host.isEmpty && !credential.isEmpty }

    func client(tenant: String = "") -> TokenService {
        TokenService(
            endpoint: RelayEndpoint(host: host, port: port),
            certificateHashes: certificateHashes,
            credential: credential,
            tenant: tenant
        )
    }

    var summary: String {
        guard !host.isEmpty else { return "none — a token has to be pasted" }
        let trust = certificateHashes.isEmpty ? "system trust" : "pinned"
        return credential.isEmpty
            ? "\(host):\(port), \(trust), no credential"
            : "\(host):\(port), \(trust), enrolled"
    }
}

struct RelayConfiguration {
    var host: String?
    var port: UInt16

    var certificateHashes: [String]

    var token: Data

    var tokenService: JoinService?

    static let development = RelayConfiguration(
        host: BuildSetting.string("MOQOMRelayHost"),
        port: BuildSetting.port("MOQOMRelayPort") ?? 443,
        certificateHashes: [],
        token: Data(),
        tokenService: JoinService.development
    )

    static var relayHostOverridden: Bool {
        ProcessInfo.processInfo.arguments.contains("--relay-host") || loopbackRequested
    }

    static var loopbackRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--loopback")
    }

    mutating func useDevelopmentEndpoint() {
        host = Self.development.host
        port = Self.development.port
        certificateHashes = Self.development.certificateHashes
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        defaults: UserDefaults = .standard
    ) -> RelayConfiguration {
        var host: String?
        var port: UInt16?
        var hashes: [String] = []
        var token: Data?
        var joinHost: String?
        var joinPort: UInt16?
        var joinHashes: [String] = []
        var joinCredential: String?

        var loopback = false

        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--loopback": loopback = true
            case "--relay-host": host = value
            case "--relay-port": port = value.flatMap(UInt16.init)
            case "--relay-cert-hash": value.map { hashes.append($0) }
            case "--relay-token": token = value.flatMap { $0.data(using: .utf8) }
            case "--join-host": joinHost = value
            case "--join-port": joinPort = value.flatMap(UInt16.init)
            case "--join-cert-hash": value.map { joinHashes.append($0) }
            case "--join-credential": joinCredential = value
            default: break
            }
            index += 1
        }

        if loopback {
            return RelayConfiguration(
                host: nil,
                port: 443,
                certificateHashes: [],
                token: Data(),
                tokenService: nil
            )
        }

        let remembered: RelayConfiguration = defaults.object(forKey: "relayHost") == nil
            ? .development
            : RelayConfiguration(
                host: defaults.string(forKey: "relayHost").flatMap { $0.isEmpty ? nil : $0 },
                port: UInt16(defaults.integer(forKey: "relayPort")).nonZero ?? 443,
                certificateHashes: defaults.stringArray(forKey: "relayCertificateHashes") ?? [],
                token: Data(),
                tokenService: rememberedService(defaults)
            )

        let dialling = host ?? remembered.host

        var service = remembered.tokenService ?? JoinService.development
        joinHost.map { service.host = $0 }
        joinPort.map { service.port = $0 }
        if !joinHashes.isEmpty { service.certificateHashes = joinHashes }
        service.credential = joinCredential
            ?? (service.host.isEmpty ? "" : TokenStore.loadJoinCredential(for: service.host))
            ?? ""

        return RelayConfiguration(
            host: dialling,
            port: port ?? remembered.port,
            certificateHashes: hashes.isEmpty ? remembered.certificateHashes : hashes,
            token: token ?? dialling.flatMap { TokenStore.load(for: $0) } ?? Data(),
            tokenService: service
        )
    }

    private static func rememberedService(_ defaults: UserDefaults) -> JoinService? {
        guard let host = defaults.string(forKey: "joinHost") else { return nil }
        return JoinService(
            host: host,
            port: UInt16(defaults.integer(forKey: "joinPort")).nonZero ?? 443,
            certificateHashes: defaults.stringArray(forKey: "joinCertificateHashes") ?? [],
            credential: ""
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(host ?? "", forKey: "relayHost")
        defaults.set(Int(port), forKey: "relayPort")
        defaults.set(certificateHashes, forKey: "relayCertificateHashes")
        if let host { TokenStore.save(token, for: host) }

        if let service = tokenService, !service.host.isEmpty {
            defaults.set(service.host, forKey: "joinHost")
            defaults.set(Int(service.port), forKey: "joinPort")
            defaults.set(service.certificateHashes, forKey: "joinCertificateHashes")
            TokenStore.saveJoinCredential(service.credential, for: service.host)
        }
    }

    func needsAToken(joining room: String, as username: String, on device: String = "") -> Bool {
        guard let held = credential else { return true }
        if held.expires.timeIntervalSinceNow < 60 { return true }
        return held.complaint(joining: room, as: username, on: device) != nil
    }

    var credential: Credential? { token.isEmpty ? nil : Credential(token) }

    func transport(bestEffort: Bool = false) -> any Transport {
        #if canImport(Network)
            guard host != nil else { return LoopbackTransport() }
            return MoqtTransport.network(
                trust: certificateHashes.isEmpty
                    ? .system
                    : .pinned(base64CertificateHashes: certificateHashes),
                serviceClass: bestEffort ? .bestEffort : NetworkQUICCarrier.serviceClass
            )
        #else
            return LoopbackTransport()
        #endif
    }

    var endpoint: RelayEndpoint {
        RelayEndpoint(host: host ?? "relay.moqom.invalid", port: port)
    }

    var summary: String {
        guard let host else { return "loopback (no relay configured)" }
        let trust = certificateHashes.isEmpty ? "system trust" : "pinned"
        let credential = switch self.credential {
        case nil: token.isEmpty ? "no token" : "unreadable token"
        case let held?: held.hasExpired ? "expired token" : "token"
        }
        return "\(host):\(port), \(trust), \(credential)"
    }
}

struct LaunchOptions {
    var username: String?
    var room: String?

    var tenant = "demo"

    var pairingCode: String?

    var autojoin = false

    var benchmark = false

    var live = false

    var goesLive: Bool { benchmark || live }

    var flatLayers = false

    var eagerEncoding = false

    var frameRate: Double?

    var plainCapture = false

    var mediaVolume: Bool?

    var silenceRoom = false

    var mix: Float?

    var bestEffort = false

    var kilobitsPerSecond: Int?

    var statisticsMilliseconds: Int?

    var playoutMilliseconds: Int?

    var playoutTolerance: Double?

    var playoutFloorMilliseconds: Int?

    var audio: String?

    var locale: String?

    var video: String?

    var bubbles = false

    var sharesTheField = true

    var popEverySeconds: Double?

    var reshapeEverySeconds: Double?

    var quietLogs = false

    var roomKey: String?

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--username": options.username = value
            case "--room": options.room = value
            case "--tenant": value.map { options.tenant = $0 }
            case "--pairing-code": options.pairingCode = value
            case "--autojoin": options.autojoin = true
            case "--benchmark": options.benchmark = true
            case "--live": options.live = true
            case "--flat-layers": options.flatLayers = true
            case "--eager-encoding": options.eagerEncoding = true
            case "--plain-capture": options.plainCapture = true
            case "--media-volume": options.mediaVolume = true
            case "--call-volume": options.mediaVolume = false
            case "--silence-room": options.silenceRoom = true
            case "--mix": options.mix = value.flatMap(Float.init)
            case "--best-effort": options.bestEffort = true
            case "--fps": options.frameRate = value.flatMap(Double.init)
            case "--kbps": options.kilobitsPerSecond = value.flatMap(Int.init)
            case "--stats-ms": options.statisticsMilliseconds = value.flatMap(Int.init)
            case "--playout-ms": options.playoutMilliseconds = value.flatMap(Int.init)
            case "--tolerance": options.playoutTolerance = value.flatMap(Double.init)
            case "--floor-ms": options.playoutFloorMilliseconds = value.flatMap(Int.init)
            case "--audio": options.audio = value ?? "tone"
            case "--video": options.video = value ?? "camera"
            case "--locale": options.locale = value
            case "--bubbles": options.bubbles = true
            case "--no-bubbles": options.sharesTheField = false
            case "--pop-every": options.popEverySeconds = value.flatMap(Double.init)
            case "--reshape-every": options.reshapeEverySeconds = value.flatMap(Double.init)
            case "--quiet-logs": options.quietLogs = true
            case "--room-key": options.roomKey = value
            default: break
            }
            index += 1
        }
        return options
    }
}

// Endpoints come from Info.plist keys filled in from Signing.xcconfig.
private enum BuildSetting {
    static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    static func port(_ key: String) -> UInt16? {
        string(key).flatMap(UInt16.init)
    }
}

private extension UInt16 {
    var nonZero: UInt16? { self == 0 ? nil : self }
}
