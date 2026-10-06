import Foundation

// Smaller copies of tracks for the phone: FLAC (the original file), or AAC .m4a at High / Medium / Low, made with
// macOS's built-in afconvert (~0.7 s for a 2-minute FLAC) and tagged like the original, so a file the phone
// downloads still has title, BPM, key and cover. Cached in _cache/transcodes/<quality>/, oldest dropped past 10 GB.

enum StreamQuality: String, CaseIterable {
    case flac, high, med, low

    /// AAC bit rate; nil = the original file.
    var bitRate: Int? {
        switch self {
        case .flac: return nil
        case .high: return 256_000
        case .med: return 160_000
        case .low: return 96_000
        }
    }

    init(param: String?) { self = StreamQuality(rawValue: (param ?? "").lowercased()) ?? .flac }
}

final class Transcoder {
    static let shared = Transcoder()
    static let root = libraryRoot.appendingPathComponent("_cache/transcodes")
    static let limitBytes: Int64 = 10 * 1024 * 1024 * 1024

    /// Formats afconvert can decode. Anything else (e.g. ogg) is served as the original.
    private static let decodable: Set<String> = ["flac", "wav", "aif", "aiff", "m4a", "mp3", "aac", "alac", "caf"]
    private static let lossless: Set<String> = ["flac", "wav", "aif", "aiff", "alac"]

    private let lock = NSLock()
    private var inFlight: [String: [(URL?) -> Void]] = [:]
    private let work = DispatchQueue(label: "wreckbox.transcode", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 2)   // two at a time keeps the Mac responsive

    func cacheURL(_ id: String, _ q: StreamQuality) -> URL {
        Self.root.appendingPathComponent(q.rawValue).appendingPathComponent(ArtworkLoader.fileStem(id) + ".m4a")
    }

    /// True when `q` needs a converted copy of `source` (the original is used for FLAC, and for lossy files at High).
    static func needsCopy(_ source: String, _ q: StreamQuality) -> Bool {
        let ext = (source as NSString).pathExtension.lowercased()
        guard q.bitRate != nil, decodable.contains(ext) else { return false }
        return lossless.contains(ext) || q != .high
    }

    /// The ready converted file, if there is one newer than the source.
    func ready(_ id: String, source: String, _ q: StreamQuality) -> URL? {
        let out = cacheURL(id, q)
        let fm = FileManager.default
        guard let o = try? fm.attributesOfItem(atPath: out.path)[.modificationDate] as? Date,
              let s = try? fm.attributesOfItem(atPath: source)[.modificationDate] as? Date, o >= s else { return nil }
        return out
    }

    /// Makes the converted copy (once, even if asked several times) and calls back with it, or nil if it failed.
    /// `tag` is the original's tag job; it's written into the copy.
    func make(_ id: String, source: String, _ q: StreamQuality, tag: TagJob?, done: ((URL?) -> Void)? = nil) {
        if let r = ready(id, source: source, q) { done?(r); return }
        let key = "\(q.rawValue):\(id)"
        lock.lock()
        if inFlight[key] != nil {
            if let done { inFlight[key]!.append(done) }
            lock.unlock()
            return
        }
        inFlight[key] = done.map { [$0] } ?? []
        lock.unlock()
        work.async {
            self.slots.wait()
            let out = self.convert(source: source, to: self.cacheURL(id, q), bitRate: q.bitRate ?? 160_000, tag: tag)
            self.slots.signal()
            self.lock.lock()
            let waiters = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            waiters.forEach { $0(out) }
            if out != nil { self.prune() }
        }
    }

    /// Waits up to `timeout` for the copy; nil if it isn't ready by then (it keeps going in the background).
    func wait(_ id: String, source: String, _ q: StreamQuality, tag: TagJob?, timeout: TimeInterval) -> URL? {
        if let r = ready(id, source: source, q) { return r }
        let sem = DispatchSemaphore(value: 0)
        var result: URL?
        make(id, source: source, q, tag: tag) { result = $0; sem.signal() }
        return sem.wait(timeout: .now() + timeout) == .success ? result : nil
    }

    private func convert(source: String, to out: URL, bitRate: Int, tag: TagJob?) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.deletingPathExtension().appendingPathExtension("part.m4a")
        try? fm.removeItem(at: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = [source, tmp.path, "-f", "m4af", "-d", "aac", "-b", String(bitRate), "-s", "2", "-q", "127"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0, fm.fileExists(atPath: tmp.path) else { try? fm.removeItem(at: tmp); return nil }
        if var job = tag {
            job.path = tmp.path
            _ = Tagger.write([job])
        }
        try? fm.removeItem(at: out)
        do { try fm.moveItem(at: tmp, to: out) } catch { return nil }
        return out
    }

    /// Marks a copy as just used, so pruning keeps it.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Drops the least recently used copies once the cache is over its limit.
    private func prune() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        for case let u as URL in e where u.pathExtension == "m4a" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(v?.fileSize ?? 0)
            total += size
            files.append((u, size, v?.contentModificationDate ?? .distantPast))
        }
        guard total > Self.limitBytes else { return }
        for (u, size, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? fm.removeItem(at: u)
            total -= size
            if total <= Self.limitBytes * 9 / 10 { break }
        }
    }
}
