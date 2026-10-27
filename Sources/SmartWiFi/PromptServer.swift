import Foundation
import Network

/// Tiny HTTP listener for the ntfy action buttons. It binds only to the Mac's
/// Tailscale address and runs only while a prompt is open; each prompt gets a
/// fresh token, so a URL can only answer that one question.
final class PromptServer {
    var onAnswer: ((_ token: String, _ turnOff: Bool) -> Void)?
    private var listener: NWListener?
    private var token = ""
    private let queue = DispatchQueue(label: "smartwifi.prompt-server")

    func start(host: String, port: UInt16, token: String) -> Bool {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            log("prompt server: could not listen on \(host):\(port)")
            return false
        }
        self.token = token
        l.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state { log("prompt server: \(error)") }
        }
        l.start(queue: queue)
        listener = l
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let path = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let answer: Bool? = path == "/ts/\(self.token)/off" ? true : path == "/ts/\(self.token)/keep" ? false : nil
            let body = answer.map { $0 ? "OK, turning Tailscale off." : "OK, keeping Tailscale on." } ?? "Not found"
            let response = "HTTP/1.1 \(answer == nil ? "404 Not Found" : "200 OK")\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let answer { self.onAnswer?(self.token, answer) }
        }
    }
}
