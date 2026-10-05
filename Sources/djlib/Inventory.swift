import AVFoundation
import Foundation

// MARK: - Model

struct TrackRecord: Codable {
    var path: String
    var folder: String
    var fileName: String
    var format: String
    var title: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: String?
    var bpm: String?
    var key: String?
    var comment: String?
    var isrc: String?
    var durationSec: Double?
    var bitrateKbps: Int?
    var sampleRate: Int?
    var channels: Int?
    var sizeBytes: Int64
    var modified: Date?
    var issues: [String]
}

// MARK: - Config

let audioExtensions: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "alac", "aac", "ogg", "opus"]
let home = FileManager.default.homeDirectoryForCurrentUser
let skipNames: Set<String> = ["Logic Pro Library.bundle", "Logic", "GarageBand", "Audio Music Apps"]

let outDir = home.appendingPathComponent("Music/DJ Library/_inventory")

// MARK: - Scan

func findAudioFiles(in root: URL) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    for case let url as URL in e {
        if skipNames.contains(url.lastPathComponent) || url.path.hasPrefix(outDir.path) {
            e.skipDescendants(); continue
        }
        if audioExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
    }
    return files
}

func stringValue(_ item: AVMetadataItem) async -> String? {
    if let s = try? await item.load(.stringValue), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let n = try? await item.load(.numberValue) { return n.stringValue }
    return nil
}

func readTrack(_ url: URL) async -> TrackRecord {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    var r = TrackRecord(
        path: url.path,
        folder: url.deletingLastPathComponent().path.replacingOccurrences(of: home.path, with: "~"),
        fileName: url.lastPathComponent,
        format: url.pathExtension.lowercased(),
        sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
        modified: attrs?[.modificationDate] as? Date,
        issues: []
    )

    let asset = AVURLAsset(url: url)
    if let d = try? await asset.load(.duration), d.isNumeric { r.durationSec = (d.seconds * 10).rounded() / 10 }

    if let track = try? await asset.loadTracks(withMediaType: .audio).first {
        if let rate = try? await track.load(.estimatedDataRate), rate > 0 { r.bitrateKbps = Int((rate / 1000).rounded()) }
        if let descs = try? await track.load(.formatDescriptions), let desc = descs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
            r.sampleRate = Int(asbd.mSampleRate)
            r.channels = Int(asbd.mChannelsPerFrame)
        }
    } else {
        r.issues.append("unreadable")
    }

    // Common keys first, then format-specific frames for BPM / key / comment.
    var items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
    for fmt in (try? await asset.load(.availableMetadataFormats)) ?? [] {
        items += (try? await asset.loadMetadata(for: fmt)) ?? []
    }
    for item in items {
        let key = (item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "").lowercased()
        guard let v = await stringValue(item) else { continue }
        switch key {
        case "title", _ where key.hasSuffix("/tit2") || key.hasSuffix("/%a9nam"): r.title = r.title ?? v
        case "artist", _ where key.hasSuffix("/tpe1") || key.hasSuffix("/%a9art"): r.artist = r.artist ?? v
        case "albumname", _ where key.hasSuffix("/talb") || key.hasSuffix("/%a9alb"): r.album = r.album ?? v
        case "type", _ where key.hasSuffix("/tcon") || key.hasSuffix("/%a9gen"): r.genre = r.genre ?? v
        case "creationdate", _ where key.hasSuffix("/tdrc") || key.hasSuffix("/tyer") || key.hasSuffix("/%a9day"): r.year = r.year ?? String(v.prefix(4))
        case _ where key.hasSuffix("/tbpm") || key.hasSuffix("/tmpo"): r.bpm = r.bpm ?? v
        case _ where key.hasSuffix("/tkey") || key.contains("initialkey"): r.key = r.key ?? v
        case _ where key.hasSuffix("/tsrc") || key.contains("isrc"): r.isrc = r.isrc ?? v.uppercased()
        case _ where key.hasSuffix("/comm") || key.hasSuffix("/%a9cmt"): r.comment = r.comment ?? v
        default: break
        }
    }

    if r.title == nil { r.issues.append("no title tag") }
    if r.artist == nil { r.issues.append("no artist tag") }
    if r.bpm == nil { r.issues.append("no BPM") }
    if r.key == nil { r.issues.append("no key") }
    if let kbps = r.bitrateKbps, ["mp3", "m4a", "aac", "ogg", "opus"].contains(r.format), kbps < 256 { r.issues.append("low bitrate (\(kbps) kbps)") }
    if let d = r.durationSec, d < 60 { r.issues.append("short (<1 min)") }
    return r
}

