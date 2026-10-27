import Foundation

/// Phone notifications through ntfy (https://ntfy.sh). Messages that can't be
/// sent while the Mac is offline are queued and sent once it's back online.
final class Notifier {
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private let lock = NSLock()
    private var pending: [[String: Any]] = []

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func send(_ title: String, _ message: String, tags: [String] = [], priority: Int = 3,
              actions: [[String: Any]] = [], queueIfOffline: Bool = true, config cfg: AppConfig) {
        guard cfg.ntfyEnabled, !cfg.ntfyTopic.isEmpty, let url = URL(string: cfg.ntfyServer) else { return }
        var body: [String: Any] = ["topic": cfg.ntfyTopic, "title": title, "message": message, "priority": priority]
        if !tags.isEmpty { body["tags"] = tags }
        if !actions.isEmpty { body["actions"] = actions }
        post(body, to: url) { [weak self] ok in
            guard !ok, queueIfOffline, let self else { return }
            body["message"] = "(\(Self.clock.string(from: Date()))) \(message)"
            self.enqueue(body)
        }
    }

    func flush(_ cfg: AppConfig) {
        lock.lock()
        let items = pending
        pending = []
        lock.unlock()
        guard !items.isEmpty, cfg.ntfyEnabled, let url = URL(string: cfg.ntfyServer) else { return }
        for item in items {
            post(item, to: url) { [weak self] ok in if !ok { self?.enqueue(item) } }
        }
    }

    private func enqueue(_ body: [String: Any]) {
        lock.lock()
        pending.append(body)
        if pending.count > 20 { pending.removeFirst() }
        lock.unlock()
    }

    private func post(_ body: [String: Any], to url: URL, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }
}
