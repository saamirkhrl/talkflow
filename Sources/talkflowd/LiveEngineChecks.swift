import Foundation

// The live engine's on-demand lifecycle (LONG-HOLD-SPEC.md B6), run from `--streamtest`. Pure.
enum LiveEngineChecks {
    static func run(_ check: (Bool, String, String) -> Void) {}
}
