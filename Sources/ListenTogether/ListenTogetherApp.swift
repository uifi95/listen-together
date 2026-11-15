import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // `ListenTogether --host-room [name]`: just host a room (relay + tunnel)
        // from the command line, without the player.
        if let i = CommandLine.arguments.firstIndex(of: "--host-room") {
            let name = CommandLine.arguments.dropFirst(i + 1).first ?? "Host"
            HostCLI.run(name: name)
        } else {
            ListenTogetherApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = MainActor.assumeIsolated { SyncEngine() }

    // Closing the window must not quit: the Apple Music player lives in this
    // app and a hosted room ends with it. The Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        LogFile.write("--- ListenTogether \(version) started")
        // `kill`, logout and Ctrl-C quit normally, so a hosted room's tunnel
        // is stopped instead of left running.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        // Test runs stay out of the way: no window in front.
        if SyncEngine.testDir != nil {
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) }; NSApp.hide(nil) }
        }
    }

    // listentogether://join?relay=…&room=… from an invite page.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { engine.join(link: url.absoluteString) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave a tunnel running after the app is gone.
        MainActor.assumeIsolated { engine.stopHosting() }
    }
}

struct ListenTogetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("ListenTogether", id: "main") {
            ContentView().environmentObject(appDelegate.engine)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Apple Music Player") { appDelegate.engine.apple.showWindow() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([LogFile.url]) }
            }
            CommandMenu("Volume") {
                Button("Apple Music Louder") { appDelegate.engine.nudgeAppleVolume(by: 0.1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Apple Music Quieter") { appDelegate.engine.nudgeAppleVolume(by: -0.1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }
    }
}

enum HostCLI {
    static func run(name: String) {
        let room = SyncEngine.hostedRoomCode()
        let server = HostServer(room: room, hostName: name)
        let tunnel = CloudflareTunnel()
        signal(SIGINT) { _ in exit(0) }
        signal(SIGTERM) { _ in exit(0) }
        atexit { cliTunnel?.stop() }
        cliTunnel = tunnel
        Task {
            do {
                let port = try await server.start()
                print("local:  ws://127.0.0.1:\(port)/?room=\(room)")
                let url = try await tunnel.start(localPort: port)
                _ = await CloudflareTunnel.waitUntilPublic(url)
                server.publicURL = url
                print("public: \(url.absoluteString)")
                print("room:   \(room)")
                print("invite: \(server.inviteLink?.absoluteString ?? "")")
                print("app:    \(server.appLink?.absoluteString ?? "")")
                fflush(stdout)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        withExtendedLifetime(server) { dispatchMain() }
    }
}

private var cliTunnel: CloudflareTunnel?
