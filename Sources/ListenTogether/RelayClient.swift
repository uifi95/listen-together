import Foundation

struct Peer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

/// WebSocket connection to the relay. Reconnects on its own, and keeps an
/// estimate of the relay's clock so positions can be compared across Macs.
@MainActor
final class RelayClient {
    enum Status: Equatable { case disconnected, connecting, connected, failed(String) }

    var onStatus: ((Status) -> Void)?
    var onState: ((SharedState) -> Void)?
    var onPeers: (([Peer], _ myId: String?, _ joined: Bool) -> Void)?

    private(set) var myId: String?
    private var task: URLSessionWebSocketTask?
    private var url: URL?
    private var wanted = false
    private var retryDelay: Double = 1
    private var pingTimer: Timer?
    private var generation = 0

    /// relay clock − local clock, from the ping with the shortest round trip.
    private var samples: [(rtt: Double, offset: Double)] = []
    private var offset: Double = 0

    var relayNow: Double { Date().timeIntervalSince1970 * 1000 + offset }

    nonisolated static func makeURL(base: String, room: String, name: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst(8) }
        if s.hasPrefix("http://") { s = "ws://" + s.dropFirst(7) }
        if !s.hasPrefix("ws://") && !s.hasPrefix("wss://") { s = "wss://" + s }
        guard var c = URLComponents(string: s) else { return nil }
        if c.path.isEmpty { c.path = "/" }
        c.queryItems = [URLQueryItem(name: "room", value: room.lowercased()), URLQueryItem(name: "name", value: name)]
        return c.url
    }

    func connect(to url: URL) {
        disconnect()
        self.url = url
        wanted = true
        retryDelay = 1
        open()
    }

    func disconnect() {
        wanted = false
        generation += 1
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        myId = nil
        onStatus?(.disconnected)
    }

    private func open() {
        guard wanted, let url else { return }
        generation += 1
        let gen = generation
        onStatus?(.connecting)
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t, gen)
        samples = []
        // A burst of pings for a quick clock estimate, then one every 10 s.
        for i in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(i)) { [weak self] in self?.ping(gen) }
        }
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping(gen) }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.dropped(error.localizedDescription)
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(t, gen)
                }
            }
        }
    }

    private func dropped(_ reason: String) {
        pingTimer?.invalidate()
        task = nil
        myId = nil
        guard wanted else { return }
        onStatus?(.failed(reason))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wanted, gen == self.generation else { return }
            self.open()
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "welcome":
            myId = obj["id"] as? String
            retryDelay = 1
            if let server = obj["server"] as? Double, samples.isEmpty {
                offset = server - Date().timeIntervalSince1970 * 1000
            }
            onStatus?(.connected)
            onPeers?(decodePeers(obj["peers"]), myId, true)
        case "peers":
            onPeers?(decodePeers(obj["peers"]), myId, false)
        case "pong":
            guard let t0 = obj["t0"] as? Double, let server = obj["server"] as? Double else { return }
            let t1 = Date().timeIntervalSince1970 * 1000
            samples.append((rtt: t1 - t0, offset: server - (t0 + t1) / 2))
            if samples.count > 12 { samples.removeFirst() }
            if let best = samples.min(by: { $0.rtt < $1.rtt }) { offset = best.offset }
        case "state":
            if let s = try? JSONDecoder().decode(SharedState.self, from: data) { onState?(s) }
        case "error":
            wanted = false
            onStatus?(.failed(obj["message"] as? String ?? "Relay error"))
        default:
            break
        }
    }

    private func decodePeers(_ any: Any?) -> [Peer] {
        guard let any, let data = try? JSONSerialization.data(withJSONObject: any) else { return [] }
        return (try? JSONDecoder().decode([Peer].self, from: data)) ?? []
    }

    private func ping(_ gen: Int) {
        guard gen == generation, let task else { return }
        sendRaw(["type": "ping", "t0": Date().timeIntervalSince1970 * 1000], on: task)
    }

    func send(_ state: SharedState) {
        guard let task, var obj = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as? [String: Any] else { return }
        obj["type"] = "state"
        sendRaw(obj, on: task)
    }

    private func sendRaw(_ obj: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}
