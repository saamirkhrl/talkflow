import AppKit
import Foundation

/// `talkflowd --pastetest`: proves Cmd+V/A/C/X/Z reach the app window's text
/// fields through the real main menu. Key events go in with
/// `NSApp.sendEvent`, the same path a physical keypress takes (window, then
/// the main menu's key equivalents, then the first responder), so a missing
/// or broken Edit menu fails here. Runs on throwaway settings, briefly opens
/// and activates the window, and puts the clipboard back afterwards. Never
/// touches the Keychain. Results in $TMPDIR/talkflow-pastetest.log.
enum PasteSelfTest {
    private static var lines: [String] = []
    private static var failures = 0

    private static var logURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-pastetest.log")
    }

    private static func pass(_ name: String) { lines.append("PASS \(name)") }
    private static func fail(_ name: String, _ detail: String = "") {
        failures += 1
        lines.append(detail.isEmpty ? "FAIL \(name)" : "FAIL \(name) (\(detail))")
    }
    private static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        if ok { pass(name) } else { fail(name, detail) }
    }
    private static func info(_ text: String) { lines.append("INFO \(text)") }

    static func run() -> Never {
        try? FileManager.default.removeItem(at: logURL)
        PreviewSandbox.enter()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        PreviewSandbox.useRepoIcon()
        // Production order: AppDelegate installs Edit first, MainMenu on show.
        EditMenu.install()

        // The event loop must be running for SwiftUI to lay out, so the test
        // is driven from a task started before app.run().
        Task { @MainActor in
            await drive()
            finish()
        }
        app.run()
        // Only reached if the event loop ended before the test finished.
        print("pastetest: event loop ended early")
        exit(1)
    }

    // MARK: - Pasteboard save and restore

    private typealias SavedItems = [[(NSPasteboard.PasteboardType, Data)]]

    private static func savePasteboard() -> SavedItems {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restorePasteboard(_ saved: SavedItems) {
        let board = NSPasteboard.general
        board.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
    }

    // MARK: - View helpers

    private static func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    private static func sleep(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private static func setPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static var pasteboardText: String? { NSPasteboard.general.string(forType: .string) }

    // MARK: - The test

    @MainActor
    private static func drive() async {
        let previous = NSWorkspace.shared.frontmostApplication
        let saved = savePasteboard()
        let controller = DashboardController(mode: .preview)
        var dictionaryField: NSTextField?

        await body(controller, &dictionaryField)

        // Cleanup on every path.
        controller.model.settings.openAIDraft = ""
        controller.model.settings.anthropicDraft = ""
        controller.model.dictionary.draft = ""
        dictionaryField?.stringValue = ""
        restorePasteboard(saved)
        // Not the preview's quit-on-close: finish() decides the exit.
        controller.onClose = nil
        controller.window?.close()
        PreviewSandbox.leave()
        previous?.activate(options: [])
    }

    @MainActor
    private static func body(_ controller: DashboardController, _ dictionaryField: inout NSTextField?) async {
        controller.show(.settings)
        var waited = 0
        while controller.window?.isKeyWindow != true && waited < 100 {
            await sleep(50)
            waited += 1
        }
        guard let window = controller.window, window.isKeyWindow else {
            fail("window never became key; menu path not exercised")
            return
        }
        await sleep(300)

        // Structure: the Edit menu in the real main menu.
        let main = NSApp.mainMenu
        let editItems = main?.item(withTitle: "Edit")?.submenu?.items ?? []
        let expected: [(String, Selector, String)] = [
            ("z", Selector(("undo:")), "undo:"), ("Z", Selector(("redo:")), "redo:"),
            ("x", #selector(NSText.cut(_:)), "cut:"), ("c", #selector(NSText.copy(_:)), "copy:"),
            ("v", #selector(NSText.paste(_:)), "paste:"), ("a", #selector(NSText.selectAll(_:)), "selectAll:"),
        ]
        for (key, action, name) in expected {
            let found = editItems.contains {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask.contains(.command) && $0.action == action
            }
            check(found, "Edit menu has Cmd+\(key) -> \(name)")
        }
        check(main?.item(withTitle: "Go") != nil, "Go menu exists")
        check(main?.item(withTitle: "Window") != nil, "Window menu exists")

        // Find the key fields.
        guard let content = window.contentView else { fail("window has no content view"); return }
        var views = allViews(content)
        let secure = views.compactMap { $0 as? NSSecureTextField }
        let plainCount = views.filter { $0 is NSTextField && !($0 is NSSecureTextField) }.count
        let openAI = secure.first { $0.placeholderString == "sk-..." }
        let anthropic = secure.first { $0.placeholderString == "sk-ant-..." }
        guard let openAI, let anthropic else {
            fail("key fields not found", "secure fields \(secure.count), other text fields \(plainCount)")
            return
        }
        pass("found both key fields")

        func press(_ key: String, keyCode: UInt16, shift: Bool = false) async {
            let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : [.command]
            if let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode
            ) {
                NSApp.sendEvent(event)
            }
            await sleep(150)
        }

        let providers: [(String, NSSecureTextField, String)] = [
            ("OpenAI", openAI, "talkflow-paste-check-openai"),
            ("Anthropic", anthropic, "talkflow-paste-check-anthropic"),
        ]
        for (name, field, token) in providers {
            guard window.makeFirstResponder(field) else { fail("\(name) key field takes focus"); continue }
            setPasteboard(token)
            await press("v", keyCode: 9)
            check(field.stringValue == token, "Cmd+V into \(name) key field", "length \(field.stringValue.count)")
            let draft = name == "OpenAI" ? controller.model.settings.openAIDraft : controller.model.settings.anthropicDraft
            check(draft == token, "\(name) draft updated", "length \(draft.count)")
            await press("a", keyCode: 0)
            let range = (window.firstResponder as? NSTextView)?.selectedRange()
            check(range == NSRange(location: 0, length: token.utf16.count), "Cmd+A selects all in \(name) field")

            // Copy and cut must not leak a secret to the clipboard.
            let sentinel = "talkflow-paste-sentinel"
            setPasteboard(sentinel)
            await press("c", keyCode: 8)
            check(pasteboardText == sentinel, "Cmd+C blocked in secure field, as macOS intends")
            await press("x", keyCode: 7)
            check(pasteboardText == sentinel && field.stringValue == token, "Cmd+X blocked in secure field")
            await press("z", keyCode: 6)
            let after = field.stringValue
            info("Cmd+Z in secure field: \(after.isEmpty ? "field now empty" : after == token ? "unchanged" : "other")")
        }

        // A plain text field proves C, X and Z through the same menu.
        controller.show(.dictionary)
        await sleep(300)
        views = allViews(content)
        guard let plain = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && !($0 is NSSecureTextField) }) else {
            lines.append("SKIP no plain text field in Dictionary")
            return
        }
        dictionaryField = plain
        let word = "talkflowpastecheck"
        guard window.makeFirstResponder(plain) else { fail("Dictionary field takes focus"); return }
        setPasteboard(word)
        await press("v", keyCode: 9)
        check(plain.stringValue == word, "Cmd+V into plain field", "length \(plain.stringValue.count)")
        await press("a", keyCode: 0)
        let range = (window.firstResponder as? NSTextView)?.selectedRange()
        check(range == NSRange(location: 0, length: word.utf16.count), "Cmd+A selects all in plain field")
        setPasteboard("sentinel")
        await press("c", keyCode: 8)
        check(pasteboardText == word, "Cmd+C in plain field")
        setPasteboard("sentinel")
        await press("x", keyCode: 7)
        check(plain.stringValue.isEmpty && pasteboardText == word, "Cmd+X in plain field")
        await press("z", keyCode: 6)
        check(plain.stringValue == word, "Cmd+Z undo in plain field", "length \(plain.stringValue.count)")
    }

    @MainActor
    private static func finish() -> Never {
        lines.append(failures == 0 ? "ALL PASS" : "FAILED \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        print(lines.last ?? "")
        exit(failures == 0 ? 0 : 1)
    }
}
