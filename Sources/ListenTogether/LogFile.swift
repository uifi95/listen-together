import Foundation

/// ~/Library/Logs/ListenTogether/ListenTogether.log: the activity lines and
/// a trace of syncing, for debugging after the fact. Kept under ~1 MB
/// (the previous file is kept as ListenTogether.old.log).
enum LogFile {
    private static let queue = DispatchQueue(label: "app.listentogether.log")
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ListenTogether", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = ProcessInfo.processInfo.environment["LT_PROFILE"].map { "-\($0)" } ?? ""
        return dir.appendingPathComponent("ListenTogether\(profile).log")
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                let old = url.deletingPathExtension().appendingPathExtension("old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
