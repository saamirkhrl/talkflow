import AppKit
import SwiftUI

// The setup window's content, drawn with the app's own tokens and components
// (Palette, AppFont, AppCard, the button styles), so it looks like the rest of
// talkflow. The model and the flow are in Onboarding.swift.

/// The switch itself, drawn (as a guide for the one in System Settings), so
/// it also renders in `--onboardingshot`.
private struct GuideSwitch: View {
    var body: some View {
        ZStack(alignment: .trailing) {
            Capsule().fill(Palette.ink).frame(width: 32, height: 19)
            Circle().fill(Palette.window).frame(width: 15, height: 15).padding(2)
        }
    }
}

/// An open arc that turns once a second: the "in progress" mark. Drawn
/// rather than a ProgressView so it renders in `--onboardingshot` too, and
/// driven by the clock (no @State, which is a macro in this SDK).
private struct Spinner: View {
    var size: CGFloat = 14

    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Palette.ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
    }
}

/// A dot that breathes while talkflow listens. Still with Reduce Motion on.
private struct PulseDot: View {
    var still: Bool
    var size: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: still)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            let level = still ? 1 : 0.55 + 0.45 * (0.5 + 0.5 * cos(phase * 2 * .pi))
            Circle()
                .fill(Palette.record)
                .frame(width: size, height: size)
                .opacity(level)
        }
        .frame(width: size, height: size)
    }
}

