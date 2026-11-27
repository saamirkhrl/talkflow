import AppKit
import SwiftUI

/// The app window's palette, from the colours the dashboard and setup
/// already use (paper, ink, graphite). Separate names from setup's private
/// Color extension so the two never clash.
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha
            )
        })
    }

    static let window = dynamic(light: 0xF5F5F3, dark: 0x1F1E22)
    static let sidebar = dynamic(light: 0xEDEDEA, dark: 0x19181C)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x2A292F)
    static let field = dynamic(light: 0xFFFFFF, dark: 0x19181C)
    static let ink = dynamic(light: 0x1F1E22, dark: 0xF5F5F3)
    static let muted = dynamic(light: 0x5F5E66, dark: 0xA9A8AF)
    static let warn = dynamic(light: 0xB4541A, dark: 0xE8955A)
    static let cardStroke = dynamic(light: 0x1F1E22, dark: 0xF5F5F3, lightAlpha: 0.10, darkAlpha: 0)
    static let line = ink.opacity(0.12)
    static let hairline = ink.opacity(0.08)
    static let edge = ink.opacity(0.10)
    /// The recording dot on the page and on cards (the Notes mockups' red).
    static let record = dynamic(light: 0xD92D20, dark: 0xFF6B61)
    /// The dot on the filled Start recording button: that fill is ink, so the
    /// bright red sits on dark ink and the deep red on paper.
    static let recordOnFill = dynamic(light: 0xFF6B61, dark: 0xD92D20)
}

/// Serif (the system's New York) for the wordmark, page titles and big
/// numbers; the system sans for everything else.
enum AppFont {
    static let wordmark = Font.system(size: 24, weight: .regular, design: .serif)
    static let pageTitle = Font.system(size: 34, weight: .regular, design: .serif)
    static let hero = Font.system(size: 68, weight: .regular, design: .serif)
    static let stat = Font.system(size: 26, weight: .regular, design: .serif)
    static let panelTitle = Font.system(size: 28, weight: .regular, design: .serif)
    static let body = Font.system(size: 14)
    static let bodyMedium = Font.system(size: 14, weight: .medium)
    static let control = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let groupLabel = Font.system(size: 12, weight: .semibold)
    static let small = Font.system(size: 11)
    /// The meeting name field on the Recording screen.
    static let nameField = Font.system(size: 24, weight: .regular, design: .serif)
    /// The recording timer.
    static let timer = Font.system(size: 52, weight: .regular, design: .serif)
    /// Who spoke, beside each transcript turn.
    static let speaker = Font.system(size: 14, weight: .semibold)
    /// A section heading in the meeting's written notes.
    static let docHeading = Font.system(size: 20, weight: .regular, design: .serif)
    /// A meeting's title on its page: the serif face, smaller than a page title.
    static let noteTitle = Font.system(size: 24, weight: .regular, design: .serif)
}

enum AppMetrics {
    /// The transparent title bar the content runs under; the traffic
    /// lights sit in it, so the sidebar and pages start below it.
    static let titlebar: CGFloat = 28
    static let sidebarWidth: CGFloat = 220
    static let defaultSize = NSSize(width: 1040, height: 680)
    static let minSize = NSSize(width: 900, height: 600)
    static let pageTop: CGFloat = 36
    static let pageSide: CGFloat = 44
    static let pageBottom: CGFloat = 44
    static let cardRadius: CGFloat = 12
    static let rowH: CGFloat = 18
    static let rowV: CGFloat = 16
    /// Buttons and segments: at least the 28pt click target.
    static let controlHeight: CGFloat = 30
}

/// A page: padded, capped in width, scrolling unless drawn for a snapshot.
struct AppPage<Content: View>: View {
    let maxWidth: CGFloat
    let scrolls: Bool
    let top: CGFloat
    let content: Content

    init(maxWidth: CGFloat, scrolls: Bool, top: CGFloat = AppMetrics.titlebar + AppMetrics.pageTop,
         @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.scrolls = scrolls
        self.top = top
        self.content = content()
    }

