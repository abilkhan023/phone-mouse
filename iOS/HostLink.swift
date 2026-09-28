import Foundation
import Network

final class HostLink {
    var onHostChange: ((String?) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: BonjourService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.update(results)
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        onHostChange?(nil)
    }

    func send(_ report: MouseReport) {
        guard let connection, connection.state == .ready else { return }
        connection.send(content: report.encoded(), completion: .idempotent)
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        if let connection, results.contains(where: { $0.endpoint == connection.endpoint }) { return }
        connection?.cancel()
        connection = nil
        guard let endpoint = results.map(\.endpoint).min(by: { "\($0)" < "\($1)" }) else {
            onHostChange?(nil)
            return
        }
        connect(to: endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            if case .failed = state {
                connection.cancel()
                self.connection = nil
                self.update(self.browser?.browseResults ?? [])
            }
        }
        connection.start(queue: .main)
        self.connection = connection
        if case let .service(name, _, _, _) = endpoint {
            onHostChange?(name)
        }
    }
}
