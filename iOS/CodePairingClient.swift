import CryptoKit
import Foundation
import Network

// The phone's side of pairing by code; see CodePairing for the exchange.
final class CodePairingClient {
    enum Failure: Error {
        case noAnswer
        case wrongCode
        case mismatch
    }

    private enum Step {
        case hello
        case commit
        case reveal
        case confirm
    }

    private let name: String
    private let code: String
    private let connection: NWConnection
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let phoneNonces = (0..<CodePairing.rounds).map { _ in CodePairing.newNonce() }
    private let completion: (Result<Pairing, Failure>) -> Void
    private let retry = 0.25
    private let timeout = 4.0

    private var step = Step.hello
    private var round = 0
    private var macKey = Data()
    private var macCommitment = Data()
    private var pairing: Pairing?
    private var timer: Timer?
    private var progressAt = Date()
    private var finished = false

    private var phoneKey: Data { privateKey.publicKey.rawRepresentation }

    init(host: NWEndpoint, code: String, peerToPeer: Bool, completion: @escaping (Result<Pairing, Failure>) -> Void) {
        if case let .service(name, _, _, _) = host {
            self.name = name
        } else {
            name = "Mac"
        }
        self.code = code
        self.completion = completion
        connection = NWConnection(to: host, using: HostLink.parameters(peerToPeer: peerToPeer))
        connection.start(queue: .main)
        receive()
        let timer = Timer(timeInterval: retry, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        send()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        connection.cancel()
    }

    // The current message goes out again until it is answered, since any
    // message may be lost.
    private func tick() {
        guard !finished else { return }
        guard Date().timeIntervalSince(progressAt) < timeout else {
            finish(.failure(.noAnswer))
            return
        }
        send()
    }

    private func send() {
        let packet: Packet
        switch step {
        case .hello:
            packet = .pairHello(publicKey: phoneKey)
        case .commit:
            let commitment = CodePairing.commitment(nonce: phoneNonces[round], ownKey: phoneKey, otherKey: macKey, round: round, code: code)
            packet = .pairCommit(round: UInt8(round), commitment)
        case .reveal:
            packet = .pairReveal(round: UInt8(round), phoneNonces[round])
        case .confirm:
            packet = .pairReveal(round: UInt8(CodePairing.rounds - 1), phoneNonces[CodePairing.rounds - 1])
        }
        connection.send(content: packet.encoded(), completion: .idempotent)
    }

    private func advance(to next: Step) {
        step = next
        progressAt = Date()
        send()
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
        if step == .confirm, let pairing {
            if SecureChannel(key: pairing.key).open(data, from: .mac) != nil {
                finish(.success(pairing))
            }
            return
        }
        switch (step, Packet(data: data)) {
        case let (.hello, .pairReply(key)?):
            macKey = key
            advance(to: .commit)
        case let (.commit, .pairCommitReply(received, commitment)?) where Int(received) == round:
            macCommitment = commitment
            advance(to: .reveal)
        case let (.reveal, .pairRevealReply(received, nonce)?) where Int(received) == round:
            check(nonce)
        case (_, .pairReject?):
            finish(.failure(.wrongCode))
        default:
            break
        }
    }

    // The Mac's nonce has to open its commitment to the same bit, or the other
    // end does not know the code and pairing stops.
    private func check(_ macNonce: Data) {
        guard CodePairing.commitmentIsValid(macCommitment, nonce: macNonce, ownKey: macKey, otherKey: phoneKey, round: round, code: code) else {
            finish(.failure(.mismatch))
            return
        }
        round += 1
        guard round == CodePairing.rounds else {
            advance(to: .commit)
            return
        }
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else {
            finish(.failure(.mismatch))
            return
        }
        pairing = Pairing(hostName: name, keyData: CodePairing.sessionKey(secret: secret, phoneKey: phoneKey, macKey: macKey))
        advance(to: .confirm)
    }

    private func finish(_ result: Result<Pairing, Failure>) {
        cancel()
        completion(result)
    }
}
