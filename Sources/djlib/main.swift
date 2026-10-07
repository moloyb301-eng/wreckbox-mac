import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let usage = """
usage:
  djlib                                                   open the WreckBox app
  djlib spotify [--client-id ID] [--include-generated]   import your Spotify playlists + Liked Songs
  djlib library                                           build the master catalog from the Spotify export
  djlib sync-playlists                                    both of the above (runs every morning at 07:00)
  djlib bpm --playlists "A,B" [--min 120 --max 145]       BPM list (ascending) for the given playlists
  djlib analyze [file or folder ...]                      BPM + key (Camelot) of local audio files
  djlib genres [--lastfm-key KEY]                         genre per track, cross-checked from several sources
  djlib inventory [folder ...]                            read tags from local audio files (read-only)
"""

if args.isEmpty || args.first?.hasPrefix("-psn") == true {
    DJApp.main()    // no arguments (or launched from Finder): open the app window
}

do {
    switch args.first {
    case "spotify": try await SpotifyImport.run(args: Array(args.dropFirst()))
    case "library": try buildLibrary()
    case "sync-playlists": try await PlaylistSync.run()   // Spotify import + library rebuild (the 07:00 job)
    case "bpm": try await BPMTool.run(args: Array(args.dropFirst()))
    case "bpm-file":
        for p in args.dropFirst() { let r = BPMTool.estimateTempo(url: URL(fileURLWithPath: p)); print(p, r?.bpm ?? -1, r?.ambiguous ?? false, r?.alternate ?? 0) }
    case "analyze": await Analyzer.runCLI(paths: Array(args.dropFirst()))
    case "spotify-get": try await SpotifyImport.debugGet(args.dropFirst().first ?? "me")
    case "genres": try await GenreTool.run(args: Array(args.dropFirst()))
    case "inventory": try await runInventory(paths: Array(args.dropFirst()))
    case "snapshot": await Snapshot.run(args: Array(args.dropFirst()))
    case "play-test": await MacAudio.selfTest(Array(args.dropFirst()))
    case "link-test":   // reads a playlist link without saving it (dev check)
        for l in args.dropFirst() {
            guard let (kind, id) = LinkedPlaylists.parse(l) else { print("not a playlist link: \(l)"); continue }
            do {
                let got = kind == "spotify" ? try await LinkedPlaylists.fetchSpotify(id) : try await LinkedPlaylists.fetchYouTube(id)
                print("\(kind) \(id): \(got.name) — \(got.tracks.count) tracks; first: \(got.tracks.first.map { "\($0.artists.joined(separator: ", ")) – \($0.name)" } ?? "-")")
            } catch { print("\(kind) \(id): \(error)") }
        }
    case "friend-test":   // opens a friend's share key, lists it and fetches its first track (dev check)
        let f = await FriendShares.shared
        do {
            try await f.add(args.dropFirst().first ?? "")
            let s = await f.shares[0]
            let list = await f.tracks[s.id] ?? []
            print("\(s.title) from \(s.owner): \(list.count) tracks; status \(await f.status[s.id] ?? "ok")")
            if let t = list.first {
                let path = await f.fetch(t.id)
                let size = path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
                let job = await f.jobs[t.id] ?? ""
                print("fetched \(t.track.title): \(path ?? "failed — \(job)") (\(size) bytes)")
            }
            await f.remove(s.id)
        } catch { print("friend-test: \(error.localizedDescription)") }
    case "layout-check": await LayoutCheck.run(args: Array(args.dropFirst()))
    case "make-icon": await IconMaker.run(args: Array(args.dropFirst()))
    case "phone-serve":   // developer test: serve the crate to phones for N seconds (no window)
        let store = await LibraryStore()
        let server = PhoneSyncServer()
        await server.attach(store)
        await server.start()
        print(server.pairingURI)
        print("ticket secret:", PhoneSyncServer.ticketSecret, "device:", AccountAPI.deviceID)
        // A "test" event every 10 s, so live updates can be checked without changing the library.
        let end = Date().addingTimeInterval(Double(args.dropFirst().first ?? "60") ?? 60)
        while Date() < end {
            try await Task.sleep(for: .seconds(10))
            server.testEvent()
        }
    case "tag-job":   // prints the tag job the app would write for a track (no file is changed)
        let store = await LibraryStore()
        let id = await args.dropFirst().first ?? (store.library?.tracks.first { store.state.tracks[$0.id]?.status == .downloaded }?.id ?? "")
        if let job = await store.tagJob(id), let d = try? JSONEncoder().encode([job]) { print(String(decoding: d, as: UTF8.self)) }
    default: print(usage)
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
