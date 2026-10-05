import Foundation

// Where the project's helper tools live. The .app bundle records the repo path in its Info.plist
// (set by scripts/make-app.sh); the CLI finds it by walking up from the executable.

enum AppPaths {
    static let repo: URL = {
        if let p = Bundle.main.object(forInfoDictionaryKey: "DJLibRepoDir") as? String {
            return URL(fileURLWithPath: p)
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("analysis/analyze.py").path) { return dir }
            dir.deleteLastPathComponent()
        }
        return home.appendingPathComponent("Developer/DJLibrary")
    }()

    static var essentiaPython: URL { repo.appendingPathComponent("analysis/venv/bin/python") }
    static var essentiaScript: URL { repo.appendingPathComponent("analysis/analyze.py") }
    static var essentiaAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: essentiaPython.path) && FileManager.default.fileExists(atPath: essentiaScript.path)
    }

    static var slskSync: URL { repo.appendingPathComponent("soulseek/slsk-sync") }
    static var slskConfig: URL { repo.appendingPathComponent("soulseek/config.toml") }
    static let slskWorkDir = libraryRoot.appendingPathComponent("_soulseek")

    /// Fonts: inside the app bundle, or the source folder when running the CLI build.
    static var fontsDir: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), repo.appendingPathComponent("Sources/djlib/Resources/Fonts")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
