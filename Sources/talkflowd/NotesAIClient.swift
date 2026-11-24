import Foundation

// The network half of Summary and Ask for meeting notes: sends the requests NotesAI builds, reads the replies
// back through NotesAI's validators, and does the one automatic retry. The transport is a seam, so every path
// here runs in `--notestest` on canned replies (NotesAISamples) without a network or a key.
//
// Logs: counts, durations, categories, HTTP status codes and model ids only. Never transcript text, names,
// questions, answers, provider messages or keys.

/// Cancels one job. Cancelling stops all callbacks: after cancel(), completion is never called.
final class NotesCancel {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    /// Runs the action once; a second call does nothing.
    func cancel() {
        let run = action
        action = nil
        run?()
    }
}

protocol NotesTransport: AnyObject {
    /// Whole reply. completion once, on any queue.
    func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), URLError>) -> Void) -> NotesCancel
    /// Streamed reply: for a 2xx response onLine is called for each line of the body (any queue, in order), then
    /// completion(.success((response, nil))). For a non-2xx response no lines: completion(.success((response, body))).
    func stream(_ request: URLRequest, onLine: @escaping (String) -> Void,
                completion: @escaping (Result<(HTTPURLResponse, Data?), URLError>) -> Void) -> NotesCancel
}

// MARK: - The real transport

/// Refuses every redirect. A redirect would carry the key header to another host; refusing hands the 3xx back,
/// which is reported as a server error.
final class NotesNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Splits a byte stream into lines on 0x0A only (one trailing 0x0D dropped). bytes.lines also splits on U+0085,
/// U+2028 and U+2029, which may sit inside a JSON string and would break a data: line.
struct NotesLineSplitter {
    private var buffer: [UInt8] = []

    private mutating func take() -> String {
        if buffer.last == 0x0D { buffer.removeLast() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    /// Returns a finished line when `byte` is the newline, otherwise nil.
    mutating func feed(_ byte: UInt8) -> String? {
        if byte != 0x0A {
            buffer.append(byte)
            return nil
        }
        return take()
    }

    /// The last line when the stream ends without a newline; nil if nothing is left.
    mutating func finish() -> String? {
        buffer.isEmpty ? nil : take()
    }

    static func lines(_ chunks: [[UInt8]]) -> [String] {
        var splitter = NotesLineSplitter()
        var result: [String] = []
        for chunk in chunks {
            for byte in chunk {
                if let line = splitter.feed(byte) { result.append(line) }
            }
        }
        if let last = splitter.finish() { result.append(last) }
        return result
    }
}

/// URLSession on its own ephemeral session (no cache, no cookies, no redirects), so the transcript (in the
/// request body) is never cached to disk and the key header never follows a redirect to another host.
final class LiveNotesTransport: NotesTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: NotesNoRedirect(), delegateQueue: nil)
    }()

    /// Most of an error body that is read; a provider's error JSON is far smaller.
    private static let maxErrorBody = 65_536

    func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), URLError>) -> Void) -> NotesCancel {
        let task = LiveNotesTransport.session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure((error as? URLError) ?? URLError(.badServerResponse)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success((http, data ?? Data())))
        }
        task.resume()
        return NotesCancel { task.cancel() }
    }

    func stream(_ request: URLRequest, onLine: @escaping (String) -> Void,
                completion: @escaping (Result<(HTTPURLResponse, Data?), URLError>) -> Void) -> NotesCancel {
        // URLSession.bytes needs macOS 12, fine for the macOS 13 target.
        let task = Task {
            do {
                let (bytes, response) = try await LiveNotesTransport.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if !(200...299).contains(http.statusCode) {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                        if body.count >= LiveNotesTransport.maxErrorBody { break }
                    }
                    completion(.success((http, body)))
                    return
                }
                var splitter = NotesLineSplitter()
                for try await byte in bytes {
                    if let line = splitter.feed(byte) { onLine(line) }
                }
                if let last = splitter.finish() { onLine(last) }
                completion(.success((http, nil)))
            } catch let error as URLError {
                completion(.failure(error))
            } catch {
                completion(.failure(URLError(.cancelled)))
            }
        }
        return NotesCancel { task.cancel() }
    }
}

// MARK: - The client

