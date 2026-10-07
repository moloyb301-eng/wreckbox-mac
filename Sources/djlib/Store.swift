import Foundation
import SwiftUI

// App state: which library tracks have a file on disk, where it lives, and a log of every change.
// Persisted to ~/Music/DJ Library/state.json; library.json and the BPM cache are read-only inputs.

enum TrackStatus: String, Codable { case missing, downloaded, ignored }

struct TrackState: Codable {
    var status: TrackStatus
    var localPath: String?
    var source: String?         // "scan", "soundcloud", "manual"
    var updatedAt: Date
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var event: String
    var trackID: String?
    var detail: String
}

struct AppState: Codable {
    var tracks: [String: TrackState] = [:]
    var log: [LogEntry] = []
    var genreOverrides: [String: String] = [:]   // track id → genre you set by hand
    var scanFolders: [String] = ["~/Music/DJ Library/Tracks", "~/Music/rekordbox", "~/Music/Music", "~/Documents/06 Music & DJ", "~/Downloads", "~/Desktop"]
    /// Download order: "playlist:<name>" / "genre:<name>", highest priority first.
    var downloadPriority: [String] = []
    /// When true, only tracks matched by `downloadPriority` are downloaded.
    var priorityOnly = false

    init() {}

    /// Tolerates state.json files written before a field existed (missing keys keep their defaults),
    /// so an older file never fails to load and then gets overwritten with an empty state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        tracks = try c.decodeIfPresent([String: TrackState].self, forKey: .tracks) ?? d.tracks
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? d.log
        genreOverrides = try c.decodeIfPresent([String: String].self, forKey: .genreOverrides) ?? d.genreOverrides
        scanFolders = try c.decodeIfPresent([String].self, forKey: .scanFolders) ?? d.scanFolders
        downloadPriority = try c.decodeIfPresent([String].self, forKey: .downloadPriority) ?? d.downloadPriority
        priorityOnly = try c.decodeIfPresent(Bool.self, forKey: .priorityOnly) ?? d.priorityOnly
    }
}

enum SidebarItem: Hashable {
    case home, all, missing, downloaded, ignored, files, playlist(String), genre(String), log, soundcloud, soulseek, youtube, search, queue, results, phone, friends
}

/// One track's entry in _soulseek/sync.json (written by slsk-sync).
struct SyncRecord {
    var status: String          // "done", "not_found", "failed"
    var lastTry: String         // ISO 8601, UTC
    var attempts: Int
    var reason: String?         // e.g. "no results", "312 files from 40 users, none matched"
    var queries: [String]
    var format: String?
    var bitrate: Int?
    var sizeBytes: Int?
    var source: String?         // "user:remote path"
    var file: String?

    init(_ d: [String: Any]) {
        status = d["status"] as? String ?? ""
        lastTry = d["last_try"] as? String ?? ""
        attempts = d["attempts"] as? Int ?? 0
        reason = d["reason"] as? String
        queries = d["queries"] as? [String] ?? []
        format = d["format"] as? String
        bitrate = d["bitrate"] as? Int
        sizeBytes = d["sizeBytes"] as? Int
        source = d["source"] as? String
        file = d["file"] as? String
    }

    var date: Date? { ISO8601DateFormatter().date(from: lastTry) }
}

struct SoulseekStatus {
    var done = 0, notFound = 0, failed = 0
    var records: [String: SyncRecord] = [:]     // by track id
    var overrides: [String: [String: String]] = [:]   // retry requests / custom queries not yet picked up
    var recent: [String] = []      // newest first
    var configured = false         // username + password present in config.toml
    var running = false
    /// A sync this app didn't start (terminal, or left over from an earlier run) that holds the lock.
    var externalPID: Int32?
}

