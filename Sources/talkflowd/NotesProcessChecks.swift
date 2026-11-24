import Foundation

/// The notes child-process matcher (pure parts on fixed lines) and one live stop of a fake engine on a private
/// port, so no real engine can ever match.
enum NotesProcessChecks {
    static func run(_ report: (Bool, String, String) -> Void) {
        func check(_ ok: Bool, _ label: String, _ detail: String = "") { report(ok, label, detail) }
        let model = "/Users/x/Library/Application Support/talkflow/models/ggml-large-v3-turbo-q5_0.bin"
        func engine(_ port: Int) -> String {
            "/Applications/talkflow.app/Contents/Helpers/whisper-server -m \(model) --host 127.0.0.1 --port \(port) -nt"
        }
        check(NotesProcesses.isLeftover(command: engine(8192), helperPath: nil), "NP1 the notes engine command line on 8192 is a leftover")
        check(!NotesProcesses.isLeftover(command: engine(8178), helperPath: nil)
              && !NotesProcesses.isLeftover(command: engine(8179), helperPath: nil),
              "NP2 the live engine (8178) and the final pass (8179) are not leftovers")
        let h = "/Applications/talkflow.app/Contents/Helpers/talkflow-diarize"
        check(NotesProcesses.isLeftover(command: h + " run --models-dir /tmp/m --input /tmp/a.wav --output /tmp/o.json", helperPath: h)
              && NotesProcesses.isLeftover(command: h + " prepare --models-dir /tmp/m", helperPath: h)
              && !NotesProcesses.isLeftover(command: h + " check", helperPath: h)
              && !NotesProcesses.isLeftover(command: "/other/talkflow-diarize run --models-dir /tmp/m", helperPath: h),
              "NP3 the speaker helper's run and prepare lines match, other lines and paths do not")
        check(!NotesProcesses.isLeftover(command: "vim --host 127.0.0.1 --port 8192 -nt", helperPath: nil)
              && !NotesProcesses.isLeftover(command: "/usr/bin/whisper-server -m x --host 127.0.0.1 --port 81920 -nt", helperPath: nil),
              "NP4 a line without -m, or on port 81920, is not a leftover")
        let parsed = NotesProcesses.parsePS("  123 /bin/a -x\n4567 /usr/bin/b\nnot a line\n")
        check(parsed.count == 2 && parsed[0].pid == 123 && parsed[0].command == "/bin/a -x"
              && parsed[1].pid == 4567 && parsed[1].command == "/usr/bin/b",
              "NP5 ps output is parsed into pids and commands", "\(parsed.count)")
        let pids = NotesProcesses.leftoverPIDs([(10, engine(8192)), (11, engine(8192)), (12, "/bin/zsh")], helperPath: nil, ownPID: 11)
        check(pids == [10], "NP6 the leftover list skips our own pid and unrelated processes", "\(pids)")

        let label = "NP7 a leftover on the notes command line is stopped"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The compound command keeps sh from exec'ing sleep, so its own command line stays matchable.
        p.arguments = ["-c", "sleep 5; exit 0", "fake-notes-engine", "-m", "/tmp/talkflow-np-check.bin",
                       "--host", "127.0.0.1", "--port", "58192", "-nt"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            check(false, label, "could not start: \(type(of: error))")
            return
        }
        Thread.sleep(forTimeInterval: 0.3)
        let n = NotesProcesses.stopLeftovers(reason: "check", port: 58192, helperPath: nil)
        var waited = 0
        while p.isRunning, waited < 3000 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 50
        }
        let gone = !p.isRunning
        if !gone { p.terminate() }   // our own fake only; never reached when the stop works
        check(n >= 1 && gone, label, "found \(n), gone \(gone)")
    }
}
