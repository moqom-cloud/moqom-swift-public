import CryptoKit
import Foundation
import MoqomCore
import MoqomKit

enum RoomKey {
    static let samplePassphrase = "moqom-sample-not-a-secret"

    static let keyID: UInt64 = 1

    static func encryption(room: RoomID, passphrase: String = samplePassphrase) -> RoomEncryption {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: Data(room.value.utf8),
            info: Data("moqom-sample room key".utf8),
            outputByteCount: 32
        )
        let base = derived.withUnsafeBytes { Data($0) }
        return .sharedKey(base, keyID: keyID)
    }
}
