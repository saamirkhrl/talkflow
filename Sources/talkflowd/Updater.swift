import AppKit
import Foundation

/// Checks GitHub Releases for a newer talkflow and installs it in place.
///
/// A release is expected to carry a zip of `talkflow.app` (see `release.sh`),
/// tagged `v<CFBundleShortVersionString>`. Installing swaps the bundle the app
/// is running from, re-signs it, and relaunches.
///
/// Re-signing matters: macOS ties the microphone, Accessibility and Input
/// Monitoring grants to the code signature, and a release zip is signed
/// ad hoc. When this Mac has the "talkflow Local Dev" identity that the
/// install scripts use, the update is signed with it and every permission
/// carries over. Without it the update keeps its ad-hoc signature and macOS
/// asks for the permissions again - said in the UI before the user clicks.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "saamirkhrl/talkflow"
    nonisolated static let signingIdentity = "talkflow Local Dev"

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL?
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

    @Published private(set) var state: State = .idle
    private var lastCheck: Date?

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks when the dashboard opens, at most every few hours, so the
    /// header already knows when the user looks at it.
    func checkIfStale() {
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        if case .checking = state { return }
        check()
    }

    func check() {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        lastCheck = Date()
        DispatchQueue.global(qos: .utility).async { _ = Self.localIdentityHash }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("talkflow/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let next: State
            if let error {
                next = .failed("Could not reach GitHub: \(error.localizedDescription)")
            } else if code == 404 {
                // No release published yet.
                next = .upToDate
            } else if !(200..<300).contains(code) {
                next = .failed(code == 403 ? "GitHub rate limit reached, try again later" : "GitHub returned \(code)")
            } else if let release = data.flatMap(Self.parse) {
                next = Self.isNewer(release.version, than: Self.currentVersion) ? .available(release) : .upToDate
            } else {
                next = .failed("The latest release has no talkflow zip attached")
            }
            DispatchQueue.main.async { self.state = next }
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

    nonisolated static var keepsPermissions: Bool { localIdentityHash != nil }

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
        // Keep this install's identifier, so a test copy stays a test copy.
        let currentID = Bundle.main.bundleIdentifier
        if let currentID, info["CFBundleIdentifier"] as? String != currentID {
            _ = run("/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleIdentifier \(currentID)", app.appendingPathComponent("Contents/Info.plist").path])
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        let identity = localIdentityHash ?? "-"
        guard run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, app.path]).status == 0 else {
            return "Could not sign the update"
        }
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
        } catch {
            return "Could not replace the app: \(error.localizedDescription)"
        }
        print("talkflowd: installed update \(version), signed with \(identity == "-" ? "an ad-hoc signature" : signingIdentity)")
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
        return Release(version: version, zipURL: url, pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)))
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
