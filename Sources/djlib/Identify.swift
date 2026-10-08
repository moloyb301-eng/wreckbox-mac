import Foundation
import SwiftUI

// Identify: names tracks from their sound, like Shazam but for files. fpcalc (Chromaprint) fingerprints the audio,
// AcoustID looks the fingerprint up, MusicBrainz adds the ISRC, release year and genre, and the Cover Art Archive the
// cover. Nothing changes until the user accepts a suggestion: then the tags are written (Tagger), the file is renamed
// "Artist - Title.ext", and if it now matches a playlist track it's filed into the library like a download.
// Suggestions are kept in _cache/identify.json so they survive restarts.

struct IdentifyEntry: Codable, Identifiable {
    enum Status: String, Codable { case suggested, nomatch, accepted, skipped }
    var id: String { path }
    var path: String
    var status: Status
    var score: Double = 0
    var title: String?
    var artists: [String] = []
    var album: String?
    var year: String?
    var genre: String?
    var isrc: String?
    var cover: String?
    var recordingID: String?
    /// What the file said before (tags or file name), to show next to the suggestion.
    var was: String = ""
    var name: String { "\(artists.joined(separator: ", ")) – \(title ?? "")" }
}

@MainActor
final class Identifier: ObservableObject {
    static let shared = Identifier()

    @Published private(set) var entries: [String: IdentifyEntry] = [:]
    @Published private(set) var running = false
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var line = ""
    private var stop = false

    /// AcoustID application key (acoustid.org/new-application) — one key for the app, not per user.
    /// UserDefaults "acoustidKey" overrides it.
    static let builtInKey = "2HJPWXkWnz"
    static var key: String { UserDefaults.standard.string(forKey: "acoustidKey").flatMap { $0.isEmpty ? nil : $0 } ?? builtInKey }

