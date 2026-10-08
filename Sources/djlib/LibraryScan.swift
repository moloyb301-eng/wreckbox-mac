import AppKit
import SwiftUI

// Scan this Mac: walks the home folder for music outside WreckBox (Downloads, Desktop, old iTunes / Rekordbox folders,
// AirDrop, …), shows what it found per folder, and moves the picked folders' tracks into the library — the ones that
// match a library track go into Tracks/<genre>/ like any download (the better copy wins, see importDownloaded), the
// rest into Tracks/Found/, where Identify (Identify.swift) can name them. Rekordbox and Apple Music folders start
// unticked: those apps point at the files where they are.

struct ScanFind: Identifiable {
    var id: String { path }
    let path: String
    let group: String           // the folder it's grouped under, relative to home ("Downloads", "Music/rekordbox")
    let trackID: String?        // the library track it matches
    let label: String           // "Artist – Title" or the file name
    let size: Int64
}

struct ScanGroup: Identifiable {
    var id: String { name }
    let name: String
    var finds: [ScanFind]
    var matched: Int { finds.filter { $0.trackID != nil }.count }
    var size: Int64 { finds.reduce(0) { $0 + $1.size } }
    /// Other apps' libraries: moving their files breaks them, so they start unticked.
    var otherAppLibrary: Bool {
        let n = name.lowercased()
        return n.contains("rekordbox") || n.hasPrefix("music/music") || n.hasPrefix("music/itunes") || n.contains("serato")
            || n.contains("pioneerdj") || n.contains("traktor") || n.contains("virtualdj")
    }
}

@MainActor
final class LibraryScanner: ObservableObject {
    static let shared = LibraryScanner()

    enum Phase: Equatable { case idle, scanning, review, moving, done }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var groups: [ScanGroup] = []
    @Published var picked: Set<String> = []
    @Published private(set) var progress = (done: 0, total: 0)
    @Published private(set) var line = ""

    static let foundDir = LibraryStore.tracksDir.appendingPathComponent("Found")
    /// Shorter than this is a sample, ringtone or voice note, not a track.
    static let minSeconds = 45.0
    private static let skipDirs: Set<String> = ["Library", "Applications", "Developer", "node_modules", "Pictures", "Movies"]

    func scan(_ store: LibraryStore) {
        guard phase != .scanning, phase != .moving, let lib = store.library else { return }
        phase = .scanning
        groups = []
        line = "Looking through your folders…"
        Task {
            let urls = await Task.detached(priority: .userInitiated) { Self.findOutside() }.value
            let matcher = Matcher(tracks: lib.tracks)
            var byGroup: [String: [ScanFind]] = [:]
            progress = (0, urls.count)
            for (i, url) in urls.enumerated() {
                progress = (i + 1, urls.count)
                line = url.lastPathComponent
                let rec = await readTrack(url)
                if let d = rec.durationSec, d < Self.minSeconds { continue }
                if rec.durationSec == nil, rec.sizeBytes < 1_000_000 { continue }
                let idx = matcher.match(rec)
                let label = [rec.artist, rec.title].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " – ")
                byGroup[Self.group(of: url), default: []].append(ScanFind(
                    path: url.path, group: Self.group(of: url), trackID: idx.map { lib.tracks[$0].id },
                    label: label.isEmpty ? url.deletingPathExtension().lastPathComponent : label, size: rec.sizeBytes))
            }
            groups = byGroup.map { ScanGroup(name: $0.key, finds: $0.value.sorted { $0.label < $1.label }) }
                .sorted { $0.finds.count > $1.finds.count }
            picked = Set(groups.filter { !$0.otherAppLibrary }.map(\.name))
            line = ""
            phase = .review
            store.log("scan", nil, "Scan found \(groups.reduce(0) { $0 + $1.finds.count }) tracks outside WreckBox in \(groups.count) folders")
        }
    }

    /// Moves the picked folders' tracks into the library.
    func move(_ store: LibraryStore) {
        guard phase == .review else { return }
        let finds = groups.filter { picked.contains($0.name) }.flatMap(\.finds)
        guard !finds.isEmpty else { return }
        phase = .moving
        Task {
            var linked = 0, found = 0, kept = 0, failed = 0
            for (i, f) in finds.enumerated() {
                progress = (i + 1, finds.count)
                line = f.label
                let url = URL(fileURLWithPath: f.path)
                guard FileManager.default.fileExists(atPath: f.path) else { continue }
                if let id = f.trackID {
                    let r = await store.importDownloaded(url, source: "scan", trackID: id)
                    if r.hasPrefix("Added") { linked += 1 } else if r.hasPrefix("Kept") { kept += 1 } else { failed += 1 }
                } else if let dest = Self.moveToFound(url) {
                    let rec = await readTrack(dest)
                    store.analysis[dest.path] = await Task.detached(priority: .utility) { Analyzer.analyze(rec, libraryTrackID: nil) }.value
                    found += 1
                } else {
                    failed += 1
                }
                store.analysis[f.path] = nil
            }
            Analyzer.saveCache(store.analysis)
            line = "\(linked) library tracks filed · \(found) other tracks in Tracks/Found"
                + (kept > 0 ? " · \(kept) duplicates moved to the Bin (the library copy was as good or better)" : "")
                + (failed > 0 ? " · \(failed) couldn't be moved" : "")
            store.log("scan", nil, "Scan moved tracks in: " + line)
            groups = []
            phase = .done
        }
    }

    func reset() { if phase == .review || phase == .done { phase = .idle; groups = []; line = "" } }

    // MARK: files

    /// Audio files under home that aren't already in WreckBox's own folder.
    nonisolated static func findOutside() -> [URL] {
        let root = libraryRoot.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: home, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                let top = e.level == 1
                if url.standardizedFileURL.path == root || v?.isPackage == true || skipNames.contains(url.lastPathComponent)
                    || (top && skipDirs.contains(url.lastPathComponent)) || url.path.hasPrefix(outDir.path) {
                    e.skipDescendants()
                }
                continue
            }
            if audioExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        return files
    }

    /// "Downloads", "Music/rekordbox", "Documents/06 Music & DJ": the first two folders under home.
    nonisolated static func group(of url: URL) -> String {
        let rel = url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "")
            .split(separator: "/").prefix(2).joined(separator: "/")
        return rel.isEmpty ? "Home" : rel
    }

    /// Moves a file into Tracks/Found/ under a free name.
    nonisolated static func moveToFound(_ url: URL) -> URL? {
        try? FileManager.default.createDirectory(at: foundDir, withIntermediateDirectories: true)
        let dest = freeName(foundDir.appendingPathComponent(url.lastPathComponent))
        do { try FileManager.default.moveItem(at: url, to: dest); return dest } catch { return nil }
    }

    /// `url`, or "name (2).ext", "name (3).ext"… if it's taken.
    nonisolated static func freeName(_ url: URL) -> URL {
        var dest = url, n = 2
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension, dir = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return dest
    }
}

