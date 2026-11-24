import Foundation

/// Notes on disk: one folder per meeting under `root`
/// (~/Library/Application Support/talkflow/notes/<id>/):
///   note.json        NoteMeta
///   transcript.json  Transcript, once written
///   summary.json     NoteSummary (optional; the summary part writes it)
///   questions.json   NoteQuestions (optional; the Ask part writes it)
///   audio/           the two recorded tracks, only until the transcript is saved
/// The root is injected so tests and previews use a temporary folder.
struct NoteStore {
    let root: URL

    static var defaultRoot: URL { UserData.directory.appendingPathComponent("notes", isDirectory: true) }

    init(root: URL) {
        self.root = root
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private struct VersionProbe: Decodable { let schemaVersion: Int }

    /// The id is also the folder name, so this check is what keeps `delete`
    /// from ever removing anything outside `root`.
    static func isValidID(_ id: String) -> Bool {
        guard let r = id.range(of: "^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$", options: .regularExpression) else { return false }
        return r.lowerBound == id.startIndex && r.upperBound == id.endIndex
    }

    func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    func audioFolder(for id: String) -> URL {
        folder(for: id).appendingPathComponent("audio", isDirectory: true)
    }

    private func file(_ name: String, for id: String) -> URL {
        folder(for: id).appendingPathComponent(name)
    }

    // MARK: - Create, list, read

    func create(title: String, started: Date) throws -> NoteMeta {
        let whole = Date(timeIntervalSince1970: floor(started.timeIntervalSince1970))
        let fm = FileManager.default
        // Notes are private, so the folders are readable by this user only.
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: whole)
        var id: String
        repeat {
            id = stamp + "-" + String(format: "%04x", UInt16.random(in: .min ... .max))
        } while fm.fileExists(atPath: folder(for: id).path)
        try fm.createDirectory(at: audioFolder(for: id), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let meta = NoteMeta(id: id, title: title, started: whole, duration: 0, speakers: [],
                            state: .recording, actionItemCount: nil)
        try save(meta)
        return meta
    }

    func list() -> [NoteMeta] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let metas = names.filter { Self.isValidID($0) }.compactMap { meta($0) }
        // Unreadable folders are skipped, never deleted or rewritten.
        return metas.sorted {
            if $0.started != $1.started { return $0.started > $1.started }
            return $0.id > $1.id
        }
    }

    func meta(_ id: String) -> NoteMeta? {
        guard Self.isValidID(id) else { return nil }
        return read(NoteMeta.self, from: file("note.json", for: id))
    }

    func transcript(_ id: String) -> Transcript? {
        guard Self.isValidID(id) else { return nil }
        return read(Transcript.self, from: file("transcript.json", for: id))
    }

    func summary(_ id: String) -> NoteSummary? {
        guard Self.isValidID(id) else { return nil }
        return read(NoteSummary.self, from: file("summary.json", for: id))
    }

    func questions(_ id: String) -> NoteQuestions? {
        guard Self.isValidID(id) else { return nil }
        return read(NoteQuestions.self, from: file("questions.json", for: id))
    }

    // MARK: - Save

    func save(_ meta: NoteMeta) throws {
        try write(meta, name: "note.json", id: meta.id)
    }

    func save(_ transcript: Transcript, for id: String) throws {
        try write(transcript, name: "transcript.json", id: id)
    }

    func save(_ summary: NoteSummary, for id: String) throws {
        try write(summary, name: "summary.json", id: id)
    }

    func save(_ questions: NoteQuestions, for id: String) throws {
        try write(questions, name: "questions.json", id: id)
    }

    // MARK: - Audio

    func hasAudio(_ id: String) -> Bool {
        guard Self.isValidID(id) else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: audioFolder(for: id).path)) ?? []
        return entries.contains { !$0.hasPrefix(".") }
    }

    /// True when no audio remains. Checked after the removal, because the
    /// privacy rule is "verify the files are gone", not "asked for them to go".
    @discardableResult
    func deleteAudio(_ id: String) -> Bool {
        guard Self.isValidID(id) else { return false }
        let fm = FileManager.default
        let url = audioFolder(for: id)
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        return !fm.fileExists(atPath: url.path)
    }

    func delete(_ id: String) throws {
        guard Self.isValidID(id) else { throw NoteStoreError(message: "Not a note.") }
        try FileManager.default.removeItem(at: folder(for: id))
    }

    /// Notes that were recording or writing with no session owning them:
    /// talkflow quit or crashed part way.
    func leftovers(active: String?) -> [NoteMeta] {
        list().filter { $0.state.isUnfinished && $0.id != active }
    }

    // MARK: - Files

    private func write<T: Encodable>(_ value: T, name: String, id: String) throws {
        guard Self.isValidID(id) else { throw NoteStoreError(message: "Not a note.") }
        // A save never creates the note folder: if it is gone (deleted
        // meanwhile) the write must fail, so a late save can never bring a
        // deleted note back.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder(for: id).path, isDirectory: &isDir), isDir.boolValue else {
            throw NoteStoreError(message: "This note was deleted.")
        }
        // Encode first, so a failure never touches the file; then .atomic, which writes a temporary file and
        // renames it over the old one, so a crash leaves either the old note or the new, never half of one.
        let data = try Self.encoder.encode(value)
        try data.write(to: file(name, for: id), options: .atomic)
    }

    /// A file from a newer talkflow (higher schemaVersion) reads as nil, so
    /// an older one never misreads it.
    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let probe = try? Self.decoder.decode(VersionProbe.self, from: data),
              probe.schemaVersion <= NotesSchema.version else { return nil }
        return try? Self.decoder.decode(type, from: data)
    }
}

struct NoteStoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
