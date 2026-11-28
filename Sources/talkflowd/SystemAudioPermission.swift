import CoreAudio
import Foundation

/// System Audio Recording, which meeting notes need. macOS has no public call
/// to read or request it, so this uses the TCC SPI looked up at run time
/// (never linked), with a Core Audio tap probe as the fallback way to raise
/// the prompt.
enum SystemAudioPermission {
    static let service = "kTCCServiceAudioCapture" as CFString
    /// Set false to never touch the TCC SPI (then status is always .unknown
    /// and request uses the probe).
    static let usesTCC = true
    /// If owner testing shows the System Audio Recording list accepts dragged
    /// apps, set true: the denied path then uses the drag panel instead of
    /// the "switch talkflow on" one.
    static let dragIntoList = false

    /// System audio recording exists from macOS 14.2.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    // MARK: TCC SPI

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightFunction: PreflightFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunction.self)
    }()

    private static let requestFunction: RequestFunction? = {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFunction.self)
    }()

    /// Read without asking. `.unknown` when this macOS cannot record system
    /// audio, or the SPI is not there.
    static func status() -> SystemAudioStatus {
        guard isSupported, usesTCC, let preflightFunction else { return .unknown }
        switch preflightFunction(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Raises macOS's prompt; `done` is called on the main thread.
    static func request(_ done: @escaping () -> Void) {
        guard isSupported else {
            done()
            return
        }
        if usesTCC, let requestFunction {
            requestFunction(service, nil) { _ in
                DispatchQueue.main.async(execute: done)
            }
        } else if #available(macOS 14.2, *) {
            probe(done)
        } else {
            done()
        }
    }

    // MARK: Probe

    private static let probeQueue = DispatchQueue(label: "talkflow.setup.audioprobe")

    private static func log(_ step: String, _ status: OSStatus) {
        print("talkflowd: setup audio probe: \(step) failed (\(status))")
    }

    /// Records two seconds of system audio into nothing, which makes macOS
    /// show its prompt the first time. Everything it makes is taken down again.
    @available(macOS 14.2, *)
    private static func probe(_ done: @escaping () -> Void) {
        probeQueue.async {
            var tap = AudioObjectID(kAudioObjectUnknown)
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            var proc: AudioDeviceIOProcID?
            var started = false

            func teardown() {
                if started, let proc { _ = AudioDeviceStop(aggregate, proc) }
                if let proc, aggregate != AudioObjectID(kAudioObjectUnknown) { _ = AudioDeviceDestroyIOProcID(aggregate, proc) }
                if aggregate != AudioObjectID(kAudioObjectUnknown) { _ = AudioHardwareDestroyAggregateDevice(aggregate) }
                if tap != AudioObjectID(kAudioObjectUnknown) { _ = AudioHardwareDestroyProcessTap(tap) }
            }
            func finish() { DispatchQueue.main.async(execute: done) }

            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            let tapUUID = UUID()
            description.uuid = tapUUID
            description.isPrivate = true
            description.muteBehavior = .unmuted

            let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
            guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
                log("creating the tap", tapStatus)
                tap = AudioObjectID(kAudioObjectUnknown)
                finish()
                return
            }

            let dictionary: [String: Any] = [
                kAudioAggregateDeviceNameKey: "talkflow setup",
                kAudioAggregateDeviceUIDKey: "talkflow-setup-" + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString]],
            ]
            let aggregateStatus = AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate)
            guard aggregateStatus == noErr, aggregate != AudioObjectID(kAudioObjectUnknown) else {
                log("creating the aggregate device", aggregateStatus)
                aggregate = AudioObjectID(kAudioObjectUnknown)
                teardown()
                finish()
                return
            }

            let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, _, _, _, _ in }
            guard procStatus == noErr, proc != nil else {
                log("creating the IOProc", procStatus)
                proc = nil
                teardown()
                finish()
                return
            }

            // The prompt appears here on first use.
            guard let ioProc = proc else { teardown(); finish(); return }
            let startStatus = AudioDeviceStart(aggregate, ioProc)
            guard startStatus == noErr else {
                log("starting the aggregate device", startStatus)
                teardown()
                finish()
                return
            }
            started = true

            probeQueue.asyncAfter(deadline: .now() + 2.0) {
                teardown()
                finish()
            }
        }
    }
}