final class NotesAIClient {
    let transport: NotesTransport
    let keyFor: (APIKeys.Provider) -> String?
    /// Injectable so tests do not wait: runs `body` after `seconds` on the main queue.
    var sleep: (Double, @escaping () -> Void) -> Void = { s, body in DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: body) }
    /// 0...1 s added to every automatic wait, so many Macs do not retry in step.
    var jitter: () -> Double = { Double.random(in: 0...1) }
    var now: () -> Date = Date.init
    /// Asked right before every send, retries included: false once "Use my key for meeting notes" is off or the
    /// provider's key is gone, so a running job stops instead of reusing the request it built at the start.
    /// NoteAssistant sets it from the real access check; tests and the test flags keep the default.
    var allowed: (NotesProvider) -> Bool = { _ in true }

    init(transport: NotesTransport, keyFor: @escaping (APIKeys.Provider) -> String?) {
        self.transport = transport
        self.keyFor = keyFor
    }

    static func live() -> NotesAIClient {
        NotesAIClient(transport: LiveNotesTransport(), keyFor: { APIKeys.key(for: $0) })
    }

    /// State shared by the callbacks of one job. Touched on the main queue only. `cancelled` and `finished`
    /// are what make completion run exactly once, and never after cancel().
    private class Job {
        var cancelled = false
        var finished = false
        var current: NotesCancel?
        var live: Bool { !cancelled && !finished }

        func cancel() {
            cancelled = true
            current?.cancel()
        }
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start))
    }

    // MARK: Summary

    private final class SummaryJob: Job {
        let access: NotesAccess
        let key: String
        let transcript: Transcript
        let speakers: [NoteSpeaker]
        let lines: [String]
        let ranges: [Range<Int>]
        let progress: (Int, Int) -> Void
        let completion: (Result<NoteSummary, NotesAIError>) -> Void
        let started = Date()
        var partSummaries: [NoteSummary] = []

        init(access: NotesAccess, key: String, transcript: Transcript, speakers: [NoteSpeaker], lines: [String],
             ranges: [Range<Int>], progress: @escaping (Int, Int) -> Void,
             completion: @escaping (Result<NoteSummary, NotesAIError>) -> Void) {
            self.access = access
            self.key = key
            self.transcript = transcript
            self.speakers = speakers
            self.lines = lines
            self.ranges = ranges
            self.progress = progress
            self.completion = completion
        }
    }

    /// progress(step, total): step 1...total while writing the parts; step total+1 while combining (total > 1 only).
    /// All callbacks on the main queue. completion exactly once unless cancelled.
    @discardableResult
    func writeSummary(access: NotesAccess, transcript: Transcript, speakers: [NoteSpeaker],
                      progress: @escaping (Int, Int) -> Void,
                      completion: @escaping (Result<NoteSummary, NotesAIError>) -> Void) -> NotesCancel {
        let early = Job()
        func failEarly(_ error: NotesAIError) {
            DispatchQueue.main.async {
                guard early.live else { return }
                early.finished = true
                print("talkflowd: notes: summary failed: \(error.category)")
                completion(.failure(error))
            }
        }

        // No key, or a key that is gone: no request is built, so nothing is sent.
        guard let key = keyFor(access.provider.keyProvider), !key.isEmpty else {
            failEarly(.noKey)
            return NotesCancel { early.cancel() }
        }
        let lines = NotesAI.transcriptLines(transcript.turns, speakers: speakers)
        if lines.isEmpty {
            failEarly(.malformed)
            return NotesCancel { early.cancel() }
        }
        let ranges: [Range<Int>]
        switch NotesAI.plan(lines: lines) {
        case .tooLong(let hours):
            failEarly(.tooLong(hours: hours))
            return NotesCancel { early.cancel() }
        case .single:
            ranges = [0..<lines.count]
        case .parts(let parts):
            ranges = parts
        }

        let job = SummaryJob(access: access, key: key, transcript: transcript, speakers: speakers, lines: lines,
                             ranges: ranges, progress: progress, completion: completion)
        DispatchQueue.main.async { self.writePart(job, index: 0) }
        return NotesCancel { job.cancel() }
    }

    private func failSummary(_ job: SummaryJob, _ error: NotesAIError) {
        guard job.live else { return }
        job.finished = true
        print("talkflowd: notes: summary failed: \(error.category)")
        job.completion(.failure(error))
    }

    /// One part at a time, never in parallel, so a long meeting does not burst into a rate limit.
    private func writePart(_ job: SummaryJob, index: Int) {
        guard job.live else { return }
        let total = job.ranges.count
        job.progress(index + 1, total)
        let partLines = Array(job.lines[job.ranges[index]])
        let tokens = partLines.reduce(0) { $0 + NotesAI.estimateTokens($1) + 1 }
        print("talkflowd: notes: summary: part \(index + 1) of \(total), about \(tokens) tokens")
        let request = NotesAI.summaryRequest(job.access, key: job.key, lines: partLines, part: index + 1, of: total)
        perform(request, provider: job.access.provider, job: job, attempt: 0) { [self] result in
            switch result {
            case .failure(let error):
                failSummary(job, error)
            case .success(let data):
                let parsed = NotesAI.replyText(job.access.provider, data: data).flatMap {
                    NotesAI.validateSummary($0, turns: job.transcript.turns, speakers: job.speakers,
                                            provider: job.access.provider, model: job.access.model,
                                            written: now(), parts: 1)
                }
                switch parsed {
                case .failure(let error):
                    failSummary(job, error)
                case .success(let summary):
                    job.partSummaries.append(summary)
                    if index + 1 < total {
                        writePart(job, index: index + 1)
                    } else if total == 1 {
                        succeed(job, summary)
                    } else {
                        combine(job)
                    }
                }
            }
        }
    }

    private func combine(_ job: SummaryJob) {
        guard job.live else { return }
        let total = job.ranges.count
        job.progress(total + 1, total)
        let request = NotesAI.combineRequest(job.access, key: job.key, parts: job.partSummaries, speakers: job.speakers)
        perform(request, provider: job.access.provider, job: job, attempt: 0) { [self] result in
            switch result {
            case .failure(let error):
                failSummary(job, error)
            case .success(let data):
                let parsed = NotesAI.replyText(job.access.provider, data: data).flatMap {
                    NotesAI.validateSummary($0, turns: job.transcript.turns, speakers: job.speakers,
                                            provider: job.access.provider, model: job.access.model,
                                            written: now(), parts: total)
                }
                switch parsed {
                case .failure(let error): failSummary(job, error)
                case .success(let summary): succeed(job, summary)
                }
            }
        }
    }

    private func succeed(_ job: SummaryJob, _ summary: NoteSummary) {
        guard job.live else { return }
        job.finished = true
        print("talkflowd: notes: summary written: \(summary.parts) part(s), \(summary.actionItems.count) action items, "
              + "\(summary.decisions.count) decisions, \(summary.openQuestions.count) open questions, "
              + "\(NotesAIClient.seconds(since: job.started)) s, \(job.access.model.rawValue)")
        job.completion(.success(summary))
    }

    /// One whole (non-streamed) request, with one automatic retry for a short wait. `done` runs on the main
    /// queue, once, and never after a cancel.
    private func perform(_ request: URLRequest, provider: NotesProvider, job: Job, attempt: Int,
                         done: @escaping (Result<Data, NotesAIError>) -> Void) {
        // Asked before every send, retries included: the switch may go off or the key may be removed mid-job, and
        // the saved request still holds the key, so each send asks again.
        guard allowed(provider) else {
            DispatchQueue.main.async {
                guard job.live else { return }
                done(.failure(.noKey))
            }
            return
        }
        job.current = transport.send(request) { [self] result in
            DispatchQueue.main.async { [self] in
                guard job.live else { return }
                let error: NotesAIError
                let what: String
                switch result {
                case .failure(let urlError):
                    // Our own cancel comes back as .cancelled; nothing to report.
                    if urlError.code == .cancelled { return }
                    error = NotesAI.classify(urlError: urlError)
                    what = error.category
                case .success(let pair):
                    let (response, data) = pair
                    if (200...299).contains(response.statusCode) {
                        done(.success(data))
                        return
                    }
                    error = NotesAI.classify(status: response.statusCode, headers: NotesAIClient.headers(response),
                                             body: data, provider: provider, now: now())
                    what = String(response.statusCode)
                }
                if let wait = NotesAI.autoRetryWait(error, attempt: attempt) {
                    print("talkflowd: notes: HTTP \(what), one retry in \(Int(wait)) s")
                    sleep(wait + jitter()) { [self] in
                        guard job.live else { return }
                        perform(request, provider: provider, job: job, attempt: attempt + 1, done: done)
                    }
                } else {
                    done(.failure(error))
                }
            }
        }
    }

    /// Header names lowercased, because HTTP header names are case-insensitive and classify compares lowercase.
    private static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { result[key.lowercased()] = value }
        }
        return result
    }

    // MARK: Ask

    private final class AskJob: Job {
        let access: NotesAccess
        let request: URLRequest
        let turns: [TranscriptTurn]
        let question: String
        let onText: (String) -> Void
        let completion: (Result<NoteQuestions.Entry, NotesAIError>) -> Void
        let started = Date()
        var parser: NotesStreamParser
        var attempt = 0
        /// Bumped on each resend so late callbacks from the abandoned stream are ignored.
        var generation = 0

        init(access: NotesAccess, request: URLRequest, turns: [TranscriptTurn], question: String,
             onText: @escaping (String) -> Void, completion: @escaping (Result<NoteQuestions.Entry, NotesAIError>) -> Void) {
            self.access = access
            self.request = request
            self.turns = turns
            self.question = question
            self.onText = onText
            self.completion = completion
            self.parser = NotesStreamParser(provider: access.provider)
        }
    }

    /// onText: the whole answer so far (cumulative), main queue.
    @discardableResult
    func ask(access: NotesAccess, transcript: Transcript, speakers: [NoteSpeaker], history: [NoteQuestions.Entry],
             question: String, onText: @escaping (String) -> Void,
             completion: @escaping (Result<NoteQuestions.Entry, NotesAIError>) -> Void) -> NotesCancel {
        let early = Job()
        func failEarly(_ error: NotesAIError) {
            DispatchQueue.main.async {
                guard early.live else { return }
                early.finished = true
                print("talkflowd: notes: question failed: \(error.category)")
                completion(.failure(error))
            }
        }

        guard let key = keyFor(access.provider.keyProvider), !key.isEmpty else {
            failEarly(.noKey)
            return NotesCancel { early.cancel() }
        }
        let lines = NotesAI.transcriptLines(transcript.turns, speakers: speakers)
        if let tooLong = NotesAI.askTooLong(lines: lines, history: history) {
            failEarly(tooLong)
            return NotesCancel { early.cancel() }
        }
        let request = NotesAI.askRequest(access, key: key, lines: lines, history: history, question: question)
        let job = AskJob(access: access, request: request, turns: transcript.turns, question: question,
                         onText: onText, completion: completion)
        DispatchQueue.main.async { self.startStream(job) }
        return NotesCancel { job.cancel() }
    }

    private func startStream(_ job: AskJob) {
        guard job.live else { return }
        // Same reason as in perform: the saved request holds the key, so every send (retry too) asks again.
        guard allowed(job.access.provider) else { fail(job, .noKey); return }
        let generation = job.generation
        job.current = transport.stream(job.request, onLine: { [self] line in
            DispatchQueue.main.async { [self] in
                guard job.live, job.generation == generation else { return }
                for event in job.parser.feed(line) {
                    guard job.live, job.generation == generation else { return }
                    switch event {
                    case .text: job.onText(job.parser.text)
                    case .done: succeed(job)
                    case .failed(let error): failOrRetry(job, error)
                    }
                }
            }
        }, completion: { [self] result in
            DispatchQueue.main.async { [self] in
                guard job.live, job.generation == generation else { return }
                switch result {
                case .failure(let urlError):
                    if urlError.code == .cancelled { return }
                    failOrRetry(job, NotesAI.classify(urlError: urlError))
                case .success(let pair):
                    let (response, body) = pair
                    if !(200...299).contains(response.statusCode) {
                        failOrRetry(job, NotesAI.classify(status: response.statusCode,
                                                          headers: NotesAIClient.headers(response), body: body,
                                                          provider: job.access.provider, now: now()))
                    } else if !job.parser.finished, let error = job.parser.end() {
                        failOrRetry(job, error)
                    }
                }
            }
        })
    }

    /// Retries once, and only while no answer text has arrived: once the user has seen part of an answer, a
    /// second attempt would replace it with a different one.
    private func failOrRetry(_ job: AskJob, _ error: NotesAIError) {
        guard job.live else { return }
        if job.parser.text.isEmpty, let wait = NotesAI.autoRetryWait(error, attempt: job.attempt) {
            print("talkflowd: notes: \(error.category), one retry in \(Int(wait)) s")
            job.attempt += 1
            job.generation += 1
            job.current?.cancel()
            let generation = job.generation
            sleep(wait + jitter()) { [self] in
                guard job.live, job.generation == generation else { return }
                job.parser = NotesStreamParser(provider: job.access.provider)
                startStream(job)
            }
        } else {
            fail(job, error)
        }
    }

    private func fail(_ job: AskJob, _ error: NotesAIError) {
        job.finished = true
        job.current?.cancel()
        print("talkflowd: notes: question failed: \(error.category)")
        job.completion(.failure(error))
    }

    private func succeed(_ job: AskJob) {
        guard job.live else { return }
        let answer = job.parser.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty {
            failOrRetry(job, .malformed)
            return
        }
        job.finished = true
        let parsed = NotesAI.parseAnswer(answer, turns: job.turns)
        let entry = NoteQuestions.Entry(question: job.question, answer: answer, citations: parsed.times, asked: now(),
                                        provider: job.access.provider.name, model: job.access.model.rawValue)
        print("talkflowd: notes: question answered: \(parsed.times.count) citation(s), \(answer.count) characters, "
              + "\(NotesAIClient.seconds(since: job.started)) s, \(job.access.model.rawValue)")
        job.completion(.success(entry))
    }
}
