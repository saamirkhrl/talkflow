import Foundation

// Bounded live updates (LONG-HOLD-SPEC.md A9), run from `--streamtest`. Pure.
enum LongHoldChecks {
    static func run(_ check: (Bool, String, String) -> Void) {}
}
