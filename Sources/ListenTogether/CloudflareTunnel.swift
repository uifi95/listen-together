import Foundation

/// Runs a Cloudflare quick tunnel (`cloudflared tunnel --url …`) to a local
/// port and reports its public https://…trycloudflare.com address.
/// Quick tunnels need no Cloudflare account; the address changes each run.
final class CloudflareTunnel {
    private var process: Process?

    /// The copy inside the app (Contents/Helpers, added by build.sh) first,
    /// then an installed one (e.g. `swift run` builds have no bundle).
    static func findBinary() -> URL? {
        var dirs = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path,
                    "/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent("cloudflared") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func start(localPort: UInt16) async throws -> URL {
        guard let binary = Self.findBinary() else {
            throw PlayerError("Creating a room needs cloudflared, which is missing from this build. Install it with: brew install cloudflared")
        }
        Self.stopOrphans(of: binary)
        let p = Process()
        p.executableURL = binary
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        process = p

        let found = Found()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            found.add(String(decoding: data, as: UTF8.self))
        }
        p.terminationHandler = { _ in found.exited() }
        try p.run()

        // Wait for the address and for a registered edge connection.
        for _ in 0..<150 {
            let (url, ready, dead, log) = found.snapshot()
            if let url, ready { return url }
            if dead { throw PlayerError("cloudflared stopped: \(log.suffix(300))") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        stop()
        throw PlayerError("Cloudflare didn't open a tunnel in time. Check your internet connection.")
    }

    /// Waits until the tunnel's hostname resolves on public DNS. Handing out
    /// the link earlier lets the guest's resolver cache "no such host".
    static func waitUntilPublic(_ url: URL, timeout: TimeInterval = 60) async -> Bool {
        guard let host = url.host,
              let query = URL(string: "https://cloudflare-dns.com/dns-query?name=\(host)&type=A") else { return false }
        var req = URLRequest(url: query)
        req.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 5
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let answers = obj["Answer"] as? [[String: Any]], !answers.isEmpty {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Tunnels left running by an earlier copy of the app that didn't quit
    /// normally (killed, crashed): their parent is gone (adopted by launchd).
    /// Only this binary's tunnels, so a cloudflared started elsewhere is safe.
    private static func stopOrphans(of binary: URL) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        let pattern = "^" + NSRegularExpression.escapedPattern(for: binary.path) + " tunnel "
        pkill.arguments = ["-P", "1", "-f", pattern]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    deinit { stop() }

    private final class Found {
        private let lock = NSLock()
        private var log = ""
        private var url: URL?
        private var ready = false
        private var dead = false

        func add(_ text: String) {
            lock.withLock {
                log += text
                if log.count > 20000 { log = String(log.suffix(10000)) }
                if url == nil, let r = log.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) {
                    url = URL(string: String(log[r]))
                }
                if log.contains("Registered tunnel connection") { ready = true }
            }
        }
        func exited() { lock.withLock { dead = true } }
        func snapshot() -> (URL?, Bool, Bool, String) { lock.withLock { (url, ready, dead, log) } }
    }
}
