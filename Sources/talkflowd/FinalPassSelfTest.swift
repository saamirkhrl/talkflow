import Foundation

/// `talkflowd --finalpasstest [clip.wav]` - drives the on-demand final-pass
/// server (`FinalPassEngine`) the way holds do, against the real server and
/// model, and times it: the shortest hold, a release too early to wait for,
/// a stop while loading, a server that dies, and unloading once no hold or
/// final pass needs it. With a WAV, it is also transcribed by the loaded
/// server.
///
/// Run it from the installed app (the bundled engine and the app's settings).
/// It stops any final-pass server that is running, including the app's own;
/// the app starts another on its next hold.
enum FinalPassSelfTest {
    private static let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkflow-finalpasstest.log")

    private static func report(_ line: String) {
        print("finalpasstest: \(line)")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        }
    }

    static func run(wav: String?) -> Never {
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        // The engine's state lives on the main thread, so the steps run here
        // and hop onto it, while the main thread serves its queue.
        Thread.detachNewThread {
            let failures = steps(wav: wav)
            onMain { FinalPassEngine.stop() }
            report(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func onMain<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }

    /// `whenReady`, from this thread: whether it answered ready, and how long it took.
    private static func waitReady(timeout: TimeInterval) -> (ready: Bool, seconds: Double) {
        let semaphore = DispatchSemaphore(value: 0)
        var ready = false
        let started = Date()
        DispatchQueue.main.async {
            FinalPassEngine.whenReady(timeout: timeout) { ready = $0; semaphore.signal() }
        }
        semaphore.wait()
        return (ready, Date().timeIntervalSince(started))
    }

    private static var serverAnswers: Bool { SpeechEngine.isRespondingBlocking(port: FinalPassEngine.port) }

    private static var serverProcessExists: Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "\(FinalPassEngine.modelPath.path) --host 127.0.0.1 --port \(FinalPassEngine.port)"]
        pgrep.standardOutput = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    private static func steps(wav: String?) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ label: String, _ detail: String = "") {
            report((condition ? "ok   " : "FAIL ") + label + (detail.isEmpty ? "" : " -> " + detail))
            if !condition { failures += 1 }
        }
        func seconds(_ value: Double) -> String { String(format: "%.2fs", value) }

        check(Preferences.accurateFinalPass, "the accurate final pass is on")
        check(FinalPassEngine.modelIsComplete, "the final-pass model is downloaded")
        check(SpeechEngine.serverBinary() != nil, "there is a whisper-server", SpeechEngine.serverBinary() ?? "none")
        guard failures == 0 else { return failures }

        onMain { FinalPassEngine.stop() }
        check(!serverAnswers && !serverProcessExists, "starts with no final-pass server")

        // The shortest hold the app accepts (Dictation.minDuration, 0.3s):
        // the key goes down, and 0.3s later it comes up.
        let pressed = Date()
        onMain { FinalPassEngine.warmUp() }
        Thread.sleep(forTimeInterval: 0.3)
        let shortest = waitReady(timeout: FinalPassEngine.releaseWait)
        let load = Date().timeIntervalSince(pressed)
        check(shortest.ready, "a 0.3s hold gets the large model",
              "release waited \(seconds(shortest.seconds)), loaded \(seconds(load)) after the key went down")
        check(shortest.seconds < FinalPassEngine.releaseWait, "...within the release wait", seconds(FinalPassEngine.releaseWait))

        if let wav, let data = FileManager.default.contents(atPath: wav) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Transcriber.Result?
            Transcriber.transcribe(wav: data, serverURL: FinalPassEngine.inferenceURL, timeout: 8) { result = $0; semaphore.signal() }
            semaphore.wait()
            check(!(result?.text.isEmpty ?? true), "the loaded server transcribes",
                  result.map { "\(seconds($0.elapsed)): \($0.text)" } ?? "no answer")
        }

        let loaded = waitReady(timeout: FinalPassEngine.releaseWait)
        check(loaded.ready && loaded.seconds < 0.05, "a loaded server is ready at once", seconds(loaded.seconds))

        // Released before it could load: small.en takes this hold, and the
        // server keeps loading for the next one.
        onMain { FinalPassEngine.stop() }
        onMain { FinalPassEngine.warmUp() }
        let early = waitReady(timeout: 0.01)
        check(!early.ready, "a release before it loads falls back to small.en", seconds(early.seconds))
        let next = waitReady(timeout: 5)
        check(next.ready, "...and it finishes loading for the next hold", seconds(next.seconds))

        // Stopped while it was loading: nothing is left running.
        onMain { FinalPassEngine.stop() }
        onMain { FinalPassEngine.warmUp() }
        onMain { FinalPassEngine.stop() }
        Thread.sleep(forTimeInterval: 3)
        check(!serverAnswers && !serverProcessExists, "a stop while loading leaves no server behind")
        check(!onMain { FinalPassEngine.isReady }, "...and it is not marked ready")

        // A server that dies on its own: not ready any more, and the next
        // hold starts another.
        onMain { FinalPassEngine.warmUp() }
        _ = waitReady(timeout: 5)
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-9", "-f", "\(FinalPassEngine.modelPath.path) --host 127.0.0.1 --port \(FinalPassEngine.port)"]
        try? kill.run()
        kill.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        check(!onMain { FinalPassEngine.isReady }, "a server that died is no longer ready")
        let dead = waitReady(timeout: FinalPassEngine.releaseWait)
        check(!dead.ready, "...so a release goes straight to small.en", seconds(dead.seconds))
        onMain { FinalPassEngine.warmUp() }
        let again = waitReady(timeout: 5)
        check(again.ready, "...and the next hold loads it again", seconds(again.seconds))

        // Unloading once nothing needs it: no hold in progress and no final
        // pass waiting on it, for unloadDelay.
        let delay = FinalPassEngine.unloadDelay
        let gone = { !serverAnswers && !serverProcessExists && !onMain { FinalPassEngine.isReady } }

        // A hold that ends with no final pass (a discarded tap).
        onMain { FinalPassEngine.holdEnded() }
        Thread.sleep(forTimeInterval: delay - 1)
        check(serverAnswers, "still loaded \(Int(delay - 1))s after a hold with no final pass")
        Thread.sleep(forTimeInterval: 2)
        check(gone(), "...and unloaded \(Int(delay))s after it")

        // The release path: the hold ends, the final pass goes to the server.
        // It is not cut off however long it runs, and the server is unloaded
        // unloadDelay after it ends.
        onMain { FinalPassEngine.warmUp() }
        check(waitReady(timeout: 5).ready, "a hold after an unload loads it again")
        onMain { FinalPassEngine.holdEnded(); FinalPassEngine.passStarted() }
        if let wav, let data = FileManager.default.contents(atPath: wav) {
            let semaphore = DispatchSemaphore(value: 0)
            var result: Transcriber.Result?
            Transcriber.transcribe(wav: data, serverURL: FinalPassEngine.inferenceURL, timeout: 8) { result = $0; semaphore.signal() }
            semaphore.wait()
            check(!(result?.text.isEmpty ?? true), "...and its final pass is answered", result.map { seconds($0.elapsed) } ?? "no answer")
        }
        Thread.sleep(forTimeInterval: delay + 1.5)
        check(serverAnswers, "a final pass still running \(Int(delay + 1.5))s after release keeps it loaded")
        FinalPassEngine.passEnded()
        Thread.sleep(forTimeInterval: delay - 1)
        check(serverAnswers, "...for \(Int(delay - 1))s after the pass ends")
        Thread.sleep(forTimeInterval: 2)
        check(gone(), "...then unloaded \(Int(delay))s after it")

        // A tap (a hold that starts and ends) while a long final pass is still
        // running schedules an unload, which must not cut the pass off.
        onMain { FinalPassEngine.warmUp() }
        _ = waitReady(timeout: 5)
        onMain { FinalPassEngine.holdEnded(); FinalPassEngine.passStarted() }
        onMain { FinalPassEngine.warmUp(); FinalPassEngine.holdEnded() }
        Thread.sleep(forTimeInterval: delay + 1.5)
        check(serverAnswers, "a tap while a final pass runs does not unload it under the pass")
        FinalPassEngine.passEnded()
        Thread.sleep(forTimeInterval: delay + 1)
        check(gone(), "...it goes \(Int(delay))s after the pass")

        // The next hold starts while the last one's final pass is running:
        // the pass ending must not unload the server under the new hold.
        onMain { FinalPassEngine.warmUp() }
        _ = waitReady(timeout: 5)
        onMain { FinalPassEngine.holdEnded(); FinalPassEngine.passStarted() }
        onMain { FinalPassEngine.warmUp() }
        FinalPassEngine.passEnded()
        Thread.sleep(forTimeInterval: delay + 1.5)
        check(serverAnswers, "a pass that ends during the next hold leaves it loaded")
        onMain { FinalPassEngine.holdEnded() }
        Thread.sleep(forTimeInterval: delay + 1)
        check(gone(), "...until \(Int(delay))s after that hold")

        // A hold started inside unloadDelay keeps the loaded server: no reload.
        onMain { FinalPassEngine.warmUp() }
        _ = waitReady(timeout: 5)
        onMain { FinalPassEngine.holdEnded() }
        Thread.sleep(forTimeInterval: delay - 1)
        onMain { FinalPassEngine.warmUp() }
        let kept = waitReady(timeout: FinalPassEngine.releaseWait)
        Thread.sleep(forTimeInterval: 2)
        check(kept.ready && kept.seconds < 0.05 && serverAnswers, "a hold started \(Int(delay - 1))s after the last keeps it, ready at once",
              seconds(kept.seconds))
        onMain { FinalPassEngine.holdEnded() }
        Thread.sleep(forTimeInterval: delay + 1)
        check(gone(), "...and it goes \(Int(delay))s after that hold")
        check(onMain { !FinalPassEngine.holding && FinalPassEngine.passesInFlight == 0 }, "nothing is left holding it")
        return failures
    }
}