// MARK: - Page

struct ScanView: View {
    @EnvironmentObject var store: LibraryStore
    @ObservedObject var scanner = LibraryScanner.shared
    @ObservedObject var identifier = Identifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(eyebrow: "Tools", title: "Scan & identify",
                       subtitle: "Bring every track on this Mac into WreckBox, and name the ones nobody tagged") { EmptyView() }
            Scroller {
                VStack(alignment: .leading, spacing: 16) {
                    scanCard
                    IdentifyCard()
                }
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
        .padding(.horizontal, 22).padding(.top, 34).padding(.bottom, 10)
    }

    private var scanCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Scan this Mac").font(Theme.ui(18, .semibold))
                Spacer()
                switch scanner.phase {
                case .idle, .done:
                    PillButton(label: "Scan this Mac", icon: "magnifyingglass", style: .smart) { scanner.scan(store) }
                case .review:
                    PillButton(label: "Cancel", icon: "xmark") { scanner.reset() }
                    PillButton(label: "Move \(pickedCount) tracks into WreckBox", icon: "tray.and.arrow.down", style: .smart) { scanner.move(store) }
                case .scanning, .moving:
                    EmptyView()
                }
            }
            Text("Looks through your home folder (not system folders or apps) for music that isn't in WreckBox yet. Tracks "
                 + "from your playlists are filed into Tracks/<genre>, the rest go to Tracks/Found. If WreckBox already has a "
                 + "track, the better copy stays and the other goes to the Bin.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if scanner.phase == .scanning || scanner.phase == .moving {
                ProgressLine(done: scanner.progress.done, total: scanner.progress.total,
                             label: (scanner.phase == .scanning ? "Reading " : "Moving ") + scanner.line)
            } else if scanner.phase == .done, !scanner.line.isEmpty {
                Text(scanner.line).font(Theme.ui(12.5, .semibold)).foregroundStyle(Theme.lilac)
            }
            if scanner.phase == .review {
                if scanner.groups.isEmpty {
                    Text("Nothing found outside WreckBox — everything's already in.").font(Theme.ui(13)).foregroundStyle(Theme.text2)
                }
                ForEach(scanner.groups) { g in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { scanner.picked.contains(g.name) },
                                                 set: { if $0 { scanner.picked.insert(g.name) } else { scanner.picked.remove(g.name) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(Theme.ui(13.5, .semibold))
                            Text("\(g.finds.count) tracks · \(g.matched) in your playlists · \(ByteCountFormatter.string(fromByteCount: g.size, countStyle: .file))"
                                 + (g.otherAppLibrary ? " · another app's library — moving breaks it there" : ""))
                                .font(Theme.ui(11.5)).foregroundStyle(g.otherAppLibrary ? Theme.peach : Theme.text3)
                        }
                        Spacer()
                        Button("Show") {
                            NSWorkspace.shared.open(home.appendingPathComponent(g.name == "Home" ? "" : g.name))
                        }.buttonStyle(.plain).font(Theme.ui(12)).foregroundStyle(Theme.text2)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(22)
        .glass(Theme.Radius.card)
    }

    private var pickedCount: Int { scanner.groups.filter { scanner.picked.contains($0.name) }.reduce(0) { $0 + $1.finds.count } }
}

/// A thin progress bar with a count and what it's on.
struct ProgressLine: View {
    let done: Int
    let total: Int
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.text3.opacity(0.25))
                    Capsule().fill(Theme.lilac).frame(width: total == 0 ? 0 : g.size.width * CGFloat(done) / CGFloat(total))
                }
            }
            .frame(height: 4)
            Text("\(done) / \(total) · \(label)").font(Theme.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
        }
    }
}
