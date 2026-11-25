import AppKit
import SwiftUI

/// The meeting being recorded, then its notes being written: one screen, as in the mockup, so Stop never jumps
/// anywhere. Opens the finished note by itself (NotesModel.finished).
struct NoteSessionPage: View {
    @ObservedObject var model: NotesModel
    var scrolls = true

    var body: some View {
        AppPage(maxWidth: 720, scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 26) {
                AppBackLink(title: "Notes") { model.backToList() }
                nameField
                if let problem = model.problem {
                    Text(problem)
                        .font(AppFont.caption)
                        .foregroundColor(Palette.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch model.session?.phase {
                case .recording(let l)?: recordingCard(l)
                case .writing(let p)?: writingCard(p)
                case nil: EmptyView()
                }
            }
        }
    }

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meeting name").font(AppFont.caption).foregroundColor(Palette.muted)
            TextField("Untitled meeting", text: $model.sessionTitle)
                .textFieldStyle(.plain)
                .font(AppFont.nameField)
                .foregroundColor(Palette.ink)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.field))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.ink.opacity(0.28), lineWidth: 1))
                .onSubmit { model.saveSessionTitle() }
                .accessibilityLabel("Meeting name")
        }
    }

    // MARK: - Recording

    private func recordingCard(_ l: CaptureLevels) -> some View {
        let mic = model.capture.microphoneName.isEmpty ? "Microphone" : model.capture.microphoneName
        return AppStageCard(spacing: 24) {
            HStack(alignment: .center, spacing: 16) {
                HStack(spacing: 14) {
                    Circle().fill(Palette.record).frame(width: 14, height: 14).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording").font(AppFont.caption).foregroundColor(Palette.muted)
                        Text(NotesLogic.timestamp(l.elapsed))
                            .font(AppFont.timer)
                            .monospacedDigit()
                            .foregroundColor(Palette.ink)
                            .accessibilityLabel("Recording time \(NotesLogic.timestamp(l.elapsed))")
                    }
                }
                Spacer(minLength: 16)
                Button("Stop and write notes") { model.stop() }
                    .buttonStyle(AppCapsuleButtonStyle(height: 40, weight: .semibold))
                    .help("Stops recording and writes the transcript on this Mac")
            }
            VStack(spacing: 14) {
                meter("You", mic, l.you, "Your microphone level")
                meter("Everyone else", "Sound from this Mac", l.others, "Computer audio level")
            }
            VStack(alignment: .leading, spacing: 0) {
                RowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = l.problem {
                        Text(problem)
                            .font(AppFont.caption)
                            .foregroundColor(Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = computerAudioNote(l) {
                        Text(note.text)
                            .font(AppFont.caption)
                            .foregroundColor(note.warn ? Palette.warn : Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if note.settings {
                            Button("Open System Settings") { NotesSystemSettings.openAudioRecording() }
                                .buttonStyle(.link)
                                .font(AppFont.caption)
                        }
                    }
                    if l.echoHandlingActive {
                        Text("You're on speakers, so talkflow is filtering the other voices out of your microphone.")
                            .font(AppFont.caption)
                            .foregroundColor(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    /// The line about the computer-audio track, chosen from what the capture has seen so far.
    private func computerAudioNote(_ l: CaptureLevels) -> (text: String, warn: Bool, settings: Bool)? {
        switch l.computerAudio {
        case .waitingForPermission:
            return ("Waiting for macOS to allow talkflow to record the sound from this Mac. If a message asks, choose Allow.", false, false)
        case .nothingPlaying:
            return ("Sound from this Mac: nothing playing yet.", false, false)
        case .notArriving:
            return ("No sound is arriving from this Mac, though an app is playing. talkflow may not be allowed to record it.", true, true)
        case .notAuthorised:
            return ("talkflow can't hear the sound from this Mac yet. If macOS asked, choose Allow. Otherwise turn on talkflow in System Settings > Privacy & Security > Screen & System Audio Recording.", true, true)
        case .starting, .receiving:
            // Older callers and the fakes only set noComputerAudio.
            if l.noComputerAudio {
                return ("No sound is coming from this Mac yet. If the call has started, check that it's playing on this Mac.", true, false)
            }
            return nil
        }
    }

    private func meter(_ name: String, _ detail: String, _ value: Double, _ label: String) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(AppFont.bodyMedium).foregroundColor(Palette.ink)
                Text(detail).font(AppFont.caption).foregroundColor(Palette.muted).lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            AppMeter(value: value)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
        }
    }

    // MARK: - Writing

    private func writingCard(_ p: WritingProgress) -> some View {
        let current = WritingStep.allCases.firstIndex(of: p.step) ?? 0
        return AppStageCard(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing your notes").font(AppFont.panelTitle).foregroundColor(Palette.ink)
                Text(NotesLogic.estimateText(p.secondsLeft))
                    .font(AppFont.body)
                    .foregroundColor(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AppMeter(value: NotesLogic.overallProgress(p))
                .accessibilityElement()
                .accessibilityLabel("Step \(current + 1) of \(WritingStep.allCases.count)")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(WritingStep.allCases.enumerated()), id: \.element) { i, step in
                    stepRow(i, step, current: current)
                }
            }
        }
    }

    private func stepRow(_ i: Int, _ step: WritingStep, current: Int) -> some View {
        let done = i < current
        let now = i == current
        let label = NotesLogic.stepLabel(step, duration: model.sessionDuration, done: done,
                                         summaryProvider: NotesKeys.provider())
        return HStack(spacing: 10) {
            marker(i, done: done, now: now).accessibilityHidden(true)
            if done {
                Text(label).font(AppFont.body).foregroundColor(Palette.ink)
                    + Text(" (done)").font(AppFont.body).foregroundColor(Palette.muted)
            } else if now {
                Text(label).font(AppFont.bodyMedium).foregroundColor(Palette.ink)
                    + Text(" (now)").font(AppFont.body).foregroundColor(Palette.muted)
            } else {
                Text(label).font(AppFont.body).foregroundColor(Palette.muted)
            }
        }
    }

    @ViewBuilder private func marker(_ i: Int, done: Bool, now: Bool) -> some View {
        if done {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.ink)
                .frame(width: 16)
        } else {
            Text("\(i + 1)")
                .font(AppFont.body)
                .foregroundColor(now ? Palette.ink : Palette.muted)
                .frame(width: 16)
        }
    }
}

/// System Settings > Privacy & Security > Screen & System Audio Recording, where System Audio Recording is turned on.
/// The anchor is the one macOS 14.2+ uses for that list; if a macOS version ignores it, the pane still opens at
/// Privacy & Security.
enum NotesSystemSettings {
    static func openAudioRecording() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
