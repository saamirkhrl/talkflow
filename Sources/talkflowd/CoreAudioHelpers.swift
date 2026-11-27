import CoreAudio
import Foundation

// Thin Core Audio (HAL) property helpers for meeting capture, taken from the capture spike's AudioObjects.swift.
// Everything here can block while a System Audio Recording prompt is pending (capture spike), so callers run it
// on MeetingRecorder.controlQueue or the capture probe queue, never the main thread.

enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// A fixed-size property (scope global by default, element main). Returns the status and the value, or `def`
    /// when the read fails.
    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> (OSStatus, T) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        // Only plain C values (IDs, flags, ASBDs) are read through this, never object references.
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return (st, value)
    }

    /// CFString properties. The caller owns the returned reference, so takeRetainedValue.
    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ref)
        guard st == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// A variable-length list of object IDs; empty on error.
    static func objectArray(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var st = AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size)
        guard st == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &out)
        guard st == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown)).1
    }

    static func deviceUID(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }

    /// A device that has been unplugged reads as not alive (or fails to read, which also counts as not alive).
    static func isAlive(_ dev: AudioObjectID) -> Bool {
        get(dev, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)).1 != 0
    }

    static func transportType(_ dev: AudioObjectID) -> UInt32 {
        get(dev, kAudioDevicePropertyTransportType, default: UInt32(0)).1
    }

    /// The output data source (built-in speakers or the headphone jack); nil when the device has none.
    static func dataSource(_ dev: AudioObjectID) -> UInt32? {
        let (st, v) = get(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, default: UInt32(0))
        return st == noErr ? v : nil
    }

    /// Channels across all streams in one scope; 0 on error.
    static func channelCount(_ dev: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        // An AudioBufferList is variable length, so it is read into raw bytes of the size the HAL asked for.
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(raw.bindMemory(to: AudioBufferList.self, capacity: 1))
        var total = 0
        for b in abl { total += Int(b.mNumberChannels) }
        return total
    }

    /// The HAL's object for a process; kAudioObjectUnknown on error.
    @available(macOS 14.0, *)
    static func processObject(pid: pid_t) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &out)
        return st == noErr ? out : AudioObjectID(kAudioObjectUnknown)
    }

    /// Whether any other process is playing sound. capture spike limit (b): it did not flag an app playing digital
    /// silence through AVAudioEngine, so it is a hint for the computer-audio verdict, not proof.
    @available(macOS 14.0, *)
    static func othersPlaying() -> Bool {
        let me = getpid()
        for o in objectArray(system, kAudioHardwarePropertyProcessObjectList) {
            let running: UInt32 = get(o, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)).1
            guard running != 0 else { continue }
            let pid: pid_t = get(o, kAudioProcessPropertyPID, default: pid_t(-1)).1
            if pid != me { return true }
        }
        return false
    }
}

/// A property listener that can be removed: AudioObjectRemovePropertyListenerBlock needs the same block and queue.
/// Used on MeetingRecorder.controlQueue only.
final class CAListener {
    let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    /// Stored as the block type, so the very block that was added is the one removed.
    private let block: AudioObjectPropertyListenerBlock
    private var removed = false

    private init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
                 block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    /// Scope global, element main. Nil if the HAL refused the listener.
    static func add(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, queue: DispatchQueue,
                    _ handler: @escaping () -> Void) -> CAListener? {
        let addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let listener = CAListener(object: obj, address: addr, queue: queue, block: { _, _ in handler() })
        let st = AudioObjectAddPropertyListenerBlock(obj, &listener.address, queue, listener.block)
        guard st == noErr else {
            listener.removed = true
            return nil
        }
        return listener
    }

    /// Idempotent.
    func remove() {
        guard !removed else { return }
        removed = true
        _ = AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
