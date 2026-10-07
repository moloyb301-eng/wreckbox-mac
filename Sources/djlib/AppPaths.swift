import Foundation

// Where the project's helper tools live. A shipped app (scripts/package-mac.sh) carries them inside itself:
// Resources/helpers (the Python helpers on a bundled Python), Resources/bin (ffmpeg, deno). A developer build
// records the repo path in its Info.plist (scripts/make-app.sh); the CLI finds it by walking up from the executable.

enum AppPaths {
    /// Resources/helpers of a self-contained (shipped) app, else nil.
    static let bundledHelpers: URL? = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("helpers"),
              FileManager.default.fileExists(atPath: r.appendingPathComponent("soulseek/slsk_sync.py").path) else { return nil }
        return r
    }()
    static var bundled: Bool { bundledHelpers != nil }

    static let repo: URL = {
        if let b = bundledHelpers { return b }
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
    /// The Soulseek login: in the repo for a developer build; per user (never inside the app) when shipped.
    static var slskConfig: URL {
        bundled ? appSupport.appendingPathComponent("soulseek.toml") : repo.appendingPathComponent("soulseek/config.toml")
    }
    static var appSupport: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WreckBox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// ffmpeg / deno shipped inside the app.
    static var binDir: URL? { Bundle.main.resourceURL.map { $0.appendingPathComponent("bin") }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }

    /// PATH for helpers: the app's own tools first, then Homebrew (apps don't get Homebrew on their PATH).
    static var toolPATH: String {
        ([binDir?.path].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin", ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"])
            .joined(separator: ":")
    }

    /// Environment for every helper process.
    static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPATH
        env["WRECKBOX_SLSK_CONFIG"] = slskConfig.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"   // the app bundle stays as it was signed
        return env
    }
    static let slskWorkDir = libraryRoot.appendingPathComponent("_soulseek")

    /// Fonts: inside the app bundle, or the source folder when running the CLI build.
    static var fontsDir: URL? {
        [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), repo.appendingPathComponent("Sources/djlib/Resources/Fonts")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
