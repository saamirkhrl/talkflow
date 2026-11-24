import Foundation

// The note taker's shared types: what is saved on disk, and the two seams
// (capture and the after-Stop pipeline) that the real audio code plugs into.
// The UI, NotesModel and the tests only ever see these, so the real capture
// and pipeline can be swapped in without touching a screen.

// MARK: - On disk

/// Written into every notes JSON file. Readers skip a file with a higher
/// version, so an older talkflow never misreads, or rewrites, notes that a
/// newer one saved.
enum NotesSchema {
    static let version = 1
}

/// The steps of writing notes after Stop, in the order the Writing screen
/// lists them.
enum WritingStep: String, Codable, CaseIterable, Equatable {
    /// Closing the two audio files (NotesModel, at Stop).
    case saving
    /// Speech to text, on this Mac (the pipeline).
    case transcribing
    /// Telling the other voices apart (the pipeline).
    case speakers
    /// Saving the transcript and deleting the audio (NotesModel); later
    /// also the summary.
    case finishing
}

/// What can still be done about a note whose writing failed.
enum RetryKind: String, Codable, Equatable {
    /// The audio is kept, so writing the notes can run again from it.
    case notes
    /// The transcript is saved and the audio gone; only the summary can be
    /// tried again (the summary part handles it).
    case summary
    /// Nothing to retry from. The note can only be deleted.
    case none
}

struct NoteFailure: Codable, Equatable {
    var step: WritingStep
    /// Plain words for the user, such as "The speech engine stopped." Never
    /// holds transcript text, names or titles, and is never logged.
    var message: String
    var retry: RetryKind
}

/// Where a note is in its life.
enum NoteState: Equatable {
    case recording
    case writing(WritingStep)
    case ready
    case failed(NoteFailure)

    /// Recording or writing: if no session owns it, talkflow quit or crashed
    /// part way (a leftover).
    var isUnfinished: Bool {
        switch self {
        case .recording, .writing: return true
        case .ready, .failed: return false
        }
    }
}

/// Flat on disk, `{"phase": "writing", "step": "transcribing"}`, so a later
/// version can add fields without breaking this one.
extension NoteState: Codable {
    private enum CodingKeys: String, CodingKey { case phase, step, failure }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .phase) {
        case "recording": self = .recording
        case "writing": self = .writing(try c.decode(WritingStep.self, forKey: .step))
        case "ready": self = .ready
        case "failed": self = .failed(try c.decode(NoteFailure.self, forKey: .failure))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .phase, in: c, debugDescription: "unknown phase \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recording:
            try c.encode("recording", forKey: .phase)
        case .writing(let step):
            try c.encode("writing", forKey: .phase)
            try c.encode(step, forKey: .step)
        case .ready:
            try c.encode("ready", forKey: .phase)
        case .failed(let failure):
            try c.encode("failed", forKey: .phase)
            try c.encode(failure, forKey: .failure)
        }
    }
}

struct NoteSpeaker: Codable, Equatable {
    /// "you" for the microphone; "s1", "s2", ... for the other voices,
    /// numbered by first appearance (NotesLogic.numberSpeakers).
    var key: String
    /// Set when the user renames this speaker; nil shows the default name
    /// ("You", "Speaker 1").
    var name: String?
}

/// note.json: everything the list and the header need, so the list never
/// reads a transcript.
struct NoteMeta: Codable, Equatable, Identifiable {
    var schemaVersion: Int = NotesSchema.version
    /// Also the folder's name (NoteStore.isValidID).
    var id: String
    /// As typed; empty shows "Untitled meeting".
    var title: String
    /// Whole seconds (NoteStore.create truncates), so it round-trips exactly
    /// through ISO 8601.
    var started: Date
    /// Seconds recorded. 0 until Stop.
    var duration: Double
    /// In order of first appearance in the transcript. Empty until the
    /// transcript is saved.
    var speakers: [NoteSpeaker]
    var state: NoteState
    /// How many action items the summary has; nil when there is no summary
    /// (the list says "Transcript only"). Written by the summary part.
    var actionItemCount: Int?
}

struct TranscriptTurn: Codable, Equatable {
    /// A NoteSpeaker key.
    var speaker: String
    /// Seconds from the start of the recording.
    var start: Double
    var end: Double
    var text: String
}

/// transcript.json.
struct Transcript: Codable, Equatable {
    var schemaVersion: Int = NotesSchema.version
    var turns: [TranscriptTurn]
}

/// summary.json, written by NoteAssistant once a reply has passed
/// NotesAI.validateSummary: every time in it is the start of a transcript turn.
struct NoteSummary: Codable, Equatable {
    struct ActionItem: Codable, Equatable {
        /// A NoteSpeaker key when the owner matched a speaker's name (so a
        /// rename follows), otherwise the name the model gave; "" for nobody.
        var owner: String
        var task: String
        /// The start of the transcript turn it points back to, in seconds.
        var time: Double
        var done: Bool
    }

    /// A decision or an open question, and the turn it points back to.
    struct Point: Codable, Equatable {
        var text: String
        var time: Double
    }

