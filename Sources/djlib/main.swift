import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let usage = """
usage:
  djlib                                                   open the WreckBox app
  djlib spotify [--client-id ID] [--include-generated]   import your Spotify playlists + Liked Songs
  djlib library                                           build the master catalog from the Spotify export
  djlib bpm --playlists "A,B" [--min 120 --max 145]       BPM list (ascending) for the given playlists
  djlib analyze [file or folder ...]                      BPM + key (Camelot) of local audio files
  djlib genres                                            genre per track, cross-checked from several sources
  djlib inventory [folder ...]                            read tags from local audio files (read-only)
"""

if args.isEmpty || args.first?.hasPrefix("-psn") == true {
    DJApp.main()    // no arguments (or launched from Finder): open the app window
}

do {
    switch args.first {
    case "spotify": try await SpotifyImport.run(args: Array(args.dropFirst()))
    case "library": try buildLibrary()
    case "bpm": try await BPMTool.run(args: Array(args.dropFirst()))
    case "bpm-file":
        for p in args.dropFirst() { let r = BPMTool.estimateTempo(url: URL(fileURLWithPath: p)); print(p, r?.bpm ?? -1, r?.ambiguous ?? false, r?.alternate ?? 0) }
    case "analyze": await Analyzer.runCLI(paths: Array(args.dropFirst()))
    case "spotify-get": try await SpotifyImport.debugGet(args.dropFirst().first ?? "me")
    case "genres": try await GenreTool.run(args: Array(args.dropFirst()))
    case "inventory": try await runInventory(paths: Array(args.dropFirst()))
    case "snapshot": await Snapshot.run(args: Array(args.dropFirst()))
    case "layout-check": await LayoutCheck.run(args: Array(args.dropFirst()))
    case "make-icon": await IconMaker.run(args: Array(args.dropFirst()))
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
