import AppKit

/// `--pilltest [seconds] [accessory|regular|both] [waitfullscreen]`: shows the real pill
/// through OverlayController.show() for `seconds` (default 2) and writes the
/// diagnostic line of each show to $TMPDIR/talkflow-pilltest.log. `both` shows it
/// as an accessory app, then a regular one (as when the app window is open),
/// then an accessory one again. `waitfullscreen` first waits (up to 10 minutes)
/// until the frontmost app's window is full screen. No keystrokes, no focus,
/// no microphone; run it as the bare built binary.
enum PillSelfTest {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-pilltest.log")

    static func run(arguments: [String]) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        let seconds = arguments.first.flatMap(Double.init) ?? 2
        let policies: [NSApplication.ActivationPolicy]
        if arguments.contains("both") { policies = [.accessory, .regular, .accessory] }
        else if arguments.contains("regular") { policies = [.regular] }
        else { policies = [.accessory] }
        let waitFullScreen = arguments.contains("waitfullscreen")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let overlay = OverlayController()
        let started = Date()

        func write(_ line: String) {
            print("talkflowd: [pilltest] \(line)")
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }

        func step(_ i: Int) {
            guard i < policies.count else { write("done"); exit(0) }
            app.setActivationPolicy(policies[i])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                overlay.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0.5)) {
                    write("step \(i + 1): \(overlay.lastShowReport ?? "no report")")
                    overlay.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { step(i + 1) }
                }
            }
        }

        write("start: frontFullScreen=\(OverlayController.frontIsFullScreen()) waitfullscreen=\(waitFullScreen)")
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            if !waitFullScreen || OverlayController.frontIsFullScreen() {
                timer.invalidate()
                step(0)
            } else if Date().timeIntervalSince(started) > 600 {
                write("timeout: never saw a full-screen front window")
                exit(2)
            }
        }
        app.run()
        exit(0)
    }
}
