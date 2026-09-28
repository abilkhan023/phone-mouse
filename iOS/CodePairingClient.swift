import CryptoKit
import Foundation
import Network

// The phone's side of pairing by code; see CodePairing for the exchange.
final class CodePairingClient {
    enum Failure: Error {
        case noAnswer
        case mismatch
    }

    private let name: String
    private let connection: NWConnection
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let phoneNonce = CodePairing.newNonce()
    private let onCode: (String) -> Void
    private let completion: (Result<Pairing, Failure>) -> Void
    private let retry = 0.3
    private let answerTimeout = 5.0
    private let allowTimeout = 120.0

    private var macKey: Data?
    private var commitment: Data?
    private var pairing: Pairing?
    private var timer: Timer?
    private var startedAt = Date()
    private var finished = false

    private var phoneKey: Data { privateKey.publicKey.rawRepresentation }

    init(
        host: NWEndpoint,
        peerToPeer: Bool,
        onCode: @escaping (String) -> Void,
        completion: @escaping (Result<Pairing, Failure>) -> Void
    ) {
        if case let .service(name, _, _, _) = host {
            self.name = name
        } else {
            name = "Mac"
        }
        self.onCode = onCode
        self.completion = completion
        connection = NWConnection(to: host, using: HostLink.parameters(peerToPeer: peerToPeer))
        connection.start(queue: .main)
        receive()
        let timer = Timer(timeInterval: retry, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        connection.cancel()
    }

    // Messages go out again until answered, since any of them may be lost.
    // Once the code is up the Mac waits for a click, so the phone keeps asking.
    private func tick() {
        guard !finished else { return }
        let limit = pairing == nil ? answerTimeout : allowTimeout
        guard Date().timeIntervalSince(startedAt) < limit else {
            finish(.failure(.noAnswer))
            return
        }
        let packet: Packet = macKey == nil ? .pairHello(publicKey: phoneKey) : .pairNonce(phoneNonce)
        connection.send(content: packet.encoded(), completion: .idempotent)
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data {
                self.handle(data)
            }
            if error == nil {
                self.receive()
            }
        }
    }

    private func handle(_ data: Data) {
        if let pairing {
            if SecureChannel(key: pairing.key).open(data, from: .mac) != nil {
                finish(.success(pairing))
            }
            return
        }
        switch Packet(data: data) {
        case let .pairReply(key, commitment) where macKey == nil:
            macKey = key
            self.commitment = commitment
            tick()
        case let .pairNonceReply(macNonce):
            reveal(macNonce)
        default:
            break
        }
    }

    // A Mac nonce that does not match its commitment means someone is in the
    // middle, so pairing stops right there.
    private func reveal(_ macNonce: Data) {
        guard let macKey, let commitment else { return }
        guard CodePairing.commitmentIsValid(commitment, macNonce: macNonce, macKey: macKey, phoneKey: phoneKey),
              let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            finish(.failure(.mismatch))
            return
        }
        let key = CodePairing.sessionKey(secret: secret, phoneKey: phoneKey, macKey: macKey, phoneNonce: phoneNonce, macNonce: macNonce)
        pairing = Pairing(hostName: name, keyData: key)
        startedAt = Date()
        onCode(CodePairing.code(phoneKey: phoneKey, macKey: macKey, phoneNonce: phoneNonce, macNonce: macNonce))
    }

    private func finish(_ result: Result<Pairing, Failure>) {
        cancel()
        completion(result)
    }
}
