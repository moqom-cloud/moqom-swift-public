import Foundation
import Security

struct Credential {
    var subject: String
    var tenant: String
    var room: String
    var expires: Date

    var device: String

    init?(_ token: Data) {
        let parts = token.split(separator: UInt8(ascii: "."))
        guard parts.count == 3, let payload = Self.unpad(parts[1]) else { return nil }

        struct Claims: Decodable {
            struct Scope: Decodable { var room: String? }
            struct Confirmation: Decodable { var jkt: String? }
            var sub: String?
            var aud: String?
            var exp: Double?
            var moqt: Scope?
            var cnf: Confirmation?
        }

        guard
            let claims = try? JSONDecoder().decode(Claims.self, from: payload),
            let expires = claims.exp
        else { return nil }

        subject = claims.sub ?? ""
        tenant = claims.aud ?? ""
        room = claims.moqt?.room ?? ""
        device = claims.cnf?.jkt ?? ""
        self.expires = Date(timeIntervalSince1970: expires)
    }

    private static func unpad(_ text: Data) -> Data? {
        var encoded = String(decoding: text, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    var hasExpired: Bool { expires <= .now }

    var summary: String {
        let when = expires.formatted(.relative(presentation: .numeric))
        let who = subject.isEmpty ? "somebody" : subject
        let where_ = room.isEmpty ? "no room" : "room \(room)"
        return "\(who) in \(tenant), \(where_) — \(hasExpired ? "expired" : "expires") \(when)"
    }

    func complaint(joining room: String, as username: String, on device: String = "") -> String? {
        if hasExpired { return "This token expired \(expires.formatted(.relative(presentation: .numeric)))." }
        if !self.room.isEmpty, self.room != room {
            return "This token is for room \(self.room), not \(room)."
        }
        if !subject.isEmpty, subject != username {
            return "This token names \(subject), not \(username)."
        }
        if !self.device.isEmpty, !device.isEmpty, !self.device.hasPrefix(device) {
            return "This token is bound to another device's key (\(self.device.prefix(16)))."
        }
        return nil
    }
}

enum TokenStore {
    private static let service = "cloud.moqom.room"

    private static func identity(for host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    static func load(for host: String) -> Data? {
        var query = identity(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    static func save(_ token: Data, for host: String) {
        SecItemDelete(identity(for: host) as CFDictionary)
        guard !token.isEmpty else { return }

        var item = identity(for: host)
        item[kSecValueData as String] = token
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    static func loadJoinCredential(for host: String) -> String? {
        load(for: "join:" + host).map { String(decoding: $0, as: UTF8.self) }
    }

    static func saveJoinCredential(_ credential: String, for host: String) {
        save(Data(credential.utf8), for: "join:" + host)
    }
}
