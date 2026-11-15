import Foundation

/// Just enough of the Chrome DevTools Protocol to run JavaScript in a Node
/// inspector (Qobuz's Electron main process) and get the result back.
final class CDPClient {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private(set) var isClosed = false
    var onClose: (() -> Void)?

    init(url: URL) {
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    func start() {
        task.resume()
        receive()
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        fail(PlayerError("Connection closed"))
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error)
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = s.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = obj["id"] as? Int {
                    self.lock.lock()
                    let cont = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    if let error = obj["error"] as? [String: Any] {
                        cont?.resume(throwing: PlayerError("Inspector: \(error["message"] ?? error)"))
                    } else {
                        cont?.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
                    }
                }
                self.receive()
            }
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let wasClosed = isClosed
        isClosed = true
        let all = pending
        pending = [:]
        lock.unlock()
        all.values.forEach { $0.resume(throwing: error) }
        if !wasClosed { onClose?() }
    }

    func send(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let id: Int? = lock.withLock {
            if isClosed { return nil }
            nextId += 1
            return nextId
        }
        guard let id else { throw PlayerError("Not connected to Qobuz") }
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = cont
            lock.unlock()
            task.send(.string(String(decoding: body, as: UTF8.self))) { [weak self] error in
                if let error { self?.resolve(id, with: error) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, with: PlayerError("Qobuz did not answer in time"))
            }
        }
    }

    private func resolve(_ id: Int, with error: Error) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: error)
    }

    /// Evaluate an expression (awaiting promises) and return its value.
    func evaluate(_ expression: String, timeout: TimeInterval = 20) async throws -> Any? {
        let r = try await send("Runtime.evaluate", [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true,
        ], timeout: timeout)
        if let ex = r["exceptionDetails"] as? [String: Any] {
            let desc = (ex["exception"] as? [String: Any])?["description"] as? String
            throw PlayerError(desc ?? (ex["text"] as? String) ?? "JavaScript error")
        }
        return (r["result"] as? [String: Any])?["value"]
    }
}
