import AVFoundation
import AppKit
import Combine
import MediaPlayer
import SwiftUI

// Playback on every device, controlled from any of them (like Spotify Connect). This Mac plays its own files; phones
// stream from it. Every device reports what it plays to the hub here (POST /playback/state, through the phone-sync
// server), the hub sends everyone the list of devices as a "playback" event, and commands for a phone go out as a
// "playback-command" event the phone picks up from /poll. "Play on <device>" moves the queue and position over.

/// What one device is playing. Positions are seconds; `updatedAt` (ms since 1970) lets others run the clock on.
struct DeviceState: Codable, Equatable {
    var id: String
    var name: String
    var kind: String            // "mac" or "phone"
    var trackID: String?
    var playing = false
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Double = 0
    var queue: [String]?
    var index: Int?
    var volume: Double?
    var shuffle: Bool?

    init(id: String, name: String, kind: String, trackID: String?, playing: Bool, position: Double, duration: Double,
         updatedAt: Double, queue: [String]?, index: Int?, volume: Double?, shuffle: Bool? = nil) {
        (self.id, self.name, self.kind, self.trackID, self.playing, self.position, self.duration) = (id, name, kind, trackID, playing, position, duration)
        (self.updatedAt, self.queue, self.index, self.volume, self.shuffle) = (updatedAt, queue, index, volume, shuffle)
    }

    /// Phones leave out what they don't know (the hub stamps `updatedAt` itself), so only the id is required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Phone"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "phone"
        trackID = try c.decodeIfPresent(String.self, forKey: .trackID)
        playing = try c.decodeIfPresent(Bool.self, forKey: .playing) ?? false
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        queue = try c.decodeIfPresent([String].self, forKey: .queue)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle)
    }

    /// Where it is now, counting the time since it reported.
    var livePosition: Double {
        guard playing else { return position }
        let p = position + (Date().timeIntervalSince1970 * 1000 - updatedAt) / 1000
        return duration > 0 ? min(p, duration) : p
    }
}

@MainActor
final class Playback: ObservableObject {
    static let shared = Playback()

    @Published private(set) var devices: [String: DeviceState] = [:]
    /// The device that started playing most recently: the bar shows and controls it.
    @Published private(set) var activeID: String?
    @Published private(set) var error: String?
    /// The full-screen player (art or visualiser) is showing; the window goes full screen with it.
    @Published private(set) var fullScreen = false

