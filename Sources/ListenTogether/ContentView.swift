import SwiftUI

struct ContentView: View {
    @EnvironmentObject var engine: SyncEngine
    @State private var scrubbing: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            setup
            Divider()
            nowPlaying
            Divider()
            upNext
            Divider()
            activity
        }
        .padding(18)
        .frame(width: 440)
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("I listen on", selection: $engine.service) {
                ForEach(MusicService.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 6) {
                Circle().fill(engine.playerConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(engine.playerStatus).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if engine.service == .appleMusic {
                    Button("Show Player") { engine.apple.showWindow() }.controlSize(.small)
                }
            }
            if engine.needsAppleSignIn {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Sign in to Apple Music for full songs (otherwise 30-second previews).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sign In") { engine.signInToAppleMusic() }
                }
            }

            HStack {
                Text("Your name").foregroundStyle(.secondary)
                TextField("Name", text: $engine.name).textFieldStyle(.roundedBorder)
            }
            .disabled(engine.isRelayActive || engine.isHosting)

            if engine.isRelayActive || engine.isHosting {
                inRoom
            } else {
                roomPicker
            }
        }
    }

    private enum RoomMode: String, CaseIterable, Identifiable {
        case create = "Create Room", join = "Join with Link", custom = "Own Relay"
        var id: String { rawValue }
    }
    @AppStorage("roomMode", store: SyncEngine.defaults) private var roomMode: RoomMode = .create
    @State private var inviteText = ""

    private var roomPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Room", selection: $roomMode) {
                ForEach(RoomMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch roomMode {
            case .create:
                Text("Host a room on this Mac and send the link. Your friend can download the app from the same link.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed(let why) = engine.host {
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if engine.cloudflaredInstalled {
                    Button("Create Room") { engine.createRoom() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    HStack {
                        Text("Creating a room needs cloudflared:").font(.callout)
                        Text("brew install cloudflared").font(.callout.monospaced()).textSelection(.enabled)
                        Button { copy("brew install cloudflared") } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy command")
                    }
                }
            case .join:
                HStack {
                    TextField("Paste invite link", text: $inviteText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if engine.join(link: inviteText) { inviteText = "" } }
                    Button("Join") { if engine.join(link: inviteText) { inviteText = "" } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(InviteLink.parse(inviteText) == nil)
                }
            case .custom:
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Relay").foregroundStyle(.secondary)
                        TextField("wss://your-relay.example.com", text: $engine.relayURL)
                    }
                    GridRow {
                        Text("Room").foregroundStyle(.secondary)
                        HStack {
                            TextField("room-code", text: $engine.room)
                            Button { engine.room = SyncEngine.randomRoom() } label: { Image(systemName: "dice") }
                                .help("New random room code")
                        }
                    }
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Join Room") { engine.connectRelay() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(engine.room.count < 3 || engine.relayURL.isEmpty)
                }
            }
        }
    }

    private var inRoom: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch engine.host {
            case .starting(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout)
                }
            case .running(let invite):
                Text("Invite link").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(invite.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Link") { copy(invite.absoluteString) }
                }
                Text("The link works while this app stays open.")
                    .font(.caption).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            HStack {
                relayBadge
                Spacer()
                Button(engine.isHosting ? "Close Room" : "Leave Room") { engine.disconnectRelay() }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var relayBadge: some View {
        let (color, text): (Color, String) = {
            switch engine.relayStatus {
            case .disconnected: return (.gray, "Not in a room")
            case .connecting: return (.orange, "Connecting…")
            case .failed(let why): return (.red, "Reconnecting — \(why)")
            case .connected:
                let others = engine.partners.map(\.name)
                return (.green, others.isEmpty ? "In room, waiting for your partner" : "Listening with \(others.joined(separator: ", "))")
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout).lineLimit(1)
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = engine.local.track {
                Text(t.title).font(.headline).lineLimit(2)
                Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " — "))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)

                let duration = Double(max(t.durationMs, 1))
                Slider(value: Binding(
                    get: { scrubbing ?? Double(min(engine.local.positionMs, t.durationMs)) },
                    set: { scrubbing = $0 }
                ), in: 0...duration) { editing in
                    if !editing, let v = scrubbing {
                        engine.seek(toMs: Int(v))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { scrubbing = nil }
                    }
                }
                HStack {
                    Text(SyncEngine.time(Int(scrubbing ?? Double(engine.local.positionMs))))
                    Spacer()
                    Button { engine.togglePlay() } label: {
                        Image(systemName: engine.local.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.space, modifiers: [])
                    .overlay(alignment: .trailing) {
                        Button { engine.skipToNext() } label: {
                            Image(systemName: "forward.end.fill").font(.system(size: 16))
                        }
                        .buttonStyle(.plain)
                        .disabled(engine.queue.isEmpty)
                        .opacity(engine.queue.isEmpty ? 0.35 : 1)
                        .help("Play the next song in the shared queue")
                        .offset(x: 36)
                    }
                    Spacer()
                    Text(SyncEngine.time(t.durationMs))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                if engine.service == .appleMusic { volumeControl }
            } else {
                Text("Nothing playing").font(.headline)
                Text(engine.service == .qobuz
                     ? "Start a song in Qobuz. Your partner will follow."
                     : "Click Show Player, then pick a song in Apple Music. Your partner will follow.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !engine.queue.isEmpty {
                    Button { engine.skipToNext() } label: {
                        Label("Play Up Next", systemImage: "play.circle.fill")
                    }
                    .help("Play the first song in the shared queue for everyone")
                }
                if engine.service == .appleMusic { volumeControl }
            }
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Button { engine.setAppleVolume(engine.appleVolume > 0 ? 0 : 0.8) } label: {
                Image(systemName: engine.appleVolume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(engine.appleVolume == 0 ? "Unmute" : "Mute")
            Slider(value: Binding(get: { engine.appleVolume }, set: { engine.setAppleVolume($0) }), in: 0...1)
                .help("Apple Music volume (⌘↑ / ⌘↓)")
            Image(systemName: "speaker.wave.3.fill")
            Text("\(Int((engine.appleVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Up next

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Up Next").font(.caption).foregroundStyle(.secondary)
                if !engine.queue.isEmpty {
                    Text("\(engine.queue.items.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") { engine.clearQueue() }.buttonStyle(.link).font(.caption)
                }
            }
            if engine.queue.isEmpty {
                Text("Use Add to Queue or Play Next in \(engine.service.displayName). The songs show up here for both of you and play in order.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(engine.queue.items.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, number: index + 1)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }

    private func queueRow(_ item: QueueItem, number: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(number)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 18, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.track.title).font(.callout).lineLimit(1)
                Text("\(item.track.artist) · \(item.playNext ? "Play Next" : "queued") by \(item.addedBy)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(SyncEngine.time(item.track.durationMs)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            Button { engine.playNow(item) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).help("Play now for everyone")
            Button { engine.removeFromQueue(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Remove from the queue")
        }
        .padding(.vertical, 4)
    }

    // MARK: Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity").font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(engine.log) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(line.date, style: .time).foregroundStyle(.tertiary)
                                Text(line.text)
                            }
                            .font(.caption)
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .onChange(of: engine.log.count) {
                    if let last = engine.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