struct Row: Identifiable {
    let track: LibraryTrack
    let state: TrackState?
    let bpm: BPMResult?             // from the 30 s preview
    let file: FileAnalysis?         // from the full local file (preferred)
    let genreInfo: GenreInfo?
    let genreOverride: String?
    var genre: String { genreOverride ?? genreInfo?.genre ?? "" }
    var genreHelp: String {
        if genreOverride != nil { return "set by you" }
        guard let g = genreInfo else { return "" }
        return g.confidence + " — " + g.sources.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "; ")
    }
    var genreUnsure: Bool { genreOverride == nil && genreInfo?.confidence != "verified" }
    var id: String { track.id }
    var status: TrackStatus { state?.status ?? .missing }
    var statusText: String { status.rawValue }
    var artist: String { track.artists.joined(separator: ", ") }
    var title: String { track.title }
    var bestBPM: Double? { file?.bpm ?? bpm?.bpm }
    var bpmValue: Double { bestBPM ?? -1 }
    var bpmText: String {
        guard let b = bestBPM else { return "" }
        let unsure = file?.bpm != nil ? file!.bpmAmbiguous : bpm?.ambiguous == true
        return String(format: "%.0f", b) + (unsure ? "?" : "")
    }
    var bpmSource: String {
        if file?.bpm != nil { return "from full-track analysis" }
        switch bpm?.source {
        case "deezer": return "from Deezer's catalogue"
        case "estimated": return "estimated from a 30-second preview"
        case let s?: return s
        case nil: return ""
        }
    }
    var camelot: String { file?.camelot ?? "" }
    var camelotSort: Int { camelotOrder(file?.camelot) }
    var keyUnsure: Bool { file?.keyUnsure ?? false }
    var energy: Double? { file?.energy }
    var energyValue: Double { energy ?? -1 }
    var addedValue: String { track.firstAdded ?? "" }
    var keyText: String { file?.key ?? "" }
    var playlistsText: String { track.playlists.joined(separator: ", ") }
    var durationText: String { track.durationMs.map { String(format: "%d:%02d", $0 / 60000, $0 / 1000 % 60) } ?? "" }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var library: Library? {
        didSet { trackIndex = Dictionary((library?.tracks ?? []).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }
    /// Track id → index in library.tracks, so lookups don't scan 1,500+ tracks each time.
    private var trackIndex: [String: Int] = [:]
    @Published var state = AppState()
    /// When library.json was last read, so a rebuild by the morning playlist sync is noticed.
    var libraryLoadedAt: Date?
    @Published var bpm: [String: BPMResult] = [:]
    @Published var analysis: [String: FileAnalysis] = [:]   // keyed by file path
    @Published var genres: [String: GenreInfo] = [:]
    @Published var sidebar: SidebarItem? = .home
    /// The track shown in the inspector (last clicked).
    @Published var focus: String?
    @Published var busy: String?
    @Published var loadError: String?
    /// The track the user is currently hunting for on SoundCloud; the next download is attached to it.
    @Published var pendingTrackID: String?

    nonisolated static let stateFile = libraryRoot.appendingPathComponent("state.json")
    nonisolated static let tracksDir = libraryRoot.appendingPathComponent("Tracks")
    nonisolated static let inboxDir = libraryRoot.appendingPathComponent("_inbox")

    init() { reload() }

    func reload() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        // First launch on a new Mac: an empty library to start from (playlists come from Spotify or links).
        let libFile = libraryRoot.appendingPathComponent("library.json")
        if !FileManager.default.fileExists(atPath: libFile.path) {
            try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            try? buildLibrary()
        }
        do {
            library = try dec.decode(Library.self, from: Data(contentsOf: libraryRoot.appendingPathComponent("library.json")))
            loadError = nil
        } catch {
            loadError = "Couldn't read library.json in Music/DJ Library. (\(error.localizedDescription))"
        }
        if let d = try? Data(contentsOf: Self.stateFile) {
            do {
                state = try dec.decode(AppState.self, from: d)
                stateUnreadable = false
            } catch {
                // Never overwrite a state file we couldn't read: keep a copy and block saves until it's fixed.
                stateUnreadable = true
                try? d.write(to: libraryRoot.appendingPathComponent("state.unreadable.json"))
                loadError = "Couldn't read state.json (a copy is in state.unreadable.json). Changes won't be saved. \(error.localizedDescription)"
            }
        }
        analysis = Analyzer.loadCache()
        genres = GenreTool.load()
        bpm = (try? JSONDecoder().decode([String: BPMResult].self, from: Data(contentsOf: BPMTool.cacheFile))) ?? [:]
    }

    /// Set when state.json exists but couldn't be decoded; saving would destroy it.
    private var stateUnreadable = false

    func save() {
        guard !stateUnreadable else { return }
        if state.log.count > 5000 { state.log.removeFirst(state.log.count - 5000) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(state).write(to: Self.stateFile, options: .atomic)
    }

    func log(_ event: String, _ trackID: String? = nil, _ detail: String) {
        state.log.append(LogEntry(date: Date(), event: event, trackID: trackID, detail: detail))
    }

    func track(_ id: String) -> LibraryTrack? {
        guard let i = trackIndex[id], let lib = library, i < lib.tracks.count else { return FriendShares.shared.track(id) }
        return lib.tracks[i]
    }

    // MARK: Queries

    func rows(_ item: SidebarItem?, search: String) -> [Row] {
        guard let lib = library else { return [] }
        var tracks = lib.tracks
        if case .playlist(let name) = item, let p = lib.playlists.first(where: { $0.name == name }) {
            var seen = Set<String>()   // a playlist can list the same track twice; rows need unique ids
            tracks = p.trackIDs.filter { seen.insert($0).inserted }.compactMap { track($0) }
        }
        var rows = tracks.map { t -> Row in
            let st = state.tracks[t.id]
            return Row(track: t, state: st, bpm: bpm[t.id], file: st?.localPath.flatMap { analysis[$0] },
                       genreInfo: genres[t.id], genreOverride: state.genreOverrides[t.id])
        }
        if case .genre(let g) = item { rows = rows.filter { $0.genre == g || (g == "Unknown" && $0.genre.isEmpty) } }
        switch item {
        case .missing: rows = rows.filter { $0.status == .missing }
        case .downloaded: rows = rows.filter { $0.status == .downloaded }
        case .ignored: rows = rows.filter { $0.status == .ignored }
        default: break
        }
        let q = normalized(search)
        if !q.isEmpty { rows = rows.filter { normalized("\($0.artist) \($0.title) \($0.track.album ?? "")").contains(q) } }
        return rows
    }

    func count(_ status: TrackStatus) -> Int {
        library?.tracks.filter { (state.tracks[$0.id]?.status ?? .missing) == status }.count ?? 0
    }

    // MARK: Actions

    func setStatus(_ ids: Set<String>, _ status: TrackStatus) {
        for id in ids {
            let old = state.tracks[id]
            state.tracks[id] = TrackState(status: status, localPath: status == .downloaded ? old?.localPath : nil, source: "manual", updatedAt: Date())
            log("marked \(status.rawValue)", id, describe(id))
        }
        save()
    }

    func genre(of id: String) -> String { state.genreOverrides[id] ?? genres[id]?.genre ?? "Unknown" }

    var genreCounts: [(String, Int)] {
        var c: [String: Int] = [:]
        library?.tracks.forEach { c[genre(of: $0.id), default: 0] += 1 }
        return c.sorted { $0.value > $1.value }
    }

    func setGenre(_ ids: Set<String>, _ g: String?) {
        for id in ids {
            state.genreOverrides[id] = g
            log(g == nil ? "genre reset" : "genre set", id, "\(describe(id)) → \(g ?? genres[id]?.genre ?? "Unknown")")
        }
        save()
    }

    func describe(_ id: String) -> String {
        guard let t = track(id) else { return id }
        return "\(t.artists.joined(separator: ", ")) – \(t.title)"
    }

    /// Reads tags from every audio file in the scan folders and links files to library tracks.
    /// Never moves or edits files; only records where each track lives.
    func rescan() async {
        guard let lib = library else { return }
        busy = "Scanning folders…"
        let matcher = Matcher(tracks: lib.tracks)
        var files: [URL] = []
        for f in state.scanFolders { files += findAudioFiles(in: URL(fileURLWithPath: (f as NSString).expandingTildeInPath)) }

        var found: [String: String] = [:]
        var analysed = 0
        for (i, url) in files.enumerated() {
            busy = "Scanning & analysing \(i + 1)/\(files.count)…"
            let rec = await readTrack(url)
            let idx = matcher.match(rec)
            if let idx, found[lib.tracks[idx].id] == nil { found[lib.tracks[idx].id] = url.path }
            let trackID = idx.map { lib.tracks[$0].id }
            if Analyzer.isFresh(analysis[url.path], rec) {
                analysis[url.path]?.libraryTrackID = trackID
            } else {
                analysis[url.path] = await Task.detached(priority: .utility) { Analyzer.analyze(rec, libraryTrackID: trackID) }.value
                analysed += 1
                if analysed % 20 == 0 { Analyzer.saveCache(analysis) }
            }
        }
        let seen = Set(files.map(\.path))
        analysis = analysis.filter { seen.contains($0.key) || FileManager.default.fileExists(atPath: $0.key) }
        Analyzer.saveCache(analysis)

        var added = 0, removed = 0
        for t in lib.tracks {
            let cur = state.tracks[t.id]
            if let path = found[t.id] {
                if cur?.status != .downloaded || cur?.localPath != path {
                    if cur?.status == .ignored { continue }
                    state.tracks[t.id] = TrackState(status: .downloaded, localPath: path, source: cur?.source == "manual" ? "manual" : "scan", updatedAt: Date())
                    log("found", t.id, "\(describe(t.id)) → \(path.replacingOccurrences(of: home.path, with: "~"))")
                    added += 1
                }
            } else if cur?.status == .downloaded, let p = cur?.localPath, !FileManager.default.fileExists(atPath: p) {
                state.tracks[t.id] = TrackState(status: .missing, localPath: nil, source: "scan", updatedAt: Date())
                log("file gone", t.id, "\(describe(t.id)) – \(p) no longer exists")
                removed += 1
            }
        }
        log("rescan", nil, "\(files.count) audio files read, \(analysed) analysed, \(added) newly matched, \(removed) gone")
        save()
        busy = nil
    }

    /// Called when a download lands in _inbox: match it, move it into Tracks/, record it.
    func importDownloaded(_ file: URL, source: String, trackID: String? = nil) async -> String {
        guard let lib = library else { return "no library loaded" }
        let rec = await readTrack(file)
        // Known target (slsk-sync names files after the track) → tags → the track being hunted on SoundCloud.
        let idx = trackID.flatMap { trackIndex[$0] } ?? Matcher(tracks: lib.tracks).match(rec)
            ?? (source == "soundcloud" ? pendingTrackID.flatMap { trackIndex[$0] } : nil)
        guard let i = idx else {
            log("unmatched download", nil, "\(file.lastPathComponent) kept in _inbox – no matching library track")
            save()
            return "Saved to _inbox (no matching track): \(file.lastPathComponent)"
        }
        let t = lib.tracks[i]
        var replacedCopy: (URL?, String)?
        // Best quality wins. A better YouTube copy (Premium after standard) replaces the old YouTube copy; otherwise a
        // second copy of a track (e.g. slsk-sync's lossless upgrade pass) replaces the old one only if it's better —
        // lossless over lossy, then bitrate — and is dropped if it isn't, so a track never has two files.
        if let old = state.tracks[t.id], old.status == .downloaded, let oldPath = old.localPath, oldPath != file.path,
           FileManager.default.fileExists(atPath: oldPath) {
            let newRank = source == "youtube" ? -1 : FileQuality.probe(file.path).map(Self.rank) ?? 0
            // A YouTube copy is Opus decoded to FLAC: only the quality cache knows it isn't really lossless.
            let oldRank = quality[oldPath].map(Self.rank)
                ?? (old.source == "youtube" ? 300 : FileQuality.probe(oldPath).map(Self.rank) ?? 0)
            if (source == "youtube" && old.source == "youtube") || (source != "youtube" && newRank > oldRank) {
                var trashed: NSURL?
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: oldPath), resultingItemURL: &trashed)
                replacedCopy = (trashed as URL?, oldPath)
                analysis[oldPath] = nil
                quality[oldPath] = nil
                log(source, t.id, source == "youtube" ? "replaced the earlier YouTube copy of \(describe(t.id))"
                                                      : "better copy replaces the old one of \(describe(t.id))")
            } else if source != "youtube" || old.source != "youtube" {
                try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
                log(source, t.id, "kept the existing copy of \(describe(t.id)) (as good or better than \(file.lastPathComponent))")
                save()
                return "Kept the existing copy of \(describe(t.id))"
            }
        }
        // Straight into its genre folder (Tracks/<genre>/), see Organise.swift.
        let dest = destination(for: t.id, ext: file.pathExtension)
            ?? Self.tracksDir.appendingPathComponent(t.fileName).appendingPathExtension(file.pathExtension.lowercased())
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: dest)
        } catch {
            // Put the copy it was replacing back, so a failed move never leaves the track without a file.
            if let (trashed, original) = replacedCopy, let trashed {
                try? FileManager.default.moveItem(at: trashed, to: URL(fileURLWithPath: original))
            }
            log("import failed", t.id, "\(file.lastPathComponent): \(error.localizedDescription)")
            save()
            return "Import failed: \(error.localizedDescription)"
        }
        state.tracks[t.id] = TrackState(status: .downloaded, localPath: dest.path, source: source, updatedAt: Date())
        save()   // record the move now: if the app quits during analysis, the file isn't left unaccounted for
        let moved = await readTrack(dest)
        analysis[dest.path] = await Task.detached(priority: .utility) { Analyzer.analyze(moved, libraryTrackID: t.id) }.value
        Analyzer.saveCache(analysis)
        log("downloaded", t.id, "\(describe(t.id)) via \(source) → Tracks/\(dest.lastPathComponent)")
        if pendingTrackID == t.id { pendingTrackID = nil }
        save()
        // Write the Spotify data, BPM, key and cover into the file itself (what Rekordbox reads).
        if let job = tagJob(t.id) {
            let results = await Task.detached(priority: .utility) { Tagger.write([job]) }.value
            if let r = results.first, r.ok, var a = analysis[dest.path],
               let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path) {
                a.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? a.sizeBytes
                a.modified = attrs[.modificationDate] as? Date
                analysis[dest.path] = a
                Analyzer.saveCache(analysis)
            } else if let r = results.first, !r.ok {
                log("tag failed", t.id, "\(dest.lastPathComponent): \(r.error ?? "unknown error")")
                save()
            }
        }
        return "Added \(describe(t.id))"
    }

    // MARK: Inbox watcher

    /// Files already offered to importDownloaded this session (path + size), so unmatched ones aren't retried every tick.
    private var inboxSeen: Set<String> = []
    private var inboxWatcher: Task<Void, Never>?

    /// Imports whatever lands in _inbox (e.g. from slsk-sync, which moves only finished files in),
    /// refreshes the Soulseek status, and relinks downloaded tracks whose files were moved.
    func startInboxWatcher() {
        guard inboxWatcher == nil else { return }
        writeQueue()
        if hasMovedFiles { Task { await rescan() } }
        inboxWatcher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.importInbox()
                self?.refreshSoulseek()
                self?.refreshYouTube()
                self?.reloadLibraryIfChanged()
                await self?.refreshQuality()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// A downloaded track whose file is no longer at its recorded path (moved or deleted).
    var hasMovedFiles: Bool {
        state.tracks.values.contains { $0.status == .downloaded && !FileManager.default.fileExists(atPath: $0.localPath ?? "") }
    }

    // MARK: Soulseek sync (soulseek/slsk-sync)

    @Published var soulseek = SoulseekStatus()
    @Published var youtube = YouTubeStatus()
    /// File path → format / bit rate, for the Quality column (see Quality.swift).
    @Published var quality: [String: FileQuality] = [:]
    /// (analysis count, sorted energies) for energyLevel().
    var energyRankCache: (count: Int, values: [Double])?
    var familyCountCache: (key: Int, counts: [String: Int])?
    /// The yt-fill process this app started (static so the app delegate can stop it on quit).
    nonisolated(unsafe) static var ytProcess: Process?
    /// The sync process this app started (static so the app delegate can stop it on quit).
    nonisolated(unsafe) static var syncProcess: Process?
    private var slskProcess: Process? {
        get { Self.syncProcess }
        set { Self.syncProcess = newValue }
    }

    func refreshSoulseek() {
        var s = SoulseekStatus()
        let sync = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.slskWorkDir.appendingPathComponent("sync.json")))) as? [String: [String: Any]] ?? [:]
        s.records = sync.mapValues(SyncRecord.init)
        s.overrides = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.slskWorkDir.appendingPathComponent("overrides.json")))) as? [String: [String: String]] ?? [:]
        for rec in sync.values {
            switch rec["status"] as? String {
            case "done": s.done += 1
            case "not_found": s.notFound += 1
            case "failed": s.failed += 1
            default: break
            }
        }
        s.recent = Self.tail(AppPaths.slskWorkDir.appendingPathComponent("sync.log"), lines: 40).reversed()
        let cfg = (try? String(contentsOf: AppPaths.slskConfig, encoding: .utf8)) ?? ""
        s.configured = cfg.range(of: #"(?m)^username\s*=\s*"[^"]+""#, options: .regularExpression) != nil
            && cfg.range(of: #"(?m)^password\s*=\s*"[^"]+""#, options: .regularExpression) != nil
        let holder = Self.syncLockHolder()
        let own = slskProcess?.isRunning == true ? slskProcess?.processIdentifier : nil
        if let holder, holder != own, holder > 0 { s.externalPID = holder }
        s.running = own != nil || s.externalPID != nil
        soulseek = s
    }

    /// Last `lines` lines of a text file, reading at most the final 64 KB (the sync log only grows).
    nonisolated static func tail(_ url: URL, lines: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return Array(text.split(separator: "\n").suffix(lines).map(String.init))
    }

    /// PID of the slsk-sync process holding _soulseek/sync.lock, or nil if none is running.
    nonisolated static func syncLockHolder() -> Int32? {
        let lock = AppPaths.slskWorkDir.appendingPathComponent("sync.lock").path
        let fd = open(lock, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { flock(fd, LOCK_UN); return nil }   // nobody holds it
        let text = (try? String(contentsOfFile: AppPaths.slskWorkDir.appendingPathComponent("sync.pid").path, encoding: .utf8)) ?? ""
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func startSoulseek() {
        guard slskProcess?.isRunning != true, Self.syncLockHolder() == nil, FileManager.default.isExecutableFile(atPath: AppPaths.slskSync.path) else { return }
        let p = Process()
        p.executableURL = AppPaths.slskSync
        p.arguments = ["run"]
        p.environment = AppPaths.toolEnvironment
        p.standardOutput = FileHandle.nullDevice   // it writes its own log
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in Task { @MainActor [weak self] in self?.refreshSoulseek() } }
        do {
            try p.run()
            slskProcess = p
            log("soulseek", nil, "sync started")
        } catch {
            log("soulseek", nil, "couldn't start slsk-sync: \(error.localizedDescription)")
        }
        save()
        refreshSoulseek()
    }

    /// Asks slsk-sync to try these tracks again on its next pass (it wakes within ~10 s when running),
    /// optionally with your own search words instead of "artist title".
    func retrySync(_ ids: [String], query: String? = nil) {
        let url = AppPaths.slskWorkDir.appendingPathComponent("overrides.json")
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: [String: String]] ?? [:]
        let now = ISO8601DateFormatter().string(from: Date())
        for id in ids {
            var o = all[id] ?? [:]
            o["retryAt"] = now
            if let q = query?.trimmingCharacters(in: .whitespaces) { o["query"] = q.isEmpty ? nil : q }
            all[id] = o
        }
        try? FileManager.default.createDirectory(at: AppPaths.slskWorkDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        log("soulseek", ids.count == 1 ? ids[0] : nil,
            ids.count == 1 ? "retry requested: \(describe(ids[0]))" + (query.map { " (search: \($0))" } ?? "") : "retry requested for \(ids.count) tracks")
        save()
        refreshSoulseek()
    }

    func stopSoulseek() {
        slskProcess?.terminate()   // kept until it exits, so Start can't launch a second copy meanwhile
        if let pid = soulseek.externalPID { kill(pid, SIGTERM) }
        log("soulseek", nil, "sync stopped")
        save()
        refreshSoulseek()
    }

    // MARK: Queries for the dashboard and inspector

    func row(_ id: String) -> Row? {
        guard let t = track(id) else { return nil }
        let st = state.tracks[id]
        return Row(track: t, state: st, bpm: bpm[id], file: st?.localPath.flatMap { analysis[$0] },
                   genreInfo: genres[id], genreOverride: state.genreOverrides[id])
    }

    var recentlyAdded: [Row] {
        (library?.tracks ?? []).sorted { ($0.firstAdded ?? "") > ($1.firstAdded ?? "") }.prefix(16).compactMap { row($0.id) }
    }

    func downloadedCount(_ p: LibraryPlaylist) -> Int {
        p.trackIDs.filter { state.tracks[$0]?.status == .downloaded }.count
    }

    /// Tracks you have that mix with `r`: compatible Camelot key and tempo within ±6% (also at half/double time).
    func mixesWith(_ r: Row) -> [Row] {
        guard let bpm = r.bestBPM, let key = r.camelot.isEmpty ? nil : r.camelot else { return [] }
        let keys = Analyzer.compatible(key)
        func tempoGap(_ b: Double) -> Double { [b, b * 2, b / 2].map { abs($0 - bpm) / bpm }.min() ?? 1 }
        return (library?.tracks ?? []).compactMap { t -> (Row, Double)? in
            guard t.id != r.id, let o = row(t.id), let ob = o.bestBPM, keys.contains(o.camelot) else { return nil }
            let gap = tempoGap(ob)
            return gap <= 0.06 ? (o, gap + (o.camelot == key ? 0 : 0.01)) : nil
        }
        .sorted { $0.1 < $1.1 }.prefix(12).map(\.0)
    }

    /// The file slsk-sync last delivered for a track (_soulseek/sync.json).
    static func slskDelivered(_ id: String) -> String? {
        let sync = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.slskWorkDir.appendingPathComponent("sync.json")))) as? [String: [String: Any]]
        return sync?[id]?["file"] as? String
    }

    /// How good a copy is: real lossless first (not a YouTube copy decoded to FLAC), then bitrate; Dolby surround last.
    static func rank(_ q: FileQuality) -> Int {
        if q.unplayable { return -2 }
        return q.lossless && !q.fromYouTube ? 100_000 + (q.bits ?? 16) : q.kbps ?? 0
    }

    func importInbox() async {
        guard library != nil, busy == nil else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.inboxDir, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])) ?? []
        guard let lib = library else { return }
        // slsk-sync names each file "<track.fileName>.ext" (or "… (2).ext"), so the target track is known exactly.
        let byFileName = Dictionary(lib.tracks.map { ($0.fileName, $0.id) }, uniquingKeysWith: { a, _ in a })
        for f in files where audioExtensions.contains(f.pathExtension.lowercased()) {
            // Files are kept in the format they came in (the user's rule: never convert to FLAC).
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard inboxSeen.insert("\(f.path)|\(size)").inserted else { continue }
            let stem = f.deletingPathExtension().lastPathComponent
            let base = stem.replacingOccurrences(of: #" \(\d+\)$"#, with: "", options: .regularExpression)
            let id = byFileName[stem] ?? byFileName[base]
            if let id, !youtube.got.contains(id) { refreshYouTube() }   // a yt-fill download that just landed
            // slsk-sync records the file it delivered; that wins over "YouTube got this track once" (lossless upgrades).
            let fromSlsk = id.map { Self.slskDelivered($0) == f.lastPathComponent } == true
            let source = !fromSlsk && id.map { youtube.got.contains($0) } == true ? "youtube" : "soulseek"
            _ = await importDownloaded(f, source: source, trackID: id)
        }
    }
}

