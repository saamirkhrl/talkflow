import Foundation
import Network

/// The one thing talkflow reports about itself: the first time a fresh install
/// is running and online, it sends one empty POST so the site can add 1 to a
/// single install count. No ID, no version, no device or usage data, no body
/// and no headers of its own (docs/telemetry.md).
///
/// The URL exists only in release builds: release.sh writes it into the
/// bundle's Info.plist from TALKFLOW_TELEMETRY_URL. Source and contributor
/// builds (deploy.sh, `swift build`) have none and never make the request.
enum InstallCounter {
    /// Set only after a 2xx answer, so a failure or timeout is retried on the
    /// next launch. Deliberately not in `UserData.settingKeys`: it is about this
    /// install, so it is never backed up or restored on another Mac.
    static let countedKey = "installCounted"
    static let infoKey = "TalkflowTelemetryURL"

    /// Self-test modes never count, even though they exit before the app starts.
    static let selfTestArguments: Set<String> = [
        "--typetest", "--streamtest", "--focusprobe", "--writetest", "--newlinetest", "--stresstest", "--rectest",
        "--dashboardshot", "--onboardingshot", "--updatetest", "--formattest", "--uninstallplan", "--enginecheck",
        "--downloadtest",
    ]

    /// The baked-in URL, or nil when there is none (every non-release build).
    static var configuredURL: URL? {
        url(from: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// Only a complete https URL counts; anything else means "don't send".
    static func url(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func shouldSend(url: URL?, counted: Bool, arguments: [String], environment: [String: String]) -> Bool {
        guard url != nil, !counted else { return false }
        if arguments.contains(where: selfTestArguments.contains) { return false }
        // CI, and tests that point the app at a scratch data folder.
        if environment["CI"] != nil || environment["TALKFLOW_DATA_DIR"] != nil { return false }
        return true
    }

    /// An empty POST: no body, no headers of its own.
    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        return request
    }

    /// The HTTP status of a finished request, or nil when it failed or timed out.
    typealias Transport = (URLRequest, @escaping (Int?) -> Void) -> Void

    /// Sends once and records success. `done` gets whether this install now counts as counted.
    static func send(to url: URL, defaults: UserDefaults, transport: Transport, done: @escaping (Bool) -> Void = { _ in }) {
        transport(request(for: url)) { status in
            let ok = status.map { (200..<300).contains($0) } ?? false
            if ok { defaults.set(true, forKey: countedKey) }
            done(ok)
        }
    }

    /// A session that keeps nothing: no cookies, no cache, no credentials.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    static let urlSessionTransport: Transport = { request, finish in
        session.dataTask(with: request) { _, response, _ in
            finish((response as? HTTPURLResponse)?.statusCode)
        }.resume()
    }

    private static var monitor: NWPathMonitor?

    /// At launch: the first time the network is up, after a short pause (as the
    /// update check does), sends once if this install hasn't been counted. At
    /// most one attempt per launch.
    static func startWhenOnline() {
        let defaults = UserDefaults.standard
        guard let url = configuredURL,
              shouldSend(url: url, counted: defaults.bool(forKey: countedKey),
                         arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment),
              monitor == nil else { return }
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard let current = monitor else { return }
                current.cancel()
                monitor = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    send(to: url, defaults: defaults, transport: urlSessionTransport) { counted in
                        print("talkflowd: install count \(counted ? "sent" : "not sent, will retry next launch")")
                    }
                }
            }
        }
        monitor = pathMonitor
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))
    }
}