    func setFullScreen(_ on: Bool) {
        fullScreen = on
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }),
           w.styleMask.contains(.fullScreen) != on {
            w.toggleFullScreen(nil)
        }
    }

    weak var store: LibraryStore?
    weak var server: PhoneSyncServer?

    let selfID = AccountAPI.deviceID
    let audio = MacAudio()
    private var queue: [String] = []
    /// The queue in its own order, to go back to when shuffle is turned off.
    private var ordered: [String] = []
    /// Shuffle: on → the tracks after the current one are in random order (remembered between launches).
    @Published private(set) var shuffle = UserDefaults.standard.bool(forKey: "shuffle")

    private func setShuffle(_ on: Bool) {
        shuffle = on
        UserDefaults.standard.set(on, forKey: "shuffle")
        guard index >= 0, index < queue.count else { return }
        let current = queue[index]
        if on {
            ordered = queue
            queue = Array(queue[...index]) + queue[(index + 1)...].shuffled()
        } else if !ordered.isEmpty {
            // Back to the playlist's order, carrying on from the current track.
            queue = ordered
            index = queue.firstIndex(of: current) ?? 0
        }
    }
    private var index = -1
    private var tick: AnyCancellable?

    private init() {
        audio.onEnd = { [weak self] in self?.next() }
        // The bar's clock (and controllers' estimates of a phone's position) move on their own.
        tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self, self.devices.values.contains(where: \.playing) else { return }
            self.expireSilent()
            self.objectWillChange.send()
        }
        setUpRemoteCommands()
    }

    // MARK: what the UI shows

    var active: DeviceState? { activeID.flatMap { devices[$0] } }
    /// Shuffle of whichever device the controls act on.
    var activeShuffle: Bool { (activeID == nil || activeID == selfID) ? shuffle : active?.shuffle ?? false }

    /// "Shuffle" on a playlist: shuffle on, start from a random track.
    func playShuffled(_ list: [String]) {
        let playable = list.filter { localPath($0) != nil }
        guard let first = playable.randomElement() else { return }
        if !shuffle { shuffle = true; UserDefaults.standard.set(true, forKey: "shuffle") }
        play(first, list: playable)
    }
    /// Devices seen in the last 10 minutes (this Mac always).
    var deviceList: [DeviceState] {
        let now = Date().timeIntervalSince1970 * 1000
        var list = devices.values.filter { $0.id == selfID || $0.playing || now - $0.updatedAt < 600_000 }
        if !list.contains(where: { $0.id == selfID }) { list.append(localState) }
        return list.sorted { ($0.id == selfID ? 0 : 1, $0.name) < ($1.id == selfID ? 0 : 1, $1.name) }
    }

    private var localState: DeviceState {
        DeviceState(id: selfID, name: Host.current().localizedName ?? "This Mac", kind: "mac",
                    trackID: index >= 0 && index < queue.count ? queue[index] : nil,
                    playing: audio.isPlaying, position: audio.position, duration: audio.duration,
                    updatedAt: Date().timeIntervalSince1970 * 1000, queue: queue, index: index, volume: audio.volume, shuffle: shuffle)
    }

    // MARK: controls (for whichever device is active)

    enum Action: String { case play, pause, toggle, next, previous, seek, volume, shuffle }

    func control(_ action: Action, value: Double? = nil, on device: String? = nil) {
        let target = device ?? activeID ?? selfID
        if target == selfID { return local(action, value: value) }
        var args: [String: Any] = [:]
        if let value { args["value"] = value }
        send(target, action.rawValue, args)
        // Show it straight away; the phone's report confirms it a moment later.
        if var d = devices[target] {
            switch action {
            case .play: d.playing = true
            case .pause: d.position = d.livePosition; d.playing = false
            case .toggle: d.position = d.livePosition; d.playing.toggle()
            case .seek: d.position = value ?? d.position
            case .volume: d.volume = value
            case .shuffle: d.shuffle = value.map { $0 > 0 } ?? !(d.shuffle ?? false)
            default: break
            }
            d.updatedAt = Date().timeIntervalSince1970 * 1000
            devices[target] = d
            publish()
        }
    }

    /// Plays `id` with `list` as the queue on this Mac (double-click in a track list).
    func play(_ id: String, list: [String]) {
        let playable = list.filter { localPath($0) != nil }
        ordered = playable.contains(id) ? playable : [id] + playable
        // Shuffle on: this track first, the rest in random order.
        queue = shuffle ? [id] + ordered.filter { $0 != id }.shuffled() : ordered
        index = queue.firstIndex(of: id) ?? 0
        pauseOthers()
        load(at: index, from: 0, playing: true)
    }

    /// Moves what the active device plays (queue, track, position) to `device`.
    func transfer(to device: String) {
        guard let from = active, from.id != device, let tid = from.trackID else { activeID = device; return publish() }
        let q = from.queue ?? [tid], i = from.index ?? q.firstIndex(of: tid) ?? 0, pos = from.livePosition, playing = from.playing
        if device == selfID {
            queue = q.filter { localPath($0) != nil }
            index = queue.firstIndex(of: tid) ?? 0
            load(at: index, from: pos, playing: playing)
        } else {
            send(device, "load", ["queue": q, "index": i, "position": pos, "playing": playing])
        }
        if from.id == selfID { audio.pause() } else { send(from.id, "pause", [:]) }
        activeID = device
        reportLocal()
    }

    // MARK: this Mac's player

    private func localPath(_ id: String) -> String? {
        guard let st = store?.state.tracks[id], st.status == .downloaded, let p = st.localPath,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }

    private func load(at i: Int, from position: Double, playing: Bool) {
        guard i >= 0, i < queue.count, let path = localPath(queue[i]) else { error = "Not on this Mac"; return }
        error = nil
        index = i
        do {
            try audio.load(path)
        } catch {
            self.error = "Can't play \((path as NSString).lastPathComponent): \(error.localizedDescription)"
            return reportLocal()
        }
        if position > 0 { audio.seek(position) }
        if playing { audio.play(); activeID = selfID }
        updateNowPlaying()
        reportLocal()
    }

    private func local(_ action: Action, value: Double?) {
        switch action {
        case .play:
            if !audio.hasFile, !queue.isEmpty { return load(at: max(index, 0), from: 0, playing: true) }
            pauseOthers(); audio.play(); activeID = selfID
        case .pause: audio.pause()
        case .toggle: return local(audio.isPlaying ? .pause : .play, value: nil)
        case .next: return next()
        case .previous:
            if audio.position > 3 || index <= 0 { audio.seek(0) } else { return load(at: index - 1, from: 0, playing: audio.isPlaying) }
        case .seek: audio.seek(value ?? 0)
        case .volume: audio.volume = value ?? 1
        case .shuffle: setShuffle(value.map { $0 > 0 } ?? !shuffle)
        }
        updateNowPlaying()
        reportLocal()
    }

    private func next() {
        if index + 1 < queue.count { load(at: index + 1, from: 0, playing: true) } else { audio.pause(); reportLocal() }
    }

    /// Starting here pauses whatever plays elsewhere (one device plays at a time, like Spotify).
    private func pauseOthers() {
        for d in devices.values where d.id != selfID && d.playing { send(d.id, "pause", [:]) }
    }

    private func reportLocal() {
        devices[selfID] = localState
        if localState.playing { activeID = selfID }
        publish()
    }

    // MARK: hub (called by the phone-sync server)

    /// A playing phone reports every 15 s; one silent for 45 s was closed or lost its connection: not playing.
    private func expireSilent() {
        let now = Date().timeIntervalSince1970 * 1000
        var changed = false
        for (id, d) in devices where id != selfID && d.playing && now - d.updatedAt > 45_000 {
            var d = d
            d.position = d.livePosition
            d.playing = false
            devices[id] = d
            changed = true
        }
        if changed { publish() }
    }

    /// A phone's report of what it plays.
    func update(_ s: DeviceState) {
        var s = s
        s.updatedAt = Date().timeIntervalSince1970 * 1000
        let started = s.playing && devices[s.id]?.playing != true
        devices[s.id] = s
        if started {
            activeID = s.id
            if s.id != selfID, audio.isPlaying { audio.pause(); devices[selfID] = localState }
        } else if activeID == nil {
            activeID = s.id
        }
        publish()
    }

    /// A command from a controller (a phone controlling this Mac, or another phone).
    func command(target: String, action: String, args: [String: Any]) {
        if action == "transfer" { return transfer(to: target) }
        if target == selfID, let a = Action(rawValue: action) { return local(a, value: args["value"] as? Double) }
        send(target, action, args)
    }

    var snapshot: [String: Any] {
        let list = deviceList.compactMap { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) }
        return ["devices": list, "active": activeID as Any, "server": selfID]
    }

    private func publish() { server?.publish("playback", snapshot) }
    private func send(_ target: String, _ action: String, _ args: [String: Any]) {
        server?.publish("playback-command", ["target": target, "action": action, "args": args])
    }

    // MARK: media keys, Control Centre

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.control(.play); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.control(.pause); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.control(.toggle); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.control(.next); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.control(.previous); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            self?.control(.seek, value: (e as? MPChangePlaybackPositionCommandEvent)?.positionTime); return .success
        }
    }

    private func updateNowPlaying() {
        guard index >= 0, index < queue.count, let t = store?.track(queue[index]) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artists.joined(separator: ", "),
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: audio.position,
                                   MPNowPlayingInfoPropertyPlaybackRate: audio.isPlaying ? 1.0 : 0.0]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        if audio.duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = audio.duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = audio.isPlaying ? .playing : .paused
    }
}

