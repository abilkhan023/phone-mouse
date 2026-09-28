import CryptoKit
import Foundation

// Pairing by comparing a six-digit code, the way Bluetooth numeric comparison
// works.
//
// 1. Phone -> Mac: its public key.
// 2. Mac -> phone: its public key and a commitment to a random Mac nonce.
// 3. Phone -> Mac: a random phone nonce.
// 4. Mac -> phone: the Mac nonce, which the phone checks against the commitment.
//
// Both sides then show a code made from both keys and both nonces, and the
// user allows the pairing on the Mac only if the codes match. Someone in the
// middle would have to pick keys and nonces that give the same code on both
// ends, but the commitment makes the Mac's choice fixed before the phone's
// nonce is known, so the chance is one in a million per try.
enum CodePairing {
    static func newNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func commitment(macNonce: Data, macKey: Data, phoneKey: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: macKey + phoneKey, using: SymmetricKey(data: macNonce)))
    }

    static func commitmentIsValid(_ commitment: Data, macNonce: Data, macKey: Data, phoneKey: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(commitment, authenticating: macKey + phoneKey, using: SymmetricKey(data: macNonce))
    }

    static func code(phoneKey: Data, macKey: Data, phoneNonce: Data, macNonce: Data) -> String {
        let digest = Array(SHA256.hash(data: phoneKey + macKey + phoneNonce + macNonce))
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }

    static func sessionKey(secret: SharedSecret, phoneKey: Data, macKey: Data, phoneNonce: Data, macNonce: Data) -> Data {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("phonemouse pairing".utf8),
            sharedInfo: phoneKey + macKey + phoneNonce + macNonce,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }
}
