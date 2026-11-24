import Foundation

/// The two child processes Notes starts: the notes whisper-server (NotesEngine, port 8192) and the speaker helper
/// (SpeakerRun's `run`, NoteDownloads' `prepare`). A child does not die with talkflow on its own (measured for the
/// final-pass server: one outlived a deploy's SIGTERM with launchd as its new parent), so the app stops them at
/// quit and on SIGTERM, and stops any left by a crash at launch. Matched by their exact command lines, so the
/// live engine (8178), the final pass (8179) and anything else are never touched.
enum NotesProcesses {
    /// Pure. `command` is one `ps -o command=` line (argv joined by spaces).
    static func isLeftover(command: String, port: Int = NotesEngine.defaultPort, helperPath: String?) -> Bool {
        let engineTail = " --host 127.0.0.1 --port \(port) -nt"
        if command.contains(" -m "), command.hasSuffix(engineTail) || command.contains(engineTail + " ") { return true }
        if let h = helperPath, !h.isEmpty,
           command.hasPrefix(h + " run --models-dir ") || command.hasPrefix(h + " prepare --models-dir ") { return true }
        return false
    }

    /// Pure. Parses `ps -axww -o pid=,command=` output: each line is optional spaces, the pid, spaces, the command.
    /// Lines that do not start with a pid are skipped.
    static func parsePS(_ output: String) -> [(pid: Int32, command: String)] {
        var out: [(pid: Int32, command: String)] = []
        for raw in output.split(separator: "\n") {
            let line = raw.drop { $0 == " " }
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let pid = Int32(digits) else { continue }
            let rest = line.dropFirst(digits.count)
            guard rest.first == " " else { continue }
            let command = rest.drop { $0 == " " }
            guard !command.isEmpty else { continue }
            out.append((pid: pid, command: String(command)))
        }
        return out
    }

    /// Pure: the pids to stop, never `ownPID`.
    static func leftoverPIDs(_ list: [(pid: Int32, command: String)], port: Int = NotesEngine.defaultPort,
                             helperPath: String?, ownPID: Int32) -> [Int32] {
        list.filter { $0.pid != ownPID && isLeftover(command: $0.command, port: port, helperPath: helperPath) }.map { $0.pid }
    }

    /// Blocking (tens of milliseconds; up to 2 s more only when something had to be stopped). Lists processes with
    /// /bin/ps -axww -o pid=,command= (stdout through a Pipe, read to end, stderr to null), sends SIGTERM to each
    /// leftover, waits up to 2 s in 50 ms steps for them to go (kill(pid, 0) != 0 means gone), then SIGKILLs any
    /// still there. Returns how many were found. Prints only when n > 0; `reason` is a short category.
    @discardableResult
    static func stopLeftovers(reason: String, port: Int = NotesEngine.defaultPort,
                              helperPath: String? = SpeakerHelper.bundledBinary()?.path) -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return 0 }
        // Read to the end before waiting, so a full pipe can never block ps.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let list = parsePS(String(decoding: data, as: UTF8.self))
        let pids = leftoverPIDs(list, port: port, helperPath: helperPath, ownPID: ProcessInfo.processInfo.processIdentifier)
        guard !pids.isEmpty else { return 0 }
        for pid in pids { kill(pid, SIGTERM) }
        var waited = 0
        while waited < 2000, pids.contains(where: { kill($0, 0) == 0 }) {
            usleep(50_000)
            waited += 50
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        print("talkflowd: notes: stopped \(pids.count) leftover process(es) (\(reason))")
        return pids.count
    }
}