// MARK: - Matching files to library tracks

struct Matcher {
    let tracks: [LibraryTrack]
    private var byISRC: [String: Int] = [:]
    private var byTitle: [String: [Int]] = [:]

    init(tracks: [LibraryTrack]) {
        self.tracks = tracks
        for (i, t) in tracks.enumerated() {
            if let isrc = t.isrc { byISRC[isrc] = i }
            byTitle[Self.cleanTitle(t.title), default: []].append(i)
        }
    }

    /// Strips noise that differs between Spotify titles and file tags/names, but keeps remix/edit names.
    static func cleanTitle(_ s: String) -> String {
        var t = s.lowercased()
        for pattern in [#"[\(\[]\s*(feat|ft|with)\.?\s[^\)\]]*[\)\]]"#, #"\s(feat|ft)\.?\s.*$"#,
                        #"[\(\[][^\)\]]*(official|visuali[sz]er|lyric|audio|video|free\s?d(ownload|l)|out now)[^\)\]]*[\)\]]"#,
                        #"[\(\[]\s*original mix\s*[\)\]]"#, #"\s-\s(remaster(ed)?|original mix).*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return normalized(t)
    }

    func match(_ r: TrackRecord) -> Int? {
        if let isrc = r.isrc, let i = byISRC[isrc] { return i }
        var guesses: [(artist: String, title: String)] = []
        if let a = r.artist, let t = r.title { guesses.append((a, t)) }
        // "Artist - Title.mp3" (or the reverse, which shows up in rips and promo files)
        let parts = (r.fileName as NSString).deletingPathExtension.components(separatedBy: " - ")
        if parts.count >= 2 {
            guesses.append((parts[0], parts.dropFirst().joined(separator: " - ")))
            guesses.append((parts.last!, parts.dropLast().joined(separator: " - ")))
        } else if let a = r.artist {
            guesses.append((a, parts[0]))
        }
        for g in guesses {
            let fileArtist = normalized(g.artist)
            let cands = (byTitle[Self.cleanTitle(g.title)] ?? []).filter { i in
                tracks[i].artists.contains { a in let n = normalized(a); return !n.isEmpty && (fileArtist.contains(n) || n.contains(fileArtist)) }
            }
            let best = cands.min { abs(dur($0, r)) < abs(dur($1, r)) }
            if let b = best, r.durationSec == nil || tracks[b].durationMs == nil || abs(dur(b, r)) < 8 { return b }
        }
        return nil
    }

    private func dur(_ i: Int, _ r: TrackRecord) -> Double {
        guard let a = tracks[i].durationMs, let b = r.durationSec else { return 0 }
        return Double(a) / 1000 - b
    }
}

/// Sort order around the Camelot wheel: 1A, 1B, 2A, 2B … 12B; unknown keys last.
func camelotOrder(_ c: String?) -> Int {
    guard let c, let n = Int(c.dropLast()) else { return 999 }
    return n * 2 + (c.hasSuffix("B") ? 1 : 0)
}

/// Shared BPM-range / key filter used by both tables.
struct MixFilter: Equatable {
    var minBPM = ""
    var maxBPM = ""
    var key = ""            // Camelot code, "" = any
    var compatible = true   // include harmonically compatible keys

    var isActive: Bool { !minBPM.isEmpty || !maxBPM.isEmpty || !key.isEmpty }

    func allows(bpm: Double?, camelot: String?) -> Bool {
        if let lo = Double(minBPM) { guard let b = bpm, b >= lo else { return false } }
        if let hi = Double(maxBPM) { guard let b = bpm, b <= hi else { return false } }
        if !key.isEmpty {
            guard let c = camelot else { return false }
            return compatible ? Analyzer.compatible(key).contains(c) : c == key
        }
        return true
    }
}
