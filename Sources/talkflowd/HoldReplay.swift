import Foundation

/// `--holdreplay`: replays a WAV through HoldSession against a whisper-server (LONG-HOLD-SPEC.md C1).
enum HoldReplay {
    static func run(_ args: [String]) -> Never {
        print("holdreplay: not implemented")
        exit(2)
    }
}