    var schemaVersion: Int = NotesSchema.version
    var summary: String
    /// Turn starts the summary paragraph relies on most.
    var summaryTimes: [Double]
    var actionItems: [ActionItem]
    var decisions: [Point]
    var openQuestions: [Point]
    /// "Anthropic" or "OpenAI".
    var provider: String
    /// The API model id, such as "claude-haiku-5-5".
    var model: String
    var written: Date
    /// 1 when written in one request; more when a long meeting was
    /// summarised in parts and then combined (NotesAI.split).
    var parts: Int
}

/// questions.json: the Ask history for one meeting. Written by the Ask part.
struct NoteQuestions: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var question: String
        var answer: String
        /// Transcript times the answer points back to, in seconds.
        var citations: [Double]
        var asked: Date
        var provider: String
        var model: String
    }

    var schemaVersion: Int = NotesSchema.version
    var entries: [Entry]
}

// MARK: - Pipeline output

/// One stretch of speech from the after-Stop pipeline, before assembly into
/// turns (NotesLogic.transcript(from:)).
struct SpeechPiece: Equatable {
    /// "you" for the microphone track. For the computer-audio track, the
    /// voice separator's own label (any string but "you"); NotesLogic
    /// renumbers those by first appearance.
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

// MARK: - Seam: capture

/// What the Recording screen draws, polled from the capture.
struct CaptureLevels: Equatable {
    /// Seconds since recording started.
    var elapsed: Double = 0
    /// The microphone ("You"), 0...1, already smoothed for drawing.
    var you: Double = 0
    /// The sound this Mac plays ("Everyone else"), 0...1.
    var others: Double = 0
    /// No computer audio has arrived for a while (all-zero samples), so the
    /// screen can say so instead of recording silence unnoticed.
    var noComputerAudio = false
    /// The other voices are being filtered out of the microphone because the
    /// user is on speakers; the screen shows the speakers hint.
    var echoHandlingActive = false
}

/// Recording a meeting: the microphone and the sound this Mac plays, as two
/// separate tracks. Used from the main thread only. The real one (a Core
/// Audio process tap, macOS 14.2 and later) is built separately; FakeCapture
/// drives the preview and the snapshots, UnbuiltCapture the live app until
/// then.
protocol MeetingCapture: AnyObject {
    /// Nil when recording can start now; otherwise one plain sentence that
    /// says why not and what to do (a permission missing, say). The macOS
    /// 14.2 check is NotesLogic's and happens before this is asked.
    var unavailableReason: String? { get }
    /// The microphone's name for the Recording screen, such as "MacBook Pro
    /// Microphone".
    var microphoneName: String { get }
    var isRecording: Bool { get }
    /// Starts writing both tracks as files into `folder` (the note's audio
    /// folder, which exists). Throws an error whose localizedDescription is
    /// plain words for the user.
    func start(into folder: URL) throws
    /// Polled about ten times a second while recording.
    func levels() -> CaptureLevels
    /// Stops and closes the files. Returns the seconds recorded.
    func stop() -> Double
}

// MARK: - Seam: the after-Stop pipeline

struct WritingProgress: Equatable {
    var step: WritingStep
    /// 0...1 within `step`.
    var fraction: Double
    /// An honest estimate of the seconds left for the whole job, or nil
    /// while it is not known yet. Never a made-up number.
    var secondsLeft: Double?
}

enum PipelineOutcome: Equatable {
    /// Speech from both tracks, and the recording's length in seconds as
    /// measured from the audio (0 if unknown).
    case finished(pieces: [SpeechPiece], duration: Double)
    case failed(NoteFailure)
}

/// The work after Stop: reads the audio files in `audioFolder`, transcribes
/// and tells the voices apart on this Mac, and hands back the pieces. It
/// reports `.transcribing` and `.speakers` progress only. It neither writes
/// the transcript nor deletes the audio: NotesModel does both, so the rule
/// "the audio goes the moment the transcript is saved" lives in one place.
/// Called on the main thread; calls `progress` and `completion` on the main
/// thread, `completion` exactly once (not after `cancel`).
protocol NotesPipeline: AnyObject {
    func run(audioFolder: URL, progress: @escaping (WritingProgress) -> Void,
             completion: @escaping (PipelineOutcome) -> Void)
    func cancel()
}

// MARK: - Screens

/// Which Notes screen shows.
enum NotesRoute: Equatable {
    case list
    /// The meeting being recorded, or its notes being written.
    case session
    case detail(String)
}

/// The tabs of one meeting.
enum NoteTab: String, CaseIterable, Hashable {
    case transcript = "Transcript"
    case summary = "Summary"
    case ask = "Ask"
}

/// The meeting being recorded, or the notes being written for it. Only one
/// at a time.
struct NotesSession: Equatable {
    enum Phase: Equatable {
        case recording(CaptureLevels)
        case writing(WritingProgress)
    }

    var noteID: String
    var phase: Phase
}

/// A heading on the Notes list and the meetings under it.
struct NoteGroup: Equatable {
    var title: String
    var notes: [NoteMeta]
}
