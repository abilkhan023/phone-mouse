import CryptoKit
import Foundation
import Security

// Every packet is sealed with ChaCha20-Poly1305 under a key that the two
// devices share after pairing. The nonce carries a counter that only grows,
// so the Mac drops anything forged, altered or replayed.
struct SecureChannel {
    // Both sides draw counters from the clock, so the sender goes into the
    // nonce as well to keep the two directions from ever sharing a nonce.
    enum Sender: UInt8 {
        case phone
        case mac
    }

    private static let tag: UInt8 = 0xE1
    private static let counterSize = 8
    private static let overhead = 1 + counterSize + 16

    let key: SymmetricKey

    func seal(_ packet: Packet, counter: UInt64, from sender: Sender) -> Data? {
        guard let box = try? ChaChaPoly.seal(packet.encoded(), using: key, nonce: Self.nonce(counter, sender)) else { return nil }
        var data = Data([Self.tag])
        Swift.withUnsafeBytes(of: counter.littleEndian) { data.append(contentsOf: $0) }
        data.append(box.ciphertext)
        data.append(box.tag)
        return data
    }

    func open(_ data: Data, from sender: Sender) -> (packet: Packet, counter: UInt64)? {
        guard data.count > Self.overhead, data.first == Self.tag else { return nil }
        var counter: UInt64 = 0
        Swift.withUnsafeMutableBytes(of: &counter) {
            $0.copyBytes(from: data[data.startIndex + 1..<data.startIndex + 1 + Self.counterSize])
        }
        counter = UInt64(littleEndian: counter)
        let body = data.dropFirst(1 + Self.counterSize)
        guard let box = try? ChaChaPoly.SealedBox(
                nonce: Self.nonce(counter, sender),
                ciphertext: body.dropLast(16),
                tag: body.suffix(16)
              ),
              let plain = try? ChaChaPoly.open(box, using: key),
              let packet = Packet(data: plain) else { return nil }
        return (packet, counter)
    }

    static func counter(after last: UInt64) -> UInt64 {
        max(last + 1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }

    private static func nonce(_ counter: UInt64, _ sender: Sender) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = sender.rawValue
        Swift.withUnsafeBytes(of: counter.littleEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

// The pairing code holds the Mac's Bonjour name and the shared key. The Mac
// shows it as a QR code and the phone scans it once.
struct Pairing: Equatable {
    private static let scheme = "phonemouse"

    let hostName: String
    let keyData: Data

    var key: SymmetricKey { SymmetricKey(data: keyData) }

    static func generate(hostName: String) -> Pairing {
        Pairing(hostName: hostName, keyData: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    init(hostName: String, keyData: Data) {
        self.hostName = hostName
        self.keyData = keyData
    }

    init?(code: String) {
        guard let url = URLComponents(string: code),
              url.scheme == Self.scheme,
              let items = url.queryItems,
              let name = items.first(where: { $0.name == "host" })?.value,
              let encoded = items.first(where: { $0.name == "key" })?.value,
              let key = Data(base64URL: encoded),
              key.count == 32 else { return nil }
        self.init(hostName: name, keyData: key)
    }

    var code: String {
        var url = URLComponents()
        url.scheme = Self.scheme
        url.host = "pair"
        url.queryItems = [
            URLQueryItem(name: "host", value: hostName),
            URLQueryItem(name: "key", value: keyData.base64URL),
        ]
        return url.string ?? ""
    }
}

enum PairingStore {
    private static let service = "PhoneMouse.pairing"
    private static let listService = "PhoneMouse.pairings"

    // The Mac keeps one pairing.
    static func load() -> Pairing? {
        read(service).flatMap { Pairing(code: String(decoding: $0, as: UTF8.self)) }
    }

    static func save(_ pairing: Pairing) {
        write(service, Data(pairing.code.utf8))
    }

    static func clear() {
        delete(service)
    }

    // The phone keeps one per Mac, the preferred one first. A single pairing
    // from before is taken over.
    static func loadAll() -> [Pairing] {
        if let data = read(listService), let codes = try? JSONDecoder().decode([String].self, from: data) {
            return codes.compactMap(Pairing.init(code:))
        }
        return load().map { [$0] } ?? []
    }

    static func saveAll(_ pairings: [Pairing]) {
        guard let data = try? JSONEncoder().encode(pairings.map(\.code)) else { return }
        write(listService, data)
    }

    private static func read(_ service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ service: String, _ data: Data) {
        delete(service)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(_ service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
