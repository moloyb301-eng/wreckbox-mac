import AudioToolbox
import SwiftUI

// Audio quality of each file in the crate, for the "Quality" column: format + bit rate ("MP3 320", "AAC 256",
// "FLAC", "FLAC 24"), read from the file itself. Files YouTube fill made are FLAC containers holding Opus audio,
// so for those the column shows the real source ("OPUS 304") instead of the FLAC's meaningless bit rate.
// Cached in _cache/quality.json (keyed by path + size), filled in the background.

struct FileQuality: Codable, Equatable {
    var codec: String          // FLAC, ALAC, WAV, AIFF, MP3, AAC, OPUS, OGG
    var kbps: Int?
    var sampleRate: Double?
    var bits: Int?
    var lossless: Bool
    var size: Int64            // to notice a replaced file
    var fromYouTube = false
    var channels: Int?
    /// Set when WreckBox converted a format Rekordbox can't play (Dolby, OGG …) to FLAC: what the source was.
    /// Such files are not truly lossless (lossless = false), so the Soulseek FLAC re-check still looks for them.
    var convertedFrom: String?

    /// Dolby (E-AC-3 / AC-3) or any surround (more than 2 channels) — Rekordbox and CDJs can't play it.
    var unplayable: Bool { codec == "E-AC3" || codec == "AC3" || (channels ?? 2) > 2 }
    var label: String {
        if unplayable { return "\(codec)\((channels ?? 2) > 2 ? " \(channels! - 1).1" : "")" }
        if let c = convertedFrom { return kbps.map { "\(c) \($0)" } ?? c }
        if lossless && !fromYouTube { return (bits ?? 16) > 16 ? "\(codec) \(bits!)" : codec }
        return kbps.map { "\(codec) \($0)" } ?? codec
    }

    var detail: String {
        var parts: [String] = []
        if let c = convertedFrom { return "\(c)\(kbps.map { " \($0) kbps" } ?? "") source, converted to FLAC so Rekordbox can play it — a real FLAC is still being looked for" }
        if unplayable { return "Dolby surround (\(codec), \(channels ?? 0) channels) — Rekordbox and CDJs can't play this; replace it" }
        if fromYouTube { parts.append("YouTube Music, Opus \(kbps ?? 0) kbps — saved as FLAC so Rekordbox can read it") }
        else if lossless { parts.append("Lossless \(codec)") }
        else { parts.append("\(codec) \(kbps.map { "\($0) kbps" } ?? "")") }
        if let sampleRate { parts.append(String(format: "%g kHz", sampleRate / 1000)) }
        if let bits, lossless, !fromYouTube { parts.append("\(bits)-bit") }
        return parts.joined(separator: " · ")
    }

    /// Lossless = lilac, good lossy (≥ 256 kbps) = normal, lower = peach (worth replacing).
    var color: Color {
        if unplayable { return Theme.peach }
        if lossless && !fromYouTube { return Theme.lilac }
        return (kbps ?? 0) >= 256 ? Theme.text2 : Theme.peach
    }

    static func probe(_ path: String) -> FileQuality? {
        let url = URL(fileURLWithPath: path) as CFURL
        var file: AudioFileID?
        guard AudioFileOpenURL(url, .readPermission, 0, &file) == noErr, let f = file else { return nil }
        defer { AudioFileClose(f) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &size, &asbd) == noErr else { return nil }
        var bitRate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(f, kAudioFilePropertyBitRate, &size, &bitRate)
        var depth: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioFileGetProperty(f, kAudioFilePropertySourceBitDepth, &size, &depth)
        let ext = (path as NSString).pathExtension.lowercased()
        let codec: String, lossless: Bool
        switch asbd.mFormatID {
        case kAudioFormatFLAC: (codec, lossless) = ("FLAC", true)
        case kAudioFormatAppleLossless: (codec, lossless) = ("ALAC", true)
        case kAudioFormatLinearPCM: (codec, lossless) = (ext.hasPrefix("aif") ? "AIFF" : "WAV", true)
        case kAudioFormatMPEGLayer3: (codec, lossless) = ("MP3", false)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: (codec, lossless) = ("AAC", false)
        case kAudioFormatOpus: (codec, lossless) = ("OPUS", false)
        case kAudioFormatEnhancedAC3: (codec, lossless) = ("E-AC3", false)
        case kAudioFormatAC3: (codec, lossless) = ("AC3", false)
        default: (codec, lossless) = (ext.uppercased(), false)
        }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        // Round lossy rates to the familiar steps (319 → 320).
        var kbps = bitRate > 0 ? Int((Double(bitRate) / 1000).rounded()) : nil
        if let k = kbps, !lossless, let step = [96, 128, 160, 192, 224, 256, 320].min(by: { abs($0 - k) < abs($1 - k) }), abs(step - k) <= 4 { kbps = step }
        return FileQuality(codec: codec, kbps: lossless ? nil : kbps, sampleRate: asbd.mSampleRate > 0 ? asbd.mSampleRate : nil,
                           bits: depth > 0 ? Int(depth) : (asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil),
                           lossless: lossless, size: fileSize, channels: Int(asbd.mChannelsPerFrame))
    }
}

extension LibraryStore {
    static var qualityCacheFile: URL { libraryRoot.appendingPathComponent("_cache/quality.json") }

    /// Reads the quality of every crate file that isn't cached yet (or changed), off the main thread.
    func refreshQuality() async {
        if quality.isEmpty, let d = try? Data(contentsOf: Self.qualityCacheFile),
           let cached = try? JSONDecoder().decode([String: FileQuality].self, from: d) {
            quality = cached
        }
        // YouTube fill records the real source quality of what it made.
        let yt = (try? JSONSerialization.jsonObject(with: Data(contentsOf: AppPaths.ytWorkDir.appendingPathComponent("yt.json")))) as? [String: [String: Any]] ?? [:]
        let convertedIDs = Set(Playable.converted.keys)
        var todo: [(path: String, id: String)] = []
        for (id, st) in state.tracks where st.status == .downloaded {
            guard let p = st.localPath else { continue }
            let size = ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? -1
            // Re-read changed files, and converted ones whose entry doesn't say what they were converted from yet.
            if quality[p]?.size != size || (convertedIDs.contains(id) && quality[p]?.convertedFrom == nil) { todo.append((p, id)) }
        }
        guard !todo.isEmpty else { return }
        let sources = Dictionary(state.tracks.map { ($0.key, $0.value.source ?? "") }, uniquingKeysWith: { a, _ in a })
        let converted = Playable.converted
        let found = await Task.detached(priority: .utility) { () -> [String: FileQuality] in
            var out: [String: FileQuality] = [:]
            for (p, id) in todo {
                guard var q = FileQuality.probe(p) else { continue }
                if let c = converted[id] {
                    q.convertedFrom = c["codec"] as? String
                    q.kbps = c["kbps"] as? Int
                    q.lossless = false
                } else if sources[id] == "youtube", let r = yt[id] {
                    q.fromYouTube = true
                    q.codec = ((r["codec"] as? String) == "mp4a") ? "AAC" : "OPUS"
                    q.kbps = r["kbps"] as? Int
                    q.lossless = false
                }
                out[p] = q
            }
            return out
        }.value
        quality.merge(found) { _, new in new }
        if let d = try? JSONEncoder().encode(quality) { try? d.write(to: Self.qualityCacheFile, options: .atomic) }
    }
}
