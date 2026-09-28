import CryptoKit
import Foundation

// Pairing by typing on the phone the six-digit code the Mac shows, done the
// way Bluetooth passkey entry works.
//
// The two agree on a key with Curve25519, then prove to each other that they
// know the code one bit per round. In each round both commit to the bit
// before either reveals, and the phone reveals first. Someone in the middle
// has to commit to a bit it does not know yet and is caught with even odds in
// every round, so twenty rounds leave a chance of one in a million. A short
// code cannot be worked out offline from what goes over the air, because each
// commitment hides its bit behind a fresh random nonce. After any failure the
// Mac shows a new code, so nothing learned carries over.
enum CodePairing {
    static let rounds = 20
    static let digits = 6

    static func newCode() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }

    static func newNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func bit(of code: String, round: Int) -> UInt8 {
        UInt8(((Int(code) ?? 0) >> round) & 1)
    }

    static func commitment(nonce: Data, ownKey: Data, otherKey: Data, round: Int, code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message(ownKey, otherKey, round, code), using: SymmetricKey(data: nonce)))
    }

    static func commitmentIsValid(_ commitment: Data, nonce: Data, ownKey: Data, otherKey: Data, round: Int, code: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(commitment, authenticating: message(ownKey, otherKey, round, code), using: SymmetricKey(data: nonce))
    }

    static func sessionKey(secret: SharedSecret, phoneKey: Data, macKey: Data) -> Data {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("phonemouse pairing".utf8),
            sharedInfo: phoneKey + macKey,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    private static func message(_ ownKey: Data, _ otherKey: Data, _ round: Int, _ code: String) -> Data {
        ownKey + otherKey + Data([UInt8(round), bit(of: code, round: round)])
    }
}
