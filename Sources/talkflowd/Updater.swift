import AppKit
import CryptoKit
import Foundation
import Network

/// Checks GitHub Releases for a newer talkflow and installs it in place.
///
/// A release carries `talkflow-release.json` (see `scripts/release-manifest.py`
/// and docs/releases.md), which names the macOS update zip and its sha256.
/// Releases from before the manifest existed are read through the GitHub API
/// instead, taking the first zip attached. Either way the zip holds
/// `talkflow.app`, tagged `v<CFBundleShortVersionString>`. Installing checks
/// the download against the manifest's sha256, swaps the bundle the app is
/// running from, and relaunches. Nothing installs without a click.
///
/// Checked shortly after launch once the network is up, every few hours while
/// running, and when the dashboard opens (`checkIfStale`).
///
/// The signature matters: macOS ties the microphone, Accessibility and Input
/// Monitoring grants to the code signature's designated requirement. Releases
/// are signed with one certificate (release.sh), so every release has the
/// same requirement, `releaseRequirement`, and a download that satisfies it
/// is installed with its own signature: the permissions carry over. Anything
/// else (a release from before that, or a test copy with its own identifier)
/// is re-signed as before, with the local "talkflow Local Dev" identity when
/// this Mac has one, otherwise ad hoc, and then macOS asks again.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repository = "saamirkhrl/talkflow"
    nonisolated static let signingIdentity = "talkflow Local Dev"
    /// The designated requirement every release is signed to. Keep it in step
    /// with RELEASE_DR in release.sh.
    nonisolated static let releaseRequirement = #"identifier "com.samir.talkflow" and certificate leaf = H"f38edda5db8580c91c067ff8ee3aefef8b5f05ba""#

    /// Every app asks this one URL; GitHub serves it from the newest release.
    nonisolated static let manifestURL = URL(string: "https://github.com/\(repository)/releases/latest/download/talkflow-release.json")!

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL?
        /// Lowercase hex. From the manifest, or GitHub's own digest of the
        /// asset when the API has one; nil only for an older release without
        /// either, which is installed unchecked as before.
        var sha256: String? = nil
    }

    /// What `talkflow-release.json` says. `release` is nil when the release
    /// has no macOS update build, which means there is nothing to offer.
    struct Manifest: Equatable {
        let version: String
        let release: Release?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { stateChanged() }
    }
    private var lastCheck: Date?
    private var lastSuccess: Date?
    private var lastBackgroundAttempt: Date?

    /// The version on offer, or nil when there is none; for the menu bar
    /// item. Not called while a check is running, so the item does not
    /// flicker while an already-known update is re-checked.
    var onAvailabilityChange: ((String?) -> Void)?

    private var pathMonitor: NWPathMonitor?
    private var online = false
    private var timer: Timer?
    static let backgroundInterval: TimeInterval = 6 * 3600
    /// The least time between two background attempts, so a flapping
    /// connection or an unreachable GitHub is not asked over and over.
    static let backgroundRetry: TimeInterval = 15 * 60

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks when the dashboard opens, at most every few hours (a successful
    /// background check counts), so the header already knows when the user
    /// looks at it.
    func checkIfStale() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        if case .checking = state { return }
        check()
    }

    func check() {
        check(quietly: false)
    }

    /// Starts the launch and periodic checks. The first one runs a few
    /// seconds after the network is reachable; while offline nothing is
    /// attempted. Background checks fail quietly: the state stays what it
    /// was, so an error never replaces a known update or appears unasked.
    func startBackgroundChecks() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            DispatchQueue.main.async { self?.networkChanged(up) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
        timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundRetry, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.backgroundCheck() }
        }
    }

    private func networkChanged(_ up: Bool) {
        let cameOnline = up && !online
        online = up
        guard cameOnline else { return }
        // Not in the middle of launch or of a reconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.backgroundCheck() }
    }

    private func backgroundCheck() {
        guard online else { return }
        let now = Date()
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < Self.backgroundInterval { return }
        if let lastBackgroundAttempt, now.timeIntervalSince(lastBackgroundAttempt) < Self.backgroundRetry { return }
        check(quietly: true)
    }

    private func check(quietly: Bool) {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        let previous = state
        state = .checking
        // A quiet failure leaves `lastCheck` alone, so opening the dashboard
        // still checks (and shows the error) as it always has.
        if quietly { lastBackgroundAttempt = Date() } else { lastCheck = Date() }
        DispatchQueue.global(qos: .utility).async { _ = Self.keepsPermissions }
        Self.fetchLatest { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let release):
                    self.lastSuccess = Date()
                    self.lastCheck = self.lastSuccess
                    self.state = release.map { .available($0) } ?? .upToDate
                case .failure(let failure):
                    if quietly { print("talkflowd: update check failed: \(failure.message)") }
                    self.state = quietly ? previous : .failed(failure.message)
                }
            }
        }
    }

    private func stateChanged() {
        switch state {
        case .checking:
            return
        case .available(let release):
            onAvailabilityChange?(release.version)
            UpdateNotice.shared.announce(version: release.version)
        default:
            onAvailabilityChange?(nil)
        }
    }

    struct CheckFailure: Error {
        let message: String
    }

    /// The newer release, nil when up to date. The manifest first; the
    /// GitHub API when there is no manifest (a release from before it) or
    /// one this build can't read.
    nonisolated private static func fetchLatest(_ done: @escaping (Result<Release?, CheckFailure>) -> Void) {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 15
        request.setValue("talkflow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error {
                done(.failure(CheckFailure(message: "Could not reach GitHub: \(error.localizedDescription)")))
                return
            }
            if (200..<300).contains(code), let manifest = data.flatMap(parseManifest) {
                done(.success(manifest.release.flatMap { isNewer($0.version, than: currentVersion) ? $0 : nil }))
                return
            }
            fetchFromAPI(done)
        }.resume()
    }

    nonisolated private static func fetchFromAPI(_ done: @escaping (Result<Release?, CheckFailure>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("talkflow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error {
                done(.failure(CheckFailure(message: "Could not reach GitHub: \(error.localizedDescription)")))
            } else if code == 404 {
                // No release published yet.
                done(.success(nil))
            } else if !(200..<300).contains(code) {
                done(.failure(CheckFailure(message: code == 403 ? "GitHub rate limit reached, try again later" : "GitHub returned \(code)")))
            } else if let release = data.flatMap(parse) {
                done(.success(isNewer(release.version, than: currentVersion) ? release : nil))
            } else {
                done(.failure(CheckFailure(message: "The latest release has no talkflow zip attached")))
            }
        }.resume()
    }

    /// Downloads, verifies, swaps the bundle and relaunches.
    func install() {
        guard case .available(let release) = state else { return }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else {
            state = .failed("Not running from an installed talkflow.app")
            return
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed("Can't write to \(target.deletingLastPathComponent().path)")
            return
        }
        state = .downloading
        print("talkflowd: downloading update \(release.version)")
        URLSession.shared.downloadTask(with: release.zipURL) { location, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let location, error == nil, (200..<300).contains(code) else {
                let reason = error?.localizedDescription ?? "HTTP \(code)"
                DispatchQueue.main.async { self.state = .failed("Download failed: \(reason)") }
                return
            }
            // The temporary file is removed when this handler returns.
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("talkflow-update-\(UUID().uuidString)")
            let zip = work.appendingPathComponent("update.zip")
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: zip)
            } catch {
                DispatchQueue.main.async { self.state = .failed("Download failed: \(error.localizedDescription)") }
                return
            }
            if let expected = release.sha256 {
                let actual = Self.sha256Hex(of: zip)
                guard actual == expected else {
                    try? FileManager.default.removeItem(at: work)
                    print("talkflowd: update \(release.version) refused: sha256 \(actual ?? "unreadable"), expected \(expected)")
                    DispatchQueue.main.async {
                        self.state = .failed("The download did not match the release's checksum, so it was not installed")
                    }
                    return
                }
            }
            DispatchQueue.main.async { self.state = .installing }
            let result = Self.installBundle(zip: zip, in: work, version: release.version, over: target)
            try? FileManager.default.removeItem(at: work)
            DispatchQueue.main.async {
                if let failure = result {
                    self.state = .failed(failure)
                } else {
                    Self.relaunch(target)
                }
            }
        }.resume()
    }

    /// Whether installing will keep the current permissions (see the type's
    /// comment). Shown next to the Update button.
    /// The SHA-1 of the local signing identity, matched without regard to
    /// case (this Mac's is "TalkFlow Local Dev"). Signing by hash also avoids
    /// codesign's ambiguous-name error if two certificates share the name.
    /// Read once (a subprocess), the first time `check()` runs.
    nonisolated static let localIdentityHash: String? = {
        let output = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).output
        let line = output.split(separator: "\n").first { $0.lowercased().contains("\"\(signingIdentity.lowercased())\"") }
        return line?.split(separator: " ").first { $0.count == 40 && $0.allSatisfy(\.isHexDigit) }.map(String.init)
    }()

    /// Whether this running copy is itself release signed, so the next
    /// release has the same designated requirement. Read once.
    nonisolated static let runningCopyIsReleaseSigned: Bool = isReleaseSigned(Bundle.main.bundleURL)

    nonisolated static var keepsPermissions: Bool { runningCopyIsReleaseSigned || localIdentityHash != nil }

    /// Whether `app` is validly signed, its helper included, by the release
    /// certificate.
    nonisolated static func isReleaseSigned(_ app: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(releaseRequirement)", app.path]).status == 0
    }

    // MARK: - Steps

    /// Nil on success, else what went wrong. Runs off the main thread.
    nonisolated static func installBundle(zip: URL, in work: URL, version: String, over target: URL) -> String? {
        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
            return "Could not unpack the update"
        }
        guard let app = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            return "The update has no talkflow.app in it"
        }
        // Only ever replace talkflow with talkflow, and only with the version
        // the release said it was.
        guard info["CFBundleExecutable"] as? String == "talkflowd" else { return "The update is not a talkflow build" }
        guard info["CFBundleShortVersionString"] as? String == version else {
            return "The update says it is \(info["CFBundleShortVersionString"] as? String ?? "?"), expected \(version)"
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        // A release-signed talkflow replacing talkflow is installed exactly as
        // published; editing or re-signing it would change its requirement.
        let currentID = Bundle.main.bundleIdentifier
        let signed = info["CFBundleIdentifier"] as? String == currentID && isReleaseSigned(app)
        var signedWith = "the release signature"
        if !signed {
            // Keep this install's identifier, so a test copy stays a test copy.
            if let currentID, info["CFBundleIdentifier"] as? String != currentID {
                _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(currentID)", app.appendingPathComponent("Contents/Info.plist").path])
            }
            let identity = localIdentityHash ?? "-"
            // --deep also re-signs the bundled speech engine,
            // Contents/Helpers/whisper-server, with the same identity.
            guard run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, app.path]).status == 0 else {
                return "Could not sign the update"
            }
            signedWith = identity == "-" ? "an ad-hoc signature" : signingIdentity
        }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
        } catch {
            return "Could not replace the app: \(error.localizedDescription)"
        }
        print("talkflowd: installed update \(version), signed with \(signedWith)")
        return nil
    }

    /// Quits and starts the new build. Under the LaunchAgent, launchd starts
    /// it; otherwise `open` does. The script waits for this process to be
    /// gone first: kickstart does nothing to a job that is still running, and
    /// the single-instance guard would make a second copy quit.
    private static func relaunch(_ app: URL) {
        let uid = getuid()
        let pid = ProcessInfo.processInfo.processIdentifier
        let label = Bundle.main.bundleIdentifier ?? "com.samir.talkflow"
        let script = "for _ in $(seq 50); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done; "
            + "/bin/launchctl kickstart gui/\(uid)/\(label) 2>/dev/null || /usr/bin/open \"\(app.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - Pure helpers, for --streamtest

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }),
              let link = zip["browser_download_url"] as? String, let url = URL(string: link) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // GitHub records "sha256:<hex>" for assets uploaded since mid 2025.
        let digest = (zip["digest"] as? String)?.lowercased()
        let sha256 = digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }.flatMap { isSHA256($0) ? $0 : nil }
        return Release(version: version, zipURL: url, pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)), sha256: sha256)
    }

    /// Reads `talkflow-release.json` (schema 1, see docs/releases.md). Nil
    /// when it is not JSON or not a schema this build knows. Platforms other
    /// than macOS, and any other keys, are ignored. The macOS entry counts
    /// only with an https URL and a well-formed sha256.
    nonisolated static func parseManifest(_ data: Data) -> Manifest? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schema"] as? Int == 1,
              let version = json["version"] as? String, !version.isEmpty,
              let platforms = json["platforms"] as? [String: Any] else { return nil }
        let page = (json["notesUrl"] as? String).flatMap(URL.init(string:))
        var release: Release?
        if let macos = platforms["macos"] as? [String: Any],
           let universal = macos["universal"] as? [String: Any],
           let update = universal["update"] as? [String: Any],
           let link = update["url"] as? String, let url = URL(string: link), url.scheme == "https",
           let sha256 = (update["sha256"] as? String)?.lowercased(), isSHA256(sha256) {
            release = Release(version: version, zipURL: url, pageURL: page, sha256: sha256)
        }
        return Manifest(version: version, release: release)
    }

    nonisolated static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }

    /// Lowercase hex sha256 of a file, read in pieces. Nil if unreadable.
    nonisolated static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // nil or empty at the end of the file.
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// "0.10.0" is newer than "0.9.2"; missing parts count as zero.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
