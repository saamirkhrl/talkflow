import Foundation

/// What a hold needs from the live engine (port 8178). See design-reference/LONG-HOLD-SPEC.md B3.
protocol EngineGate: AnyObject {
    var isReady: Bool { get }
    func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void)
    func requestFailed()
}

/// One user of the live engine. `end()` is idempotent.
final class EngineLease {
    private var onEnd: (() -> Void)?
    init(_ end: @escaping () -> Void) { onEnd = end }
    func end() {
        let end = onEnd
        onEnd = nil
        end?()
    }
}

/// Interface stub; replaced by the on-demand lifecycle (LONG-HOLD-SPEC.md B2-B3).
final class LiveEngine: EngineGate {
    static let shared = LiveEngine()
    var isReady: Bool { true }
    func acquire(_ reason: String) -> EngineLease { EngineLease {} }
    func whenReady(timeout: TimeInterval, _ done: @escaping (Bool) -> Void) { done(true) }
    func requestFailed() {}
}