/// The practice field: a plain text view that takes the keyboard focus as
/// soon as it is on screen, so holding Fn types straight into it.
private struct PracticeTextView: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// The field took the focus once; after that it is the user's call.
        var focused = false
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if text.wrappedValue != view.string { text.wrappedValue = view.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        if let view = scroll.documentView as? NSTextView {
            view.delegate = context.coordinator
            view.drawsBackground = false
            view.isRichText = false
            view.allowsUndo = true
            view.font = .systemFont(ofSize: 14)
            view.textColor = .labelColor
            view.insertionPointColor = .labelColor
            view.textContainerInset = NSSize(width: 8, height: 9)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        // Into the field as soon as it is in a window, so holding Fn types
        // straight into it. Tried again on the next update until then.
        if !coordinator.focused {
            DispatchQueue.main.async {
                guard !coordinator.focused, let window = view.window else { return }
                coordinator.focused = window.makeFirstResponder(view)
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// For `--onboardingshot`: the practice field is drawn instead of being
    /// a live text view, which ImageRenderer cannot draw.
    var snapshot = false

    static let width: CGFloat = 560
    static let height: CGFloat = 580
    private let gutter: CGFloat = 40

    private var motion: Animation? { OnboardingMotion.animation(reduceMotion: model.reduceMotion) }

    /// The step dots: one per page of a first run. The engine page (only
    /// shown when the engine is still not ready by then) counts with Try it.
    private var pages: [OnboardingStep] {
        var list: [OnboardingStep] = [.welcome, .microphone, .accessibility, .tryIt]
        if model.notesSupported { list.append(.meetingNotes) }
        list.append(.done)
        return list
    }

    private static func page(of step: OnboardingStep) -> OnboardingStep {
        step == .engine ? .tryIt : step
    }

    var body: some View {
        Group {
            if model.needsMove { moveScreen } else { setupBody }
        }
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(Palette.window)
        .foregroundColor(Palette.ink)
    }

    private var hairline: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    // MARK: Frame

    private var setupBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, gutter)
                .padding(.top, 34)
            ZStack(alignment: .topLeading) {
                content
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 10)),
                        removal: .opacity))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, gutter)
            .padding(.top, 28)
            .animation(motion, value: model.step)
            Spacer(minLength: 12)
            hairline
            footer
                .padding(.horizontal, gutter)
                .padding(.vertical, 16)
        }
    }

    private var moveScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, gutter)
                .padding(.top, 34)
            VStack(alignment: .leading, spacing: 14) {
                title("Move talkflow to Applications.")
                paragraph("Then open it from there.")
            }
            .padding(.horizontal, gutter)
            .padding(.top, 28)
            Spacer(minLength: 12)
            hairline
            HStack(spacing: 16) {
                Button("Quit") { model.quit() }.buttonStyle(AppLinkButtonStyle())
                Spacer()
                Button("Open Applications") { model.openApplicationsFolder() }.buttonStyle(AppPrimaryButtonStyle())
            }
            .frame(height: 36)
            .padding(.horizontal, gutter)
            .padding(.vertical, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 26)
            Text("talkflow").font(AppFont.wordmark)
            Spacer()
            // Only on a first run, and not while the move is asked for.
            if model.firstRun && !model.needsMove { dots.animation(motion, value: model.step) }
        }
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(pages, id: \.self) { page in
                let current = Self.page(of: model.step) == page
                let mark = model.mark(page)
                Capsule()
                    .fill(current ? Palette.ink
                          : mark == .attention ? Palette.warn
                          : mark == .done ? Palette.ink.opacity(0.45) : Palette.ink.opacity(0.15))
                    .frame(width: current ? 18 : 6, height: 6)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            switch model.step {
            case .welcome, .tryIt, .meetingNotes:
                EmptyView()
            case .done:
                if model.loginItemAvailable {
                    HStack(spacing: 10) {
                        Toggle("Open talkflow when I log in", isOn: $model.launchAtLogin)
                            .toggleStyle(AppToggleStyle())
                            .labelsHidden()
                        Text("Open talkflow when I log in").font(AppFont.control)
                    }
                }
            case .microphone, .accessibility, .engine:
                if model.previousStep != nil {
                    Button("Back") { model.goBack() }.buttonStyle(AppLinkButtonStyle())
                }
            }
            Spacer()
            if model.step == .microphone || model.step == .accessibility { engineProgress }
            footerButtons
        }
        .frame(height: 36)
    }

    /// The download, from the permission pages, while it runs: the slow part
    /// of setup happens while the user deals with the permissions.
    @ViewBuilder
    private var engineProgress: some View {
        switch model.engine {
        case .working(_, let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    bar(fraction, height: 3).frame(width: 48)
                    Text("Speech engine \(Int(fraction * 100))%").monospacedDigit()
                } else {
                    Spinner(size: 11)
                    Text("Speech engine")
                }
            }
            .font(AppFont.small)
            .foregroundColor(Palette.muted)
            .fixedSize()
        case .ready:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.ink)
                Text("Speech engine ready")
            }
            .font(AppFont.small)
            .foregroundColor(Palette.muted)
            .fixedSize()
        case .checking, .needsSetup, .needsHomebrew, .failed:
            EmptyView()
        }
    }

    /// The footer buttons move between pages. A permission's own Allow
    /// button is on its row, where it is seen; Continue only shows once
    /// there is nothing left to do on the page.
    @ViewBuilder
    private var footerButtons: some View {
        switch model.step {
        case .welcome:
            Button("Get started") { model.goNext() }.buttonStyle(AppPrimaryButtonStyle())
        case .microphone, .accessibility, .engine:
            if model.canContinue {
                Button("Continue") { model.goNext() }.buttonStyle(AppPrimaryButtonStyle())
            }
        case .tryIt:
            if model.needsRestart {
                Button("Restart talkflow") { model.restartApp() }.buttonStyle(AppPrimaryButtonStyle())
            } else {
                Button("Continue") { model.goNext() }.buttonStyle(AppPrimaryButtonStyle())
            }
        case .meetingNotes:
            Button("Skip") { model.skipNotes() }.buttonStyle(AppSecondaryButtonStyle())
            if model.canContinue {
                Button("Continue") { model.goNext() }.buttonStyle(AppPrimaryButtonStyle())
            }
        case .done:
            Button("Done") { model.finish() }.buttonStyle(AppPrimaryButtonStyle())
        }
    }

    // MARK: Text

    /// "Fn", "Right Option": the shortcut as it is now. Setup never changes it.
    private var shortcut: String { model.shortcut.name }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(AppFont.pageTitle)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(AppFont.body)
            .foregroundColor(Palette.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func small(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(AppFont.caption)
            .foregroundColor(warn ? Palette.warn : Palette.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum Tone { case good, waiting, idle, warn, live }

    /// One status line: a mark and a sentence.
    private func statusLine(_ tone: Tone, _ text: String) -> some View {
        HStack(spacing: 8) {
            // Idle has no mark: an empty circle reads as a checkbox to click.
            if tone != .idle {
                Group {
                    switch tone {
                    case .good:
                        Image(systemName: "checkmark.circle.fill").foregroundColor(Palette.ink)
                    case .waiting:
                        Spinner()
                    case .warn:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Palette.warn)
                    case .live:
                        PulseDot(still: model.reduceMotion || snapshot, size: 9)
                    case .idle:
                        EmptyView()
                    }
                }
                .frame(width: 16, height: 16)
            }
            Text(text)
                .font(AppFont.body)
                .foregroundColor(tone == .warn ? Palette.warn : Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Said, not a button: nothing more to do here.
    private func doneLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(text)
        }
        .font(AppFont.bodyMedium)
        .foregroundColor(Palette.ink)
    }

    private func bar(_ fraction: Double, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.1))
                Capsule().fill(Palette.ink.opacity(0.7)).frame(width: max(height, geometry.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: height)
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            page("Hold \(shortcut), talk, let go.", "Your words appear wherever you type.") { languages }
        case .microphone:
            page("Let talkflow hear you.", "Your voice becomes text on this Mac.") {
                permissionCard(.microphone, target: .microphone, icon: "mic.fill", name: "Microphone")
            }
        case .accessibility:
            page("Let talkflow type for you.", "It types your words into the app you're using.") {
                permissionCard(.accessibility, target: .accessibility, icon: "accessibility", name: "Accessibility")
            }
        case .engine:
            page("Getting the speech engine ready.", "It runs on this Mac, so your voice stays here.") { engineCard }
        case .tryIt:
            tryIt
        case .meetingNotes:
            page("Want talkflow to take meeting notes too?", "It hears the other people in your calls through your Mac's sound.") {
                systemAudioCard
            }
        case .done:
            page("You're all set.", "Hold \(shortcut) in any app to dictate.") { EmptyView() }
        }
    }

    private func page<Body: View>(_ heading: String, _ text: String, @ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title(heading)
            paragraph(text)
            body().padding(.top, 10)
        }
    }

    /// The icon, name and one control of a row.
    private func rowHead<Control: View>(icon: String, name: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Palette.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(0.07)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(AppFont.bodyMedium)
                if let subtitle { Text(subtitle).font(AppFont.caption).foregroundColor(Palette.muted) }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, AppMetrics.rowH)
        .padding(.vertical, AppMetrics.rowV)
    }

    /// What sits under a row, after a divider.
    private func rowDetail<Detail: View>(@ViewBuilder _ detail: () -> Detail) -> some View {
        VStack(alignment: .leading, spacing: 10) { detail() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppMetrics.rowH)
            .padding(.vertical, 14)
    }

    // MARK: Permissions

    private enum PermissionDetail {
        case stale(StaleReason)
        case guiding(GuideMode)
        case manual
    }

    private func permissionDetail(_ service: Permissions.Service, target: GuideTarget) -> PermissionDetail? {
        switch model.status(service) {
        case .granted:
            return nil
        case .stale(let reason):
            return .stale(reason)
        case .missing:
            if model.guideShown.contains(target) { return .guiding(target == .accessibility ? .drag : .switchOn) }
            if model.guideFailed.contains(target) { return .manual }
            let waiting = service == .microphone ? model.microphone == .denied : model.isWaiting(service)
            return waiting ? .manual : nil
        }
    }

    private func permissionCard(_ service: Permissions.Service, target: GuideTarget, icon: String, name: String) -> some View {
        let status = model.status(service)
        let detail = permissionDetail(service, target: target)
        return AppCard {
            rowHead(icon: icon, name: name) {
                switch status {
                case .granted:
                    doneLabel("Allowed")
                case .stale:
                    Button(model.resetting == service ? "Resetting..." : "Reset and allow") { model.resetAndAskAgain(service) }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(model.resetting != nil)
                case .missing:
                    if case .guiding = detail {
                        EmptyView()
                    } else {
                        // After the first click macOS's prompt is used up, so the
                        // same button opens the pane; it says so.
                        let opensSettings = model.isWaiting(service) || (service == .microphone && model.microphone == .denied)
                        Button(opensSettings ? "Open Settings" : "Allow") { model.allow(service) }
                            .buttonStyle(AppPrimaryButtonStyle())
                    }
                }
            }
            if let detail {
                RowDivider()
                rowDetail {
                    switch detail {
                    case .stale(let reason):
                        staleFix(service, reason)
                    case .guiding(let mode):
                        statusLine(.waiting, mode == .drag
                                   ? "Drag \(model.appName) into the list."
                                   : "Switch \(model.appName) on in System Settings.")
                        Button("Open System Settings") { model.allow(service) }.buttonStyle(AppLinkButtonStyle())
                    case .manual:
                        switchOnGuide(service)
                        if service == .accessibility { small("Not listed? Add it with the + button.") }
                        Button("Already switched on?") { model.reportAlreadyOn(service) }.buttonStyle(AppLinkButtonStyle())
                    }
                }
            }
        }
    }

    /// What to look for in System Settings: the place, and the row with its
    /// switch on, drawn the way it looks there.
    private func switchOnGuide(_ service: Permissions.Service) -> some View {
        let guide = Onboarding.switchOn(service, appName: model.appName)
        return VStack(alignment: .leading, spacing: 8) {
            small("\(guide.action) in \(guide.place):")
            HStack(spacing: 10) {
                AppLogo(size: 18)
                Text(model.appName).font(AppFont.control)
                Spacer()
                GuideSwitch()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.window))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
        }
    }

    /// The permission is on in System Settings for an older copy of
    /// talkflow: say so and how to fix it. Reset is the row's button.
    @ViewBuilder
    private func staleFix(_ service: Permissions.Service, _ reason: StaleReason) -> some View {
        let help = Onboarding.staleHelp(service, reason)
        statusLine(.warn, "macOS is holding on to an older talkflow")
        small(help.why)
        if model.manualFixShown == service || model.resetFailed == service {
            small(help.fix)
        }
        if model.manualFixShown == service || model.resetFailed == service {
            Button("Open System Settings") { model.openSettings(service) }.buttonStyle(AppLinkButtonStyle())
        } else {
            Button("Fix it by hand") { model.manualFixShown = service }.buttonStyle(AppLinkButtonStyle())
        }
        if model.resetFailed == service {
            small("The reset did not work. Use the steps above in System Settings instead.", warn: true)
        }
    }

    private var systemAudioCard: some View {
        let granted = model.systemAudio == .granted
        let guiding = model.guideShown.contains(.systemAudio)
        let denied = model.systemAudio == .denied
        return AppCard {
            rowHead(icon: "speaker.wave.2.fill", name: "System audio") {
                if granted {
                    doneLabel("Allowed")
                } else if !guiding {
                    Button(denied ? "Open Settings" : "Allow") { model.allowSystemAudio() }
                        .buttonStyle(AppPrimaryButtonStyle())
                }
            }
            if !granted && (guiding || denied) {
                RowDivider()
                rowDetail {
                    if guiding {
                        statusLine(.waiting, "Switch \(model.appName) on in System Settings.")
                        Button("Open System Settings") { model.allowSystemAudio() }.buttonStyle(AppLinkButtonStyle())
                    } else {
                        statusLine(.idle, "Switch \(model.appName) on in System Settings.")
                    }
                }
            }
        }
    }

    // MARK: Welcome

    private static let languageRow: CGFloat = 46

    private var languages: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Languages").font(AppFont.groupLabel)
            AppCard {
                ForEach(Array(DictationLanguage.speakable.enumerated()), id: \.element) { index, language in
                    if index > 0 { RowDivider() }
                    languageRow(language)
                }
            }
        }
    }

    private func languageRow(_ language: DictationLanguage) -> some View {
        let ticked = model.language.spoken.contains(language)
        return Button {
            model.toggleSpoken(language)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(ticked ? Palette.ink : Color.clear)
                    RoundedRectangle(cornerRadius: 4).stroke(ticked ? Palette.ink : Palette.ink.opacity(0.35), lineWidth: 1.2)
                    if ticked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundColor(Palette.window)
                    }
                }
                .frame(width: 16, height: 16)
                Text(language.title).font(AppFont.body)
                Spacer()
                if language.needsMultilingualModel {
                    Text("190 MB").font(AppFont.small).foregroundColor(Palette.muted)
                }
            }
            .padding(.horizontal, AppMetrics.rowH)
            .frame(height: Self.languageRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Engine

    private var engineCard: some View {
        AppCard {
            rowHead(icon: "waveform", name: "Speech engine", subtitle: "One-time download, about 190 MB") {
                switch model.engine {
                case .ready:
                    doneLabel("Ready")
                case .needsSetup:
                    Button(model.engineOnlyStopped ? "Start" : "Set up") { model.runEngineSetup() }.buttonStyle(AppPrimaryButtonStyle())
                case .needsHomebrew, .failed:
                    Button("Try again") { model.runEngineSetup() }.buttonStyle(AppPrimaryButtonStyle())
                case .checking, .working:
                    Spinner(size: 15)
                }
            }
            if model.engine != .ready {
                RowDivider()
                rowDetail { engineDetail }
            }
        }
    }

    @ViewBuilder
    private var engineDetail: some View {
        switch model.engine {
        case .checking:
            small("Checking...")
        case .ready:
            EmptyView()
        case .needsSetup:
            small(model.engineNeeds)
        case .working(let message, let fraction):
            let lines = message.components(separatedBy: "\n")
            if let fraction {
                bar(fraction, height: 5)
                HStack {
                    small("\(Int(fraction * EngineSetup.modelMegabytes)) of \(Int(EngineSetup.modelMegabytes)) MB")
                        .monospacedDigit()
                    Spacer()
                    small(model.downloadTimeLeft ?? "Working out the time left")
                }
            } else {
                small(lines[0])
                if lines.count > 1 {
                    small(lines.dropFirst().joined(separator: "\n")).lineLimit(3)
                }
            }
        case .needsHomebrew:
            statusLine(.warn, "Homebrew is needed")
            small("The Whisper program is installed with Homebrew, which is not on this Mac yet. Install it from brew.sh, then come back and press Try again.")
            Button("Open brew.sh") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
                .buttonStyle(AppLinkButtonStyle())
        case .failed(let message):
            statusLine(.warn, "Setup did not finish")
            small(message, warn: true).lineLimit(5)
            if message.hasPrefix(EngineSetup.downloadStopped) {
                small("Check your internet connection, then press Try again. The download picks up where it stopped.")
            } else if message.hasPrefix(EngineSetup.homebrewFailed) {
                Text("Or in Terminal: brew install whisper-cpp")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Palette.muted)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = model.tryItPhase(at: context.date)
            VStack(alignment: .leading, spacing: 12) {
                title(phase == .success ? "That works." : "Try it.")
                paragraph(phase == .success
                          ? "Hold \(shortcut) in any app to dictate."
                          : "Hold \(shortcut), say something, then let go.")
                VStack(alignment: .leading, spacing: 12) {
                    practiceField(phase)
                    tryItStatus(phase)
                }
                .padding(.top, 10)
            }
            .animation(motion, value: phase)
        }
    }

    @ViewBuilder
    private func tryItStatus(_ phase: TryIt.Phase) -> some View {
        switch phase {
        case .restart:
            statusLine(.warn, "macOS needs talkflow to restart.")
        case .starting:
            statusLine(.waiting, "Getting \(shortcut) ready...")
        case .waiting:
            statusLine(.idle, "Ready when you are.")
        case .listening:
            statusLine(.live, "Let go when you are done.")
        case .writing:
            statusLine(.waiting, "Writing it down...")
        case .success:
            statusLine(.good, "It works.")
        case .nothingArrived:
            statusLine(.idle, "Nothing arrived. Hold \(shortcut) for the whole sentence.")
            globeKeyLink
        case .hint:
            statusLine(.idle, "Nothing yet? Keep \(shortcut) held while you speak.")
            globeKeyLink
        }
    }

    @ViewBuilder
    private var globeKeyLink: some View {
        if model.shortcut.usesFn && model.fnKeyHasSystemAction {
            Button("Globe key opens emoji? Set it to Do Nothing") { Permissions.openKeyboardSettings() }
                .buttonStyle(AppLinkButtonStyle())
        }
    }

    @ViewBuilder
    private func practiceField(_ phase: TryIt.Phase) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppMetrics.cardRadius)
        let border: Color = phase == .listening ? Palette.ink : Palette.line
        ZStack(alignment: .topLeading) {
            if snapshot {
                if !model.practice.isEmpty {
                    Text(model.practice)
                        .font(AppFont.body)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                }
            } else {
                PracticeTextView(text: $model.practice)
            }
            if model.practice.isEmpty {
                Text(phase == .listening ? "Speak now..." : "Your words appear here")
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted.opacity(0.7))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
        .background(shape.fill(Palette.field))
        .overlay(shape.stroke(border, lineWidth: phase == .listening ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if phase == .listening {
                HStack(spacing: 6) {
                    PulseDot(still: model.reduceMotion || snapshot, size: 7)
                    Text("Listening").font(AppFont.small).foregroundColor(Palette.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity)
            }
        }
    }
}
