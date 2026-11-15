import CryptoKit
import Foundation
import Network

/// The relay, built into the app so a room can be hosted from this Mac.
/// Listens on 127.0.0.1 only; a Cloudflare tunnel makes it public.
///
/// Speaks just enough HTTP/1.1 for three things:
///   GET /join/<room>  the invite page (opens the app, offers the download)
///   GET /download     this app, zipped
///   WebSocket /?room=<room>&name=<name>  the room, same protocol as relay/server.mjs
final class HostServer {
    let room: String
    let hostName: String
    var publicURL: URL?
    var maxPeers = 4

    private let queue = DispatchQueue(label: "listentogether.host-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var lastState: Data?
    private var appZip: Data?

    init(room: String, hostName: String) {
        self.room = room
        self.hostName = hostName
    }

    /// Starts listening on a free local port and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for c in self.clients.values { c.conn.cancel() }
            self.clients = [:]
        }
    }

    // MARK: Connections

    private final class Client {
        let conn: NWConnection
        var buffer: [UInt8] = []
        var isWebSocket = false
        var peerId = String(UUID().uuidString.prefix(8)).lowercased()
        var name = "Someone"
        var fragments: [UInt8] = []
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private func accept(_ conn: NWConnection) {
        let client = Client(conn)
        clients[ObjectIdentifier(client)] = client
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(client)
            default: break
            }
        }
        conn.start(queue: queue)
        read(client)
    }

    private func read(_ client: Client) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                client.buffer.append(contentsOf: data)
                if client.isWebSocket { self.readFrames(client) } else { self.readRequest(client) }
            }
            if isComplete || error != nil {
                self.drop(client)
            } else if self.clients[ObjectIdentifier(client)] != nil {
                self.read(client)
            }
        }
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.conn.cancel()
        if client.isWebSocket { broadcastPeers() }
    }

    // MARK: HTTP

    private func readRequest(_ client: Client) {
        let end: [UInt8] = [13, 10, 13, 10]
        guard let range = client.buffer.firstRange(of: end) else {
            if client.buffer.count > 16384 { drop(client) }
            return
        }
        let head = String(decoding: client.buffer[..<range.lowerBound], as: UTF8.self)
        client.buffer.removeSubrange(..<range.upperBound)

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return drop(client) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let components = URLComponents(string: String(requestLine[1]))
        let path = components?.path ?? "/"
        let query = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            upgrade(client, key: key, query: query)
            return
        }
        switch path {
        case "/join/\(room)":
            respond(client, status: "200 OK", type: "text/html; charset=utf-8", body: Data(joinPage().utf8))
        case "/download":
            if let zip = zippedApp() {
                respond(client, status: "200 OK", type: "application/zip", body: zip,
                        extra: "Content-Disposition: attachment; filename=\"ListenTogether.zip\"\r\n")
            } else {
                respond(client, status: "404 Not Found", type: "text/plain", body: Data("Not available\n".utf8))
            }
        case "/":
            respond(client, status: "200 OK", type: "text/plain", body: Data("ListenTogether room host\n".utf8))
        default:
            respond(client, status: "404 Not Found", type: "text/plain", body: Data("Not found\n".utf8))
        }
    }

    private func respond(_ client: Client, status: String, type: String, body: Data, extra: String = "") {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        client.conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.drop(client)
        })
    }

    private func upgrade(_ client: Client, key: String, query: [String: String]) {
        guard (query["room"] ?? "").lowercased() == room else {
            return respond(client, status: "403 Forbidden", type: "text/plain", body: Data("Wrong room\n".utf8))
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        client.conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        client.isWebSocket = true
        client.name = String((query["name"] ?? "Someone").prefix(40))

        let peers = clients.values.filter { $0.isWebSocket }
        if peers.count > maxPeers {
            send(json: ["type": "error", "message": "Room is full"], to: client)
            client.conn.send(content: frame(opcode: 0x8, payload: []), completion: .contentProcessed { [weak self] _ in self?.drop(client) })
            return
        }
        send(json: ["type": "welcome", "id": client.peerId, "server": Date().timeIntervalSince1970 * 1000, "peers": roster()], to: client)
        if let lastState { send(text: lastState, to: client) }
        broadcastPeers(except: client)
        if !client.buffer.isEmpty { readFrames(client) }
    }

    // MARK: WebSocket

    private func readFrames(_ client: Client) {
        while client.buffer.count >= 2 {
            let b = client.buffer
            let fin = b[0] & 0x80 != 0
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var length = Int(b[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard b.count >= 4 else { return }
                length = Int(b[2]) << 8 | Int(b[3])
                offset = 4
            } else if length == 127 {
                guard b.count >= 10 else { return }
                length = b[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            guard length <= 1_000_000 else { return drop(client) }
            var mask: [UInt8] = []
            if masked {
                guard b.count >= offset + 4 else { return }
                mask = Array(b[offset..<offset + 4])
                offset += 4
            }
            guard b.count >= offset + length else { return }
            var payload = Array(b[offset..<offset + length])
            if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            client.buffer.removeFirst(offset + length)

            switch opcode {
            case 0x0, 0x1, 0x2:
                client.fragments += payload
                if fin {
                    let message = client.fragments
                    client.fragments = []
                    handle(Data(message), from: client)
                }
            case 0x8:
                client.conn.send(content: frame(opcode: 0x8, payload: []), completion: .contentProcessed { [weak self] _ in self?.drop(client) })
                return
            case 0x9:
                client.conn.send(content: frame(opcode: 0xA, payload: payload), completion: .contentProcessed { _ in })
            default:
                break
            }
        }
    }

    private func handle(_ data: Data, from client: Client) {
        guard var msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = msg["type"] as? String else { return }
        switch type {
        case "ping":
            send(json: ["type": "pong", "t0": msg["t0"] ?? 0, "server": Date().timeIntervalSince1970 * 1000], to: client)
        case "state":
            msg["from"] = client.peerId
            msg["fromName"] = client.name
            guard let out = try? JSONSerialization.data(withJSONObject: msg) else { return }
            lastState = out
            for c in clients.values where c.isWebSocket && c !== client { send(text: out, to: c) }
        default:
            break
        }
    }

    private func roster() -> [[String: String]] {
        clients.values.filter { $0.isWebSocket }.map { ["id": $0.peerId, "name": $0.name] }
    }

    private func broadcastPeers(except skip: Client? = nil) {
        let peers = roster()
        if peers.isEmpty { lastState = nil }
        for c in clients.values where c.isWebSocket && c !== skip { send(json: ["type": "peers", "peers": peers], to: c) }
    }

    private func send(json: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(text: data, to: client)
    }

    private func send(text: Data, to client: Client) {
        client.conn.send(content: frame(opcode: 0x1, payload: [UInt8](text)), completion: .contentProcessed { _ in })
    }

    private func frame(opcode: UInt8, payload: [UInt8]) -> Data {
        var out: [UInt8] = [0x80 | opcode]
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            out.append(127)
            out += (0..<8).reversed().map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
        }
        return Data(out + payload)
    }

    // MARK: Invite page and download

    var inviteLink: URL? { publicURL?.appendingPathComponent("join").appendingPathComponent(room) }

    /// The link that opens (or launches) the app and joins this room.
    var appLink: URL? {
        guard let publicURL else { return nil }
        var c = URLComponents()
        c.scheme = "listentogether"
        c.host = "join"
        c.queryItems = [URLQueryItem(name: "relay", value: publicURL.absoluteString), URLQueryItem(name: "room", value: room)]
        return c.url
    }

    private func zippedApp() -> Data? {
        if let appZip { return appZip }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ListenTogether-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", bundle.path, out.path]
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        appZip = try? Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)
        return appZip
    }

    private func joinPage() -> String {
        let esc = { (s: String) in
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let open = esc(appLink?.absoluteString ?? "#")
        let invite = esc(inviteLink?.absoluteString ?? "")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Join \(esc(hostName)) on ListenTogether</title>
        <style>
        :root { color-scheme: light dark; --bg:#f6f5f2; --card:#fff; --ink:#1c1c1e; --muted:#6e6e73; --accent:#d4374a; --line:#e3e1dc; }
        @media (prefers-color-scheme: dark) { :root { --bg:#141416; --card:#1f1f22; --ink:#f2f2f4; --muted:#a0a0a8; --accent:#ff5a6e; --line:#2e2e33; } }
        * { box-sizing: border-box; }
        body { margin:0; background:var(--bg); color:var(--ink); font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
        main { max-width: 520px; margin: 0 auto; padding: 56px 16px; }
        .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:28px; }
        h1 { font-size:24px; line-height:1.25; margin:0 0 6px; }
        p { color:var(--muted); margin:0 0 20px; }
        a.button { display:block; text-align:center; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; padding:13px 16px; border-radius:12px; }
        ol { padding-left:20px; margin:24px 0 0; color:var(--muted); }
        li { margin-bottom:8px; }
        li a { color:var(--accent); }
        code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
        </style></head><body><main><div class="card">
        <h1>\(esc(hostName)) invited you to listen together</h1>
        <p>You'll hear the same song at the same moment, on Apple Music or Qobuz.</p>
        <a class="button" href="\(open)">Open in ListenTogether</a>
        <ol>
          <li>Don't have the app yet? <a href="/download">Download ListenTogether</a>, unzip it and open it.
              The first time, macOS blocks it: go to System Settings → Privacy &amp; Security and click <b>Open Anyway</b>.</li>
          <li>Pick Apple Music or Qobuz in the app. On Apple Music, click <b>Show Player → Sign In</b> once.</li>
          <li>Click <b>Open in ListenTogether</b> above, or paste this link into the app's Join tab:<br><code>\(invite)</code></li>
        </ol>
        </div></main></body></html>
        """
    }
}

/// Parses an invite: the https join link or the listentogether:// link.
enum InviteLink {
    static func parse(_ text: String) -> (relay: String, room: String)? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if c.scheme == "listentogether" {
            let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard let relay = q["relay"], let room = q["room"], !relay.isEmpty, !room.isEmpty else { return nil }
            return (relay, room)
        }
        guard c.scheme == "https" || c.scheme == "http", let host = c.host else { return nil }
        let parts = c.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "join" else { return nil }
        var base = "\(c.scheme!)://\(host)"
        if let port = c.port { base += ":\(port)" }
        return (base, String(parts[1]))
    }
}
