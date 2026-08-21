import CoreAudio
import Foundation

/// The HAL exposes everything — device lists, names, volume, mute — through
/// one property call taking an address, a size and a raw pointer. Reading a
/// dozen of them across two scopes is otherwise a dozen
/// `withUnsafeMutablePointer` blocks, so they live here instead.
enum CoreAudioProperty {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// The only honest test of whether a device has a control. Registering a
    /// listener for a property a device doesn't have succeeds, and so does
    /// removing one that was never added — neither tells you anything.
    static func exists(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    /// A control that exists but can't be written is a level readout, and a
    /// slider that won't move is worse than no slider at all.
    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// `seed` is only there to fix `T` and give the call somewhere to write.
    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, seed: T) -> T? {
        var address = address
        var value = seed
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func setValue<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil, size, $0)
        }
        return status == noErr
    }

    /// Ask for the size, then ask again for the contents — the list length is
    /// only known to the HAL.
    static func objectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        // The header says the caller releases it, i.e. it arrives at +1 —
        // `takeRetainedValue` is what consumes that.
        let empty: Unmanaged<CFString>? = nil
        guard let value = value(object, address, seed: empty), let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Channels on a scope, which is how you tell an output device from an
    /// input one. `AudioBufferList` is variable-length, so it can't be read
    /// into a value — the buffer has to be sized from the HAL's own answer.
    static func channelCount(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// One registered property listener, alive as long as this object is.
///
/// The block is stored under a `@convention(block)` type on purpose. Swift
/// imports `AudioObjectPropertyListenerBlock` as an ordinary closure and
/// bridges it into a *fresh* Objective-C block at each call site, so adding and
/// removing with "the same closure" would register one block and then remove a
/// different one — silently, since the remove call returns `noErr` whether or
/// not it found anything.
final class CoreAudioListener {
    typealias Handler = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

    private let object: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let handler: Handler

    /// Fails when the HAL refuses the registration; it does *not* fail for a
    /// property the device hasn't got, so check `CoreAudioProperty.exists`
    /// before deciding a device has a control.
    init?(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping Handler
    ) {
        var address = address
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, handler) == noErr else { return nil }
        self.object = object
        self.address = address
        self.queue = queue
        self.handler = handler
    }

    deinit {
        var address = address
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, handler)
    }
}
