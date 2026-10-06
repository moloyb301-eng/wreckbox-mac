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

    init(id: String, name: String, kind: String, trackID: String?, playing: Bool, position: Double, duration: Double,
         updatedAt: Double, queue: [String]?, index: Int?, volume: Double?) {
        (self.id, self.name, self.kind, self.trackID, self.playing, self.position, self.duration) = (id, name, kind, trackID, playing, position, duration)
        (self.updatedAt, self.queue, self.index, self.volume) = (updatedAt, queue, index, volume)
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

    weak var store: LibraryStore?
    weak var server: PhoneSyncServer?

    let selfID = AccountAPI.deviceID
    private let player = AVPlayer()
    private var queue: [String] = []
    private var index = -1
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?
    private var tick: AnyCancellable?

    private init() {
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] n in
                guard let self, (n.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.next()
            }
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
    /// Devices seen in the last 10 minutes (this Mac always).
    var deviceList: [DeviceState] {
        let now = Date().timeIntervalSince1970 * 1000
        var list = devices.values.filter { $0.id == selfID || $0.playing || now - $0.updatedAt < 600_000 }
        if !list.contains(where: { $0.id == selfID }) { list.append(localState) }
        return list.sorted { ($0.id == selfID ? 0 : 1, $0.name) < ($1.id == selfID ? 0 : 1, $1.name) }
    }

    private var localState: DeviceState {
        let t = player.currentTime().seconds, d = player.currentItem?.duration.seconds ?? 0
        return DeviceState(id: selfID, name: Host.current().localizedName ?? "This Mac", kind: "mac",
                           trackID: index >= 0 && index < queue.count ? queue[index] : nil,
                           playing: player.rate > 0, position: t.isFinite ? t : 0, duration: d.isFinite ? d : 0,
                           updatedAt: Date().timeIntervalSince1970 * 1000, queue: queue, index: index, volume: Double(player.volume))
    }

    // MARK: controls (for whichever device is active)

    enum Action: String { case play, pause, toggle, next, previous, seek, volume }

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
        queue = playable.contains(id) ? playable : [id] + playable
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
        if from.id == selfID { player.pause() } else { send(from.id, "pause", [:]) }
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
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        if position > 0 { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        if playing { player.play(); activeID = selfID }
        updateNowPlaying()
        reportLocal()
    }

    private func local(_ action: Action, value: Double?) {
        switch action {
        case .play:
            if player.currentItem == nil, !queue.isEmpty { return load(at: max(index, 0), from: 0, playing: true) }
            pauseOthers(); player.play(); activeID = selfID
        case .pause: player.pause()
        case .toggle: return local(player.rate > 0 ? .pause : .play, value: nil)
        case .next: return next()
        case .previous:
            if player.currentTime().seconds > 3 || index <= 0 { player.seek(to: .zero) } else { return load(at: index - 1, from: 0, playing: player.rate > 0) }
        case .seek: player.seek(to: CMTime(seconds: value ?? 0, preferredTimescale: 600))
        case .volume: player.volume = Float(value ?? 1)
        }
        updateNowPlaying()
        reportLocal()
    }

    private func next() {
        if index + 1 < queue.count { load(at: index + 1, from: 0, playing: true) } else { player.pause(); reportLocal() }
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
            if s.id != selfID, player.rate > 0 { player.pause(); devices[selfID] = localState }
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
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds,
                                   MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
        let d = player.currentItem?.asset.duration.seconds ?? 0
        if d.isFinite, d > 0 { info[MPMediaItemPropertyPlaybackDuration] = d }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.rate > 0 ? .playing : .paused
    }
}

// MARK: - Now-playing bar (bottom of the main area)

/// Cover · title · ◀ ▶ ▶▶ · time · dot progress · time · device. Fixed columns so it lines up at every width.
struct NowPlayingBar: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var playback = Playback.shared

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
                    barButton("backward.fill", "Previous") { playback.control(.previous) }
                    Button { playback.control(.toggle) } label: {
                        Image(systemName: d.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .bold))
                            .frame(width: 44, height: 28).foregroundStyle(.black)
                            .background(Capsule().fill(.white))
                    }
                    .buttonStyle(.plain).help(d.playing ? "Pause" : "Play")
                    barButton("forward.fill", "Next") { playback.control(.next) }
                }
                .frame(width: 132)
                Text(Self.time(d.livePosition)).font(Theme.dot(11)).foregroundStyle(Theme.text3).frame(width: 40, alignment: .trailing)
                DotProgress(progress: d.duration > 0 ? d.livePosition / d.duration : 0) { f in
                    playback.control(.seek, value: f * d.duration)
                }
                Text(Self.time(d.duration)).font(Theme.dot(11)).foregroundStyle(Theme.text3).frame(width: 40, alignment: .leading)
                DevicePicker(playback: playback).frame(width: 170, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .glass(Theme.Radius.tile)
            .padding(.horizontal, 22).padding(.bottom, 10)
        }
    }

    private func barButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 34, height: 28)
                .foregroundStyle(Theme.text).contentShape(Rectangle())
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