    private static let file = libraryRoot.appendingPathComponent("_cache/identify.json")
    private static let userAgent = "WreckBox/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") ( https://github.com/moloyb301-eng/wreckbox-mac )"

    init() {
        if let d = try? Data(contentsOf: Self.file), let e = try? JSONDecoder().decode([String: IdentifyEntry].self, from: d) { entries = e }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.file, options: .atomic) }
    }

    var suggestions: [IdentifyEntry] {
        entries.values.filter { $0.status == .suggested && FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.score > $1.score }
    }
    var noMatch: Int { entries.values.filter { $0.status == .nomatch }.count }

    /// Files worth identifying: on this Mac, not linked to a playlist track, long enough to be a track, not tried yet.
    func candidates(_ store: LibraryStore) -> [FileAnalysis] {
        store.analysis.values.filter {
            $0.libraryTrackID == nil && ($0.durationSec ?? 0) >= LibraryScanner.minSeconds && entries[$0.path] == nil
                && FileManager.default.fileExists(atPath: $0.path)
        }.sorted { $0.path < $1.path }
    }

    func run(_ store: LibraryStore, paths: [String]? = nil) {
        guard !running else { return }
        let list = paths ?? candidates(store).map(\.path)
        guard !list.isEmpty else { return }
        running = true
        stop = false
        Task {
            for (i, path) in list.enumerated() where !stop {
                progress = (i + 1, list.count)
                line = URL(fileURLWithPath: path).lastPathComponent
                let a = store.analysis[path]
                let was = [a?.artist, a?.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " – ")
                var e = (try? await Self.identify(path)) ?? IdentifyEntry(path: path, status: .nomatch)
                e.was = was.isEmpty ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent : was
                entries[path] = e
                if i % 10 == 9 { save() }
            }
            save()
            running = false
            line = ""
            store.log("identify", nil, "Identify: \(suggestions.count) suggestions waiting, \(noMatch) not recognised")
        }
    }

    func cancel() { stop = true }

    func skip(_ e: IdentifyEntry) {
        entries[e.path]?.status = .skipped
        save()
    }

    /// Writes the tags, renames the file, and files it into the library if it's a playlist track.
    func accept(_ e: IdentifyEntry, _ store: LibraryStore) async {
        guard let title = e.title, !e.artists.isEmpty, FileManager.default.fileExists(atPath: e.path) else { return }
        let a = store.analysis[e.path]
        let job = TagJob(path: e.path, title: title, artists: e.artists, album: e.album, year: e.year, genre: e.genre,
                         bpm: a?.bpm, key: a?.key, isrc: e.isrc, cover: e.cover, comment: nil)
        let r = await Task.detached(priority: .userInitiated) { Tagger.write([job]) }.value
        if let r = r.first, !r.ok {
            store.log("identify", nil, "Couldn't tag \(URL(fileURLWithPath: e.path).lastPathComponent): \(r.error ?? "unknown error")")
            return
        }
        // "Artist - Title.ext" next to where it was.
        let old = URL(fileURLWithPath: e.path)
        let clean = { (s: String) in s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ") }
        var url = LibraryScanner.freeName(old.deletingLastPathComponent()
            .appendingPathComponent(clean("\(e.artists.joined(separator: ", ")) - \(title)")).appendingPathExtension(old.pathExtension))
        if (try? FileManager.default.moveItem(at: old, to: url)) == nil { url = old }
        entries[e.path] = nil
        var done = e
        done.path = url.path
        done.status = .accepted
        entries[url.path] = done
        save()
        store.analysis[e.path] = nil
        let rec = await readTrack(url)
        if let lib = store.library, let i = Matcher(tracks: lib.tracks).match(rec) {
            _ = await store.importDownloaded(url, source: "scan", trackID: lib.tracks[i].id)
        } else {
            store.analysis[url.path] = await Task.detached(priority: .utility) { Analyzer.analyze(rec, libraryTrackID: nil) }.value
        }
        Analyzer.saveCache(store.analysis)
        store.log("identify", nil, "\(e.was) → \(done.name)")
    }

    func acceptAll(_ store: LibraryStore, minScore: Double = 0.9) {
        let list = suggestions.filter { $0.score >= minScore }
        Task { for e in list { await accept(e, store) } }
    }

    // MARK: lookups

    /// fpcalc: the app's own copy when shipped, the vendored one in a developer build, else Homebrew's.
    nonisolated static var fpcalc: String? {
        [AppPaths.binDir?.appendingPathComponent("fpcalc").path,
         AppPaths.repo.appendingPathComponent("build/vendor/fpcalc/fpcalc").path,
         "/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc"]
            .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func fingerprint(_ path: String) -> (duration: Int, fp: String)? {
        guard let tool = fpcalc else { return nil }
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-json", "-length", "120", path]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let fp = j["fingerprint"] as? String,
              let d = j["duration"] as? Double else { return nil }
        return (Int(d.rounded()), fp)
    }

    private static var lastCall: [String: Date] = [:]

    /// Waits so calls to one service stay under its rate limit.
    private static func pace(_ service: String, _ gap: Double) async {
        let wait = gap - Date().timeIntervalSince(lastCall[service] ?? .distantPast)
        lastCall[service] = Date().addingTimeInterval(max(wait, 0))
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    static func identify(_ path: String) async throws -> IdentifyEntry {
        guard !key.isEmpty else { throw URLError(.userAuthenticationRequired) }
        guard let (duration, fp) = await Task.detached(priority: .utility, operation: { fingerprint(path) }).value else {
            return IdentifyEntry(path: path, status: .nomatch)
        }
        await pace("acoustid", 0.35)   // AcoustID: 3 requests a second
        var req = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "client=\(key)&meta=recordings+releasegroups+compress&duration=\(duration)&fingerprint=\(fp)".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any], j["status"] as? String == "ok" else {
            throw URLError(.badServerResponse)
        }
        // The best-scoring result that has a named recording.
        for r in (j["results"] as? [[String: Any]] ?? []).sorted(by: { ($0["score"] as? Double ?? 0) > ($1["score"] as? Double ?? 0) }) {
            let score = r["score"] as? Double ?? 0
            let recs = (r["recordings"] as? [[String: Any]] ?? []).filter { $0["title"] != nil && $0["artists"] != nil }
            guard score >= 0.5, let rec = recs.first else { continue }
            var e = IdentifyEntry(path: path, status: .suggested, score: score)
            e.title = rec["title"] as? String
            e.artists = (rec["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            e.recordingID = rec["id"] as? String
            // An album or single over a compilation.
            let groups = recs.flatMap { $0["releasegroups"] as? [[String: Any]] ?? [] }
            let rg = groups.first { ($0["secondarytypes"] as? [String] ?? []).isEmpty && ["Album", "Single", "EP"].contains($0["type"] as? String ?? "") }
                ?? groups.first
            e.album = rg?["title"] as? String
            if let id = rg?["id"] as? String { e.cover = "https://coverartarchive.org/release-group/\(id)/front-500" }
            if let id = e.recordingID { try? await musicBrainz(id, into: &e) }
            return e
        }
        return IdentifyEntry(path: path, status: .nomatch)
    }

    /// ISRC, first release year and top genre from MusicBrainz (1 request a second, with a User-Agent).
    private static func musicBrainz(_ id: String, into e: inout IdentifyEntry) async throws {
        await pace("musicbrainz", 1.1)
        var req = URLRequest(url: URL(string: "https://musicbrainz.org/ws/2/recording/\(id)?inc=isrcs+genres&fmt=json")!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        e.isrc = (j["isrcs"] as? [String])?.first
        if let d = j["first-release-date"] as? String, d.count >= 4 { e.year = String(d.prefix(4)) }
        e.genre = (j["genres"] as? [[String: Any]])?.max { ($0["count"] as? Int ?? 0) < ($1["count"] as? Int ?? 0) }?["name"] as? String
        e.genre = e.genre.map { $0.capitalized }
    }
}

// MARK: - Card

struct IdentifyCard: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var id = Identifier.shared
    @State private var busy: Set<String> = []

    var body: some View {
        let waiting = id.candidates(store).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Identify tracks").font(Theme.ui(18, .semibold))
                Spacer()
                if id.running {
                    PillButton(label: "Stop", icon: "stop.fill") { id.cancel() }
                } else {
                    PillButton(label: waiting == 0 ? "Nothing to identify" : "Identify \(waiting) tracks", icon: "waveform.badge.magnifyingglass",
                               style: .smart) { id.run(store) }
                        .disabled(waiting == 0 || Identifier.key.isEmpty || Identifier.fpcalc == nil)
                }
            }
            Text("Listens to each track that isn't in your playlists (like Shazam, but for files) and suggests its real title, "
                 + "artist, album, year, genre and cover. Nothing changes until you accept.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if Identifier.key.isEmpty {
                Text("Needs an AcoustID key — coming in the next update.").font(Theme.ui(12)).foregroundStyle(Theme.peach)
            } else if Identifier.fpcalc == nil {
                Text("The fingerprint tool (fpcalc) is missing from this copy of WreckBox.").font(Theme.ui(12)).foregroundStyle(Theme.peach)
            }
            if id.running { ProgressLine(done: id.progress.done, total: id.progress.total, label: id.line) }
            let list = id.suggestions
            if !list.isEmpty {
                HStack {
                    Text("\(list.count) suggestions" + (id.noMatch > 0 ? " · \(id.noMatch) not recognised" : ""))
                        .font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.text2)
                    Spacer()
                    let sure = list.filter { $0.score >= 0.9 }.count
                    if sure > 0 { PillButton(label: "Accept all \(sure) over 90%", icon: "checkmark.circle") { id.acceptAll(store) } }
                }
                ForEach(list.prefix(200)) { e in
                    HStack(spacing: 12) {
                        Text("\(Int(e.score * 100))%").font(Theme.dot(12)).foregroundStyle(e.score >= 0.9 ? Theme.lilac : Theme.peach)
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).font(Theme.ui(13.5, .semibold)).lineLimit(1)
                            Text([e.album, e.year, e.genre].compactMap { $0 }.joined(separator: " · ")).font(Theme.ui(11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                            Text("was: \(e.was)").font(Theme.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
                        }
                        Spacer()
                        PillButton(label: "Skip", icon: "xmark") { id.skip(e) }
                        PillButton(label: busy.contains(e.path) ? "Saving…" : "Accept", icon: "checkmark", style: .smart) {
                            busy.insert(e.path)
                            Task { await id.accept(e, store); busy.remove(e.path) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if !id.running, id.noMatch > 0 {
                Text("\(id.noMatch) tracks weren't recognised — AcoustID doesn't know them yet.").font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
            }
        }
        .padding(22)
        .glass(Theme.Radius.card)
    }
}
