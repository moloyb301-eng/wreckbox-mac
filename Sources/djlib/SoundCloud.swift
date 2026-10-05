import SwiftUI
import WebKit

// In-app SoundCloud browser. You log in and click a track's own "Download file" button (or unlock a
// free-download gate); the file is caught here, saved to _inbox, then matched and filed by LibraryStore.
// Only real file downloads are handled: playback streams are never captured.

struct BulkResult: Identifiable {
    let id: String              // library track id
    var track: String
    var status: String
    var link: String?
}

struct DownloadItem: Identifiable {
    let id = UUID()
    var name: String
    var state: String
}

@MainActor
final class SoundCloudBrowser: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var downloads: [DownloadItem] = []
    @Published var currentURL: String = ""
    @Published var canGoBack = false
    weak var store: LibraryStore?
    @Published var bulk: [BulkResult] = []
    @Published var bulkRunning = false
    private var stopRequested = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var active: [ObjectIdentifier: (item: UUID, file: URL)] = [:]
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // keeps you logged in between launches
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observers.append(webView.observe(\.url) { [weak self] wv, _ in Task { @MainActor in self?.currentURL = wv.url?.absoluteString ?? "" } })
        observers.append(webView.observe(\.canGoBack) { [weak self] wv, _ in Task { @MainActor in self?.canGoBack = wv.canGoBack } })
        webView.load(URLRequest(url: URL(string: "https://soundcloud.com")!))
    }

    func search(_ query: String) {
        var c = URLComponents(string: "https://soundcloud.com/search/sounds")!
        c.queryItems = [.init(name: "q", value: query)]
        webView.load(URLRequest(url: c.url!))
    }

    func open(_ text: String) {
        if let u = URL(string: text), u.scheme?.hasPrefix("http") == true { webView.load(URLRequest(url: u)) } else { search(text) }
    }

    private func isFileDownload(_ response: URLResponse) -> Bool {
        if let http = response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().contains("attachment") { return true }
        let mime = response.mimeType?.lowercased() ?? ""
        return mime.hasPrefix("audio/") || ["application/octet-stream", "application/zip", "application/x-zip-compressed"].contains(mime)
    }

    // MARK: Bulk download (artist-enabled downloads only)

    /// Hosts that free-download gates live on; these need a follow/repost click from you.
    static let gateHosts = ["hypeddit", "toneden", "fanlink", "gate.fm", "dropbox", "drive.google", "bit.ly", "smarturl", "linktr", "feature.fm", "lnk.to", "wetransfer"]

    func stopBulk() { stopRequested = true }

    func bulkDownload(_ ids: [String]) async {
        guard let store, !bulkRunning else { return }
        bulkRunning = true
        stopRequested = false
        let todo = ids.compactMap { store.track($0) }.filter { store.state.tracks[$0.id]?.status != .downloaded }
        bulk = todo.map { BulkResult(id: $0.id, track: "\($0.artists.joined(separator: ", ")) – \($0.title)", status: "queued") }
        store.log("bulk start", nil, "SoundCloud bulk download for \(todo.count) tracks")

        for t in todo {
            if stopRequested { setBulk(t.id, "stopped"); continue }
            setBulk(t.id, "searching…")
            let outcome = await tryTrack(t)
            setBulk(t.id, outcome.status, outcome.link)
            store.log("bulk", t.id, "\(store.describe(t.id)): \(outcome.status)\(outcome.link.map { " – \($0)" } ?? "")")
            try? await Task.sleep(nanoseconds: 2_000_000_000)      // browse at a human pace
        }
        let summary = Dictionary(grouping: bulk, by: { $0.status.components(separatedBy: ":").first ?? $0.status }).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        store.log("bulk done", nil, summary)
        store.pendingTrackID = nil
        store.save()
        bulkRunning = false
    }

    private func setBulk(_ id: String, _ status: String, _ link: String? = nil) {
        if let i = bulk.firstIndex(where: { $0.id == id }) { bulk[i].status = status; if link != nil { bulk[i].link = link } }
    }

    private func tryTrack(_ t: LibraryTrack) async -> (status: String, link: String?) {
        var c = URLComponents(string: "https://soundcloud.com/search/sounds")!
        c.queryItems = [.init(name: "q", value: "\(t.artists.first ?? "") \(t.title)")]
        await load(c.url!)
        var links: [String] = []
        for _ in 0..<8 {
            links = (try? await webView.callAsyncJavaScript(
                "return [...document.querySelectorAll('li.searchList__item a.soundTitle__title')].slice(0, 5).map(a => a.href)",
                contentWorld: .page)) as? [String] ?? []
            if !links.isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if links.isEmpty { return ("not found on SoundCloud", nil) }

        var fallback: (String, String?)? = nil
        for link in links {
            if stopRequested { return ("stopped", nil) }
            guard let u = URL(string: link) else { continue }
            await load(u)
            guard let json = try? await webView.callAsyncJavaScript(
                "const s = (window.__sc_hydration || []).find(x => x.hydratable === 'sound'); return s ? JSON.stringify(s.data) : null",
                contentWorld: .page) as? String,
                  let sound = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
                  soundMatches(sound, t) else { continue }

            let permalink = sound["permalink_url"] as? String ?? link
            if sound["downloadable"] as? Bool == true {
                if sound["has_downloads_left"] as? Bool == false { fallback = fallback ?? ("download limit reached", permalink); continue }
                return await clickDownload(t, permalink: permalink)
            }
            let purchase = (sound["purchase_url"] as? String ?? "")
            let purchaseTitle = (sound["purchase_title"] as? String ?? "").lowercased()
            let desc = (sound["description"] as? String ?? "").lowercased()
            if !purchase.isEmpty && (Self.gateHosts.contains { purchase.lowercased().contains($0) } || purchaseTitle.contains("free")) {
                return ("free download gate (unlock yourself)", purchase)
            }
            if purchaseTitle.contains("free") || desc.contains("free download") || desc.contains("free dl") {
                fallback = ("says free download – check description", permalink)
            } else if fallback == nil {
                fallback = ("stream only", permalink)
            }
        }
        return fallback ?? ("no matching upload", links.first)
    }

    private func soundMatches(_ s: [String: Any], _ t: LibraryTrack) -> Bool {
        let title = normalized(s["title"] as? String ?? "")
        let user = normalized((s["user"] as? [String: Any])?["username"] as? String ?? "")
        let want = Matcher.cleanTitle(t.title)
        guard !want.isEmpty, title.contains(want) else { return false }
        let artistOK = t.artists.contains { a in let n = normalized(a); return !n.isEmpty && (title.contains(n) || user.contains(n) || n.contains(user)) }
        guard artistOK else { return false }
        if let a = t.durationMs, let b = s["duration"] as? Int, abs(a - b) > 15_000 { return false }
        return true
    }

    /// Clicks the page's own ⋯ → Download file, then waits for the file to be caught and imported.
    private func clickDownload(_ t: LibraryTrack, permalink: String) async -> (status: String, link: String?) {
        store?.pendingTrackID = t.id
        let before = downloads.count
        let clicked = (try? await webView.callAsyncJavaScript("""
            const more = document.querySelector('.listenEngagement .sc-button-more, .soundActions .sc-button-more');
            if (!more) return 'no menu button';
            more.click();
            await new Promise(r => setTimeout(r, 800));
            const dl = document.querySelector('.sc-button-download, button[title="Download file"], a[title="Download file"]');
            if (!dl) return 'no download item';
            dl.click();
            return 'clicked';
            """, contentWorld: .page)) as? String ?? "script error"
        guard clicked == "clicked" else { return ("downloadable, but couldn't click (\(clicked))", permalink) }

        for _ in 0..<15 where downloads.count == before { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        guard downloads.count > before else { return ("download didn't start", permalink) }
        let item = downloads[0].id
        for _ in 0..<180 {
            let st = downloads.first { $0.id == item }?.state ?? ""
            if !st.hasSuffix("…") { return (st.hasPrefix("Added") ? "downloaded" : st, permalink) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return ("download timed out", permalink)
    }

    private func load(_ url: URL) async {
        loadContinuation?.resume()
        await withCheckedContinuation { c in
            loadContinuation = c
            webView.load(URLRequest(url: url))
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)          // let the page's scripts render
    }

    fileprivate func finishedLoading() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    private func update(_ id: UUID, _ state: String) {
        if let i = downloads.firstIndex(where: { $0.id == id }) { downloads[i].state = state }
    }
}

extension SoundCloudBrowser: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedLoading() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishedLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finishedLoading() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let download = MainActor.assumeIsolated { isFileDownload(response.response) || !response.canShowMIMEType }
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // Download links and gate pages often open in a new window; load them in place instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        MainActor.assumeIsolated {
            try? FileManager.default.createDirectory(at: LibraryStore.inboxDir, withIntermediateDirectories: true)
            let name = safeFileName(suggestedFilename.isEmpty ? "download" : suggestedFilename)
            var dest = LibraryStore.inboxDir.appendingPathComponent(name)
            var n = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = LibraryStore.inboxDir.appendingPathComponent("\((name as NSString).deletingPathExtension) (\(n)).\((name as NSString).pathExtension)"); n += 1
            }
            let item = DownloadItem(name: name, state: "downloading…")
            downloads.insert(item, at: 0)
            active[ObjectIdentifier(download)] = (item.id, dest)
            completionHandler(dest)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let (id, file) = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
            update(id, "importing…")
            Task {
                let msg = await store?.importDownloaded(file, source: "soundcloud") ?? "saved to _inbox"
                update(id, msg)
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            guard let (id, _) = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
            update(id, "failed: \(error.localizedDescription)")
        }
    }
}

struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct SoundCloudView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var browser: SoundCloudBrowser
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            if let id = store.pendingTrackID {
                HStack {
                    Image(systemName: "scope")
                    Text("Looking for: ").bold() + Text(store.describe(id))
                    Spacer()
                    Text("Use the track's ⋯ → Download file, or its free-download link").foregroundStyle(.secondary)
                    Button("Clear") { store.pendingTrackID = nil }
                }
                .padding(8)
                .background(.yellow.opacity(0.15))
            }
            HStack {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!browser.canGoBack)
                Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("Search SoundCloud or paste a link", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { browser.open(address) }
            }
            .padding(8)
            WebView(webView: browser.webView)
            if !browser.bulk.isEmpty {
                Divider()
                HStack {
                    Text("Bulk download").bold()
                    let done = browser.bulk.filter { !["queued", "searching…"].contains($0.status) }.count
                    Text("\(done)/\(browser.bulk.count) checked · \(browser.bulk.filter { $0.status == "downloaded" }.count) downloaded").foregroundStyle(.secondary)
                    Spacer()
                    if browser.bulkRunning { Button("Stop") { browser.stopBulk() } } else { Button("Clear") { browser.bulk = [] } }
                }
                .padding(.horizontal, 8).padding(.top, 6)
                Table(browser.bulk) {
                    TableColumn("Track", value: \.track)
                    TableColumn("Result", value: \.status)
                    TableColumn("Link") { r in
                        if let l = r.link, let u = URL(string: l) { Link(l.replacingOccurrences(of: "https://", with: ""), destination: u).lineLimit(1) }
                    }
                }
                .frame(height: 180)
            }
            if !browser.downloads.isEmpty {
                Divider()
                List(browser.downloads) { d in
                    HStack {
                        Image(systemName: d.state.hasPrefix("Added") ? "checkmark.circle.fill" : d.state.hasPrefix("failed") ? "xmark.octagon" : "arrow.down.circle")
                        Text(d.name).lineLimit(1)
                        Spacer()
                        Text(d.state).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(height: 120)
            }
        }
        .onReceive(browser.$currentURL) { address = $0 }
    }
}
