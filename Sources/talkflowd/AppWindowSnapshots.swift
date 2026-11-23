import AppKit
import SwiftUI

extension DashboardController {
    /// `--dashboardshot [folder]`: draws every section of the window, light
    /// and dark, to PNGs, from sample stats and words in a throwaway sandbox,
    /// so the layout can be checked without a screen. Never reads or writes
    /// the user's settings, stats or keys.
    @MainActor
    static func renderSnapshots() -> [URL] {
        let arguments = CommandLine.arguments
        let folder = arguments.firstIndex(of: "--dashboardshot")
            .flatMap { arguments.dropFirst($0 + 1).first }
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-app-window")
        PreviewSandbox.enter()
        defer { PreviewSandbox.leave() }
        PreviewSandbox.useRepoIcon()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppWindowModel(settings: SettingsModel(environment: .preview()), updatesEnabled: false)
        model.refresh()
        let update = Updater.State.available(Updater.Release(
            version: "0.2.0", zipURL: URL(string: "https://example.invalid/talkflow.zip")!, pageURL: nil))
        var written: [URL] = []

        /// Draws the current state of `model` as `index-name-light/dark.png`.
        func shoot(_ index: Int, _ name: String, _ section: AppSection, fullHeight: Bool) {
            model.section = section
            for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let url = folder.appendingPathComponent(String(format: "%02d-%@-%@.png", index, name, look))
                if render(model, appearance: appearance, fullHeight: fullHeight, to: url) { written.append(url) }
            }
        }

        // The state a shot sets is set after `refresh()` (it overwrites
        // `setupNeeded`) and put back before the next shot.
        model.dashboard.chartStyle = .grid
        model.dashboard.hovered = model.dashboard.days.count - 1
        shoot(1, "home", .home, fullHeight: true)

        model.dashboard.chartStyle = .bars
        model.dashboard.hovered = DashboardModel.chartWeeks - 1
        shoot(2, "home-bars", .home, fullHeight: true)

        model.dashboard.hovered = nil
        model.updateOverride = update
        shoot(3, "home-update", .home, fullHeight: true)

        model.updateOverride = nil
        model.setupNeeded = true
        shoot(4, "home-setup", .home, fullHeight: true)
        model.setupNeeded = false

        shoot(5, "notes", .notes, fullHeight: true)
        shoot(6, "dictionary", .dictionary, fullHeight: true)

        Preferences.learnedWords = []
        model.dictionary.refresh()
        shoot(7, "dictionary-empty", .dictionary, fullHeight: true)
        Preferences.learnedWords = SampleData.words
        model.dictionary.refresh()

        shoot(8, "settings", .settings, fullHeight: true)

        model.settings.hasAnthropicKey = true
        model.settings.useClaude = true
        model.settings.keyStatus["openai"] = (true, "That key was not accepted.")
        model.updateOverride = update
        shoot(9, "settings-keys", .settings, fullHeight: true)
        model.updateOverride = nil
        model.settings.keyStatus["openai"] = nil

        return written
    }

    @MainActor
    private static func render(_ model: AppWindowModel, appearance: NSAppearance.Name, fullHeight: Bool, to url: URL) -> Bool {
        guard let look = NSAppearance(named: appearance) else { return false }
        let width = AppMetrics.defaultSize.width
        let root = AppShellView(model: model, snapshot: true)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = look
        var height = AppMetrics.defaultSize.height
        if fullHeight {
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            height = max(height, host.fittingSize.height)
        }
        // A real (off-screen) window, so AppKit controls (pickers, fields,
        // the chart's menu) draw for real instead of as placeholders.
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        // 2x, whatever screen (if any) the off-screen window is on.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: width, height: height)
        look.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        window.contentView = nil
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
