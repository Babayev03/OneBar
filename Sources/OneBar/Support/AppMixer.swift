import AudioToolbox
import CoreAudio
import Foundation

/// Re-plays one tapped app at the level you asked for.
///
/// **One of these per app, deliberately.** A single shared mixer carrying every
/// tap was tried first and was wrong twice over: the taps arrive as input
/// streams and nothing guarantees they arrive in the order they were listed, so
/// with two apps the levels landed on each other's audio — Safari's 99% came
/// out of Music. And because the tap list is fixed when the device is created,
/// adding a second app tore down the device the first one was already playing
/// through, interrupting it. One tap per device makes the mapping trivially
/// right (there is only ever buffer zero) and keeps one app's changes away from
/// another's audio.
///
/// **The render block is real-time.** It runs on a thread with a deadline it
/// must not miss: no locks, no allocation, no Swift runtime calls, no logging.
/// That is why the gain lives in plain C memory rather than in a property — a
/// torn read of one `Float` costs one buffer at a slightly stale level, which
/// is inaudible, while a lock in here would be a click.
final class AppMixer {
    /// Where the level is heading, and where it is now. Jumping straight to a
    /// new gain steps the waveform, which is audible as a tick; a few
    /// milliseconds of ramp is not.
    private let target: UnsafeMutablePointer<Float>
    private let current: UnsafeMutablePointer<Float>
    private let renders: UnsafeMutablePointer<Int32>

    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    private(set) var tapUID = ""
    private(set) var outputUIDs: [String] = []

    init() {
        target = .allocate(capacity: 1)
        target.initialize(to: 1)
        current = .allocate(capacity: 1)
        current.initialize(to: 0)
        renders = .allocate(capacity: 1)
        renders.initialize(to: 0)
    }

    deinit {
        stop()
        target.deallocate()
        current.deallocate()
        renders.deallocate()
    }

    var isRunning: Bool { procID != nil }
    /// Proof the loop is actually being pumped. "Started" only means the call
    /// returned; a device that never calls back looks identical from outside.
    var renderCount: Int { Int(renders.pointee) }

    func setGain(_ gain: Float) {
        target.pointee = max(0, min(gain, 1))
    }

    @discardableResult
    func start(outputUIDs: [String], tapUID: String, gain: Float) -> Bool {
        stop()
        guard !outputUIDs.isEmpty, !tapUID.isEmpty else { return false }

        target.pointee = max(0, min(gain, 1))
        // From silence, so the app fades in rather than snapping on.
        current.pointee = 0

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OneBar App Mixer",
            kAudioAggregateDeviceUIDKey: "com.onebar.app.mixer.\(UUID().uuidString)",
            // Private: plumbing, not something to offer in a device list.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: 1,
            // Several devices when the output is a group: an aggregate cannot
            // hold another aggregate, so the group's members are mirrored here
            // instead. The first keeps time and the rest follow it, as in
            // `AggregateDevice.create`.
            kAudioAggregateDeviceMainSubDeviceKey: outputUIDs[0],
            kAudioAggregateDeviceSubDeviceListKey: outputUIDs.map {
                [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 == outputUIDs[0] ? 0 : 1]
            },
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: 1]
            ]
        ]

        var device = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &device) == noErr,
              device != 0
        else { return false }
        aggregateID = device

        renders.pointee = 0
        let target = self.target
        let current = self.current
        let renders = self.renders

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { _, input, _, output, _ in
            renders.pointee &+= 1

            let outputs = UnsafeMutableAudioBufferListPointer(output)
            guard let first = outputs.first, let destination = first.mData else { return }
            let outChannels = Int(first.mNumberChannels)
            guard outChannels > 0 else { return }

            memset(destination, 0, Int(first.mDataByteSize))
            let out = destination.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * outChannels)

            // Exactly one tap, so exactly one input buffer to care about.
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let buffer = inputs.first, let source = buffer.mData else { return }
            let inChannels = Int(buffer.mNumberChannels)
            guard inChannels > 0 else { return }

            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let count = min(frames, available)
            let samples = source.assumingMemoryBound(to: Float.self)

            let goal = target.pointee
            var level = current.pointee
            // ~5ms to cross the full range at 48kHz: fast enough to feel
            // instant, slow enough not to step the waveform.
            let step: Float = 1.0 / 240.0

            for frame in 0..<count {
                if level < goal { level = min(level + step, goal) }
                else if level > goal { level = max(level - step, goal) }

                for channel in 0..<outChannels {
                    // A mono tap feeds both sides rather than one.
                    let sourceChannel = min(channel, inChannels - 1)
                    out[frame * outChannels + channel] =
                        samples[frame * inChannels + sourceChannel] * level
                }
            }
            current.pointee = level
        }

        guard status == noErr, let id else {
            AudioHardwareDestroyAggregateDevice(device)
            aggregateID = 0
            return false
        }
        guard AudioDeviceStart(device, id) == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            AudioHardwareDestroyAggregateDevice(device)
            aggregateID = 0
            return false
        }

        procID = id
        self.tapUID = tapUID
        self.outputUIDs = outputUIDs
        return true
    }

    func stop() {
        if let procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = 0
        tapUID = ""
        outputUIDs = []
    }
}