// MARK: - Now-playing bar (bottom of the main area)

/// Cover · title · ◀ ▶ ▶▶ · time · dot progress · time · device. Fixed columns so it lines up at every width.
struct NowPlayingBar: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var playback = Playback.shared
    @State private var showEQ = false

    static let height: CGFloat = 64

    var body: some View {
        if let d = playback.active, let id = d.trackID, let r = store.row(id) {
            HStack(spacing: 14) {
                ArtworkView(row: r, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.track.title).font(Theme.ui(13.5, .semibold)).lineLimit(1)
                    Text(r.track.artists.joined(separator: ", ")).font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
                }
                .frame(width: 220, alignment: .leading)
                HStack(spacing: 6) {
                    barButton("shuffle", playback.activeShuffle ? "Shuffle is on" : "Shuffle", lit: playback.activeShuffle) { playback.control(.shuffle) }
                    barButton("backward.fill", "Previous") { playback.control(.previous) }
                    Button { playback.control(.toggle) } label: {
                        Image(systemName: d.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                            .frame(width: 44, height: 28).foregroundStyle(.black)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain).help(d.playing ? "Pause" : "Play")
                    barButton("forward.fill", "Next") { playback.control(.next) }
                }
                .frame(width: 168)
                Text(Self.time(d.livePosition)).font(Theme.dot(11)).foregroundStyle(Theme.text3).frame(width: 40, alignment: .trailing)
                DotProgress(progress: d.duration > 0 ? d.livePosition / d.duration : 0) { f in
                    playback.control(.seek, value: f * d.duration)
                }
                Text(Self.time(d.duration)).font(Theme.dot(11)).foregroundStyle(Theme.text3).frame(width: 40, alignment: .leading)
                HStack(spacing: 2) {
                    barButton("slider.vertical.3", "Equaliser") { showEQ.toggle() }
                        .popover(isPresented: $showEQ, arrowEdge: .top) { EQPanel().padding(16).frame(width: 440) }
                    barButton("arrow.up.left.and.arrow.down.right", "Full screen — album art or visualiser") { playback.setFullScreen(true) }
                    barButton("pip", "Mini player on the desktop") { MiniPlayerWindow.shared.toggle(store: store) }
                }
                .frame(width: 108)
                DevicePicker(playback: playback).frame(width: 170, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .glass(Theme.Radius.tile)
            .padding(.horizontal, 22).padding(.bottom, 10)
        }
    }

    private func barButton(_ icon: String, _ help: String, lit: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 34, height: 28)
                .foregroundStyle(lit ? Theme.lilac : Theme.text).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    static func time(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        return "\(Int(s) / 60):" + String(format: "%02d", Int(s) % 60)
    }
}

/// A row of square dots, lit up to the position; click or drag to seek.
struct DotProgress: View {
    var progress: Double
    var seek: (Double) -> Void
    private let dot: CGFloat = 3, gap: CGFloat = 2

    var body: some View {
        GeometryReader { g in
            let n = max(1, Int((g.size.width + gap) / (dot + gap)))
            let lit = Int((min(1, max(0, progress)) * Double(n)).rounded(.down))
            HStack(spacing: gap) {
                ForEach(0..<n, id: \.self) { i in
                    Rectangle().fill(i < lit ? Theme.lilac : Theme.hairline.opacity(2.5)).frame(width: dot, height: dot)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in seek(min(1, max(0, v.location.x / g.size.width))) })
        }
        .frame(height: 14)
    }
}

/// Where the music plays: this Mac or a phone. Picking one moves the music there.
struct DevicePicker: View {
    @ObservedObject var playback: Playback

    var body: some View {
        Menu {
            ForEach(playback.deviceList, id: \.id) { d in
                Button {
                    playback.transfer(to: d.id)
                } label: {
                    Label(d.id == playback.selfID ? "This Mac" : d.name + (d.playing ? " · playing" : ""),
                          systemImage: d.kind == "phone" ? "iphone" : "laptopcomputer")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: playback.active?.kind == "phone" ? "iphone" : "hifispeaker").font(.system(size: 12, weight: .semibold))
                Text(playback.activeID == playback.selfID || playback.activeID == nil ? "This Mac" : playback.active?.name ?? "")
                    .font(Theme.ui(12, .semibold)).lineLimit(1)
            }
            .foregroundStyle(playback.activeID == playback.selfID ? Theme.text : Theme.lilac)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Play on another device")
    }
}
