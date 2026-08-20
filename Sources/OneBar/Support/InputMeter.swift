import AVFoundation
import CoreAudio
import Foundation

/// A live input level for one device.
///
/// There is no level property anywhere in the HAL — `VolumeDecibels` is the
/// knob's position, not the signal — so the only way to know how loud a
/// microphone is right now is to pull audio off it. That is what this does:
/// an IOProc on the device itself, rather than `AVAudioEngine`, whose input
/// node follows the *system* default and so cannot meter a device that isn't
/// the current one.
///
/// The cost is the point: running this opens the microphone, which lights the
/// orange dot in the menubar and puts OneBar in Control Center's recently-used
/// list for as long as it runs. Hence opt-in, and stopped the moment the Sound
/// screen goes away.
final class InputMeter {
    /// Smoothed peak, 0…1. Read on the main actor; written from the IO thread.
    private let level = Atomic()

    private var procID: AudioDeviceIOProcID?
    private var deviceID: AudioObjectID = 0

    /// Decay per callback. A peak meter that fell instantly would flicker
    /// unreadably; one that fell slowly would lag the voice.
    private static let falloff = 0.82

    var currentLevel: Double { level.value }

    var isRunning: Bool { procID != nil }

    /// Returns false when the device refuses to open — another process holding
    /// it in hog mode, or a Continuity mic that has wandered off.
    @discardableResult
    func start(device: AudioObjectID) -> Bool {
        stop()
        guard device != 0 else { return false }

        // The callback hands over the device's own stream format, and the
        // samples below are read as `Float`. Every HAL device on macOS uses
        // float, but reading anything else that way would be garbage.
        guard let format = CoreAudioProperty.value(
            device,
            CoreAudioProperty.address(
                kAudioStreamPropertyVirtualFormat,
                scope: kAudioObjectPropertyScopeInput
            ),
            seed: AudioStreamBasicDescription()
        ), format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return false }

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { [level] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: input)
            )
            var peak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    peak = max(peak, abs(samples[index]))
                }
            }
            level.decay(toward: Double(min(peak, 1)), by: Self.falloff)
        }

        guard status == noErr, let id else { return false }
        guard AudioDeviceStart(device, id) == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            return false
        }

        procID = id
        deviceID = device
        return true
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        deviceID = 0
        level.reset()
    }

    deinit { stop() }

    /// The IOProc runs on a real-time thread that must not block, and the menu
    /// reads the value on the main one. One `Double` behind a lock held for a
    /// single assignment is the cheapest correct thing here.
    private final class Atomic: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Double = 0

        var value: Double {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        /// Jump straight up to a new peak, ease back down from an old one.
        func decay(toward peak: Double, by factor: Double) {
            lock.lock()
            stored = max(peak, stored * factor)
            lock.unlock()
        }

        func reset() {
            lock.lock()
            stored = 0
            lock.unlock()
        }
    }
}