    var body: some View {
        let inner = content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.top, top)
            .padding(.horizontal, AppMetrics.pageSide)
            .padding(.bottom, AppMetrics.pageBottom)
            .frame(maxWidth: .infinity, alignment: .leading)
        if scrolls {
            ScrollView { inner }
        } else {
            inner.frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// A rounded card holding rows; rows are separated with `RowDivider`.
struct AppCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.cardStroke, lineWidth: 1))
    }
}

struct RowDivider: View {
    var body: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }
}

/// The pointing hand over anything clickable in the window, as links have
/// on the web. Pushes and pops in pairs: a view that goes away while the
/// pointer is over it would otherwise leave the hand on screen.
private struct PointerCursor: ViewModifier {
    /// Whether this view has a hand pushed. A class under @StateObject
    /// rather than @State, which is a macro in this SDK (see Onboarding).
    private final class Pushed: ObservableObject { var on = false }

    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var pushed = Pushed()

    func body(content: Content) -> some View {
        content
            .onHover { inside in set(inside && isEnabled) }
            .onChange(of: isEnabled) { enabled in if !enabled { set(false) } }
            .onDisappear { set(false) }
    }

    private func set(_ on: Bool) {
        guard on != pushed.on else { return }
        pushed.on = on
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

extension View {
    func pointerCursor() -> some View { modifier(PointerCursor()) }
}

/// The one filled button on a row: ink with paper text, as the old
/// Update button was.
struct AppPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    /// Taller only where it sits beside a taller field (the Dictionary's 36pt one).
    var height: CGFloat = AppMetrics.controlHeight

    init(height: CGFloat = AppMetrics.controlHeight) { self.height = height }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isEnabled ? Palette.window : Palette.muted)
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(isEnabled ? Palette.ink.opacity(configuration.isPressed ? 0.75 : 1) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isEnabled ? Color.clear : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .pointerCursor()
    }
}

/// Every other button: an outline.
struct AppSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.body)
            .foregroundColor(isEnabled ? Palette.ink : Palette.muted)
            .padding(.horizontal, 16)
            .frame(minHeight: AppMetrics.controlHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(configuration.isPressed ? 0.06 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isEnabled ? Palette.ink.opacity(0.22) : Palette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .pointerCursor()
    }
}

/// Small underlined actions inside a row's text (Try again, the globe-key hint).
struct AppLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.caption)
            .underline()
            .foregroundColor(Palette.ink)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Rectangle())
            .pointerCursor()
    }
}

/// A text-only action that stays out of the way (Copy and Delete on a meeting): muted, no outline, a faint
/// fill while pressed.
struct AppQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.control)
            .foregroundColor(isEnabled ? (configuration.isPressed ? Palette.ink : Palette.muted) : Palette.muted.opacity(0.5))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.ink.opacity(configuration.isPressed ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .pointerCursor()
    }
}

/// The two big actions in Notes (Start recording, Stop and write notes): a
/// filled capsule, as the mockups draw them, at the app's control heights.
struct AppCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var height: CGFloat = 36
    var weight: Font.Weight = .medium

    init(height: CGFloat = 36, weight: Font.Weight = .medium) {
        self.height = height
        self.weight = weight
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: weight))
            .foregroundColor(isEnabled ? Palette.window : Palette.muted)
            .padding(.horizontal, 20)
            .frame(minHeight: height)
            .background(Capsule().fill(isEnabled ? Palette.ink.opacity(configuration.isPressed ? 0.75 : 1) : Color.clear))
            .overlay(Capsule().strokeBorder(isEnabled ? Color.clear : Palette.line, lineWidth: 1))
            .contentShape(Capsule())
            .pointerCursor()
    }
}

/// A level or progress bar: an 8pt track with an ink fill. `value` is 0...1.
struct AppMeter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.10))
                Capsule().fill(Palette.ink)
                    .frame(width: CGFloat(max(0, min(1, value.isFinite ? value : 0))) * geo.size.width)
            }
        }
        .frame(height: 8)
    }
}