// MARK: - Output

func csvField(_ s: String?) -> String {
    let v = s ?? ""
    return v.contains(where: { ",\"\n".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
}

func normalized(_ s: String) -> String {
    s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}

func runInventory(paths: [String]) async throws {
let roots = paths.isEmpty
    ? ["Music", "Downloads", "Desktop", "Documents"].map { home.appendingPathComponent($0) }
    : paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
var files: [URL] = []
for root in roots { files += findAudioFiles(in: root) }
FileHandle.standardError.write("Scanning \(files.count) audio files…\n".data(using: .utf8)!)

var records: [TrackRecord] = []
for (i, f) in files.enumerated() {
    records.append(await readTrack(f))
    if (i + 1) % 25 == 0 { FileHandle.standardError.write("  \(i + 1)/\(files.count)\n".data(using: .utf8)!) }
}
records.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

// Duplicate detection: same artist+title (or filename) and duration within 2s.
var groups: [String: [Int]] = [:]
for (i, r) in records.enumerated() {
    let base = (r.artist != nil && r.title != nil) ? "\(r.artist!) \(r.title!)" : (r.fileName as NSString).deletingPathExtension
    groups[normalized(base), default: []].append(i)
}
for idxs in groups.values where idxs.count > 1 {
    for i in idxs {
        let others = idxs.filter { j in j != i && abs((records[j].durationSec ?? 0) - (records[i].durationSec ?? 0)) < 2 }
        if !others.isEmpty { records[i].issues.append("duplicate of \(others.map { records[$0].fileName }.joined(separator: "; "))") }
    }
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
enc.dateEncodingStrategy = .iso8601
try enc.encode(records).write(to: outDir.appendingPathComponent("inventory.json"))

var csv = "artist,title,album,genre,year,bpm,key,duration,format,bitrate_kbps,sample_rate,size_mb,folder,file,issues\n"
for r in records {
    let dur = r.durationSec.map { String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) }
    csv += [r.artist, r.title, r.album, r.genre, r.year, r.bpm, r.key, dur, r.format,
            r.bitrateKbps.map(String.init), r.sampleRate.map(String.init),
            String(format: "%.1f", Double(r.sizeBytes) / 1_048_576), r.folder, r.fileName,
            r.issues.joined(separator: " | ")].map(csvField).joined(separator: ",") + "\n"
}
try csv.write(to: outDir.appendingPathComponent("inventory.csv"), atomically: true, encoding: .utf8)

// Summary
let count: ((TrackRecord) -> Bool) -> Int = { pred in records.filter(pred).count }
let totalMin = records.compactMap(\.durationSec).reduce(0, +) / 60
print("Tracks: \(records.count)  (~\(Int(totalMin / 60))h \(Int(totalMin) % 60)m, \(String(format: "%.1f", Double(records.map(\.sizeBytes).reduce(0, +)) / 1_073_741_824)) GB)")
print("Formats: " + Dictionary(grouping: records, by: \.format).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", "))
print("Missing artist/title: \(count { $0.artist == nil || $0.title == nil })   Missing BPM: \(count { $0.bpm == nil })   Missing key: \(count { $0.key == nil })")
print("Low bitrate: \(count { $0.issues.contains { $0.hasPrefix("low bitrate") } })   Duplicates: \(count { $0.issues.contains { $0.hasPrefix("duplicate") } })   Unreadable: \(count { $0.issues.contains("unreadable") })")
print("By folder:")
for (folder, rs) in Dictionary(grouping: records, by: \.folder).sorted(by: { $0.value.count > $1.value.count }) {
    print("  \(rs.count)\t\(folder)")
}
print("Wrote \(outDir.path)/inventory.csv and inventory.json")
}