/// "< Notes": back from a meeting to the list, as the mockups draw it.
struct AppBackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                Text(title).font(.system(size: 16, weight: .medium))
            }
            .foregroundColor(Palette.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 34)
        }
        .buttonStyle(BackLinkButtonStyle())
        .pointerCursor()
        .padding(.leading, -10)
        .accessibilityLabel("Back to \(title)")
    }
}

/// The back link's pressed fill, like the secondary button's.
private struct BackLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.ink.opacity(configuration.isPressed ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A bordered notice with no fill: the key banner, an interrupted recording,
/// a note that couldn't be finished. Text on the left, buttons on the right.
struct AppNotice<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(alignment: .center, spacing: 12) { content }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: AppMetrics.cardRadius).stroke(Palette.ink.opacity(0.14), lineWidth: 1))
    }
}

/// The big card of the Recording and Writing screens: rounder and roomier
/// than AppCard, as in the mockup.
struct AppStageCard<Content: View>: View {
    let spacing: CGFloat
    let content: Content
    init(spacing: CGFloat, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.cardStroke, lineWidth: 1))
    }
}

/// The switch, drawn: matches the palette in both appearances and renders
/// in `--dashboardshot`. A button underneath, so it takes keyboard focus,
/// and a real Toggle to VoiceOver.
struct AppToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Palette.ink : Color.clear)
                Capsule().strokeBorder(on ? Color.clear : Palette.ink.opacity(0.40), lineWidth: 1)
                Circle()
                    .fill(on ? Palette.window : Palette.muted)
                    .frame(width: 22, height: 22)
                    .padding(3)
            }
            .frame(width: 46, height: 28)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A segmented choice, drawn: the selected segment is paper-on-ink
/// inverted, as the old page switch was.
struct AppSegmented<Value: Hashable>: View {
    let label: String
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 14, weight: selected ? .medium : .regular))
                        .foregroundColor(selected ? Palette.window : Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.ink : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.window))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.cardStroke, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// "Soon", "Coming soon": a quiet outlined capsule.
struct AppPill: View {
    let text: String
    var font = AppFont.small
    var horizontal: CGFloat = 8
    var vertical: CGFloat = 1
    /// On an ink fill (the selected sidebar item).
    var inverted = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(inverted ? Palette.window.opacity(0.7) : Palette.muted)
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .overlay(Capsule().strokeBorder((inverted ? Palette.window : Palette.ink).opacity(0.22), lineWidth: 1))
    }
}

/// "Update to X.Y.Z", on Home's banner and Settings > About. Installing
/// is always this click; nothing installs on its own.
struct UpdateInstallButton: View {
    let release: Updater.Release
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button("Update to \(release.version)", action: action)
            .buttonStyle(AppPrimaryButtonStyle())
            .disabled(!enabled)
            .help(enabled
                  ? (Updater.keepsPermissions
                     ? "Downloads \(release.version), installs it and restarts talkflow. Permissions carry over."
                     : "Downloads \(release.version), installs it and restarts talkflow. macOS will ask for the microphone and Accessibility permissions again.")
                  : "Not available in a preview.")
    }
}

/// The talkflow mark drawn from the palette, so it stays visible on the dark
/// sidebar (the app icon is a dark tile that vanishes there). Geometry from
/// the app icon's 1024 grid.
struct AppLogo: View {
    var size: CGFloat = 26
    private let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [(159, 348, 328), (312, 231, 562), (466, 77, 870), (620, 231, 562), (773, 348, 328)]
    var body: some View {
        let s = size / 1024
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 230 * s).fill(Palette.ink)
            ForEach(0..<bars.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 46 * s).fill(Palette.window)
                    .frame(width: 92 * s, height: bars[i].h * s)
                    .offset(x: bars[i].x * s, y: bars[i].y * s)
            }
        }
        .frame(width: size, height: size, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
