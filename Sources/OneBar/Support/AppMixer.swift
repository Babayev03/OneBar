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
    /// Ours are recognised by their UID.
    static let uidPrefix = "com.onebar.app.mixer."

    /// Whether an enumerated device is a mixer of ours rather than something to
    /// offer the user.
    ///
    /// `kAudioAggregateDeviceIsPrivateKey` hides a device from *other*
    /// processes, not from the one that created it, so every running mixer
    /// comes back through our own enumeration as a selectable output. Left in,
    /// they fill the picker with phantom entries and — because creating and
    /// destroying one changes the device list — each start or stop fires the
    /// device-list listener straight back into a rebuild. That feedback is what
    /// made holding a tap open look like the output select was refusing to
    /// change.
    static func isInternal(_ uid: String) -> Bool { uid.hasPrefix(uidPrefix) }

    /// Aggregates left by the removed output-groups feature. They live in the
    /// HAL, not in our storage, so uninstalling the feature does not take them
    /// with it — without this sweep they stay in every app's device list for
    /// ever, named after groups nothing can edit or delete any more.
    static func destroyLegacyGroupDevices() {
        let legacyPrefix = "com.onebar.app.group."
        for id in CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        ) {
            guard let uid = CoreAudioProperty.string(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ), uid.hasPrefix(legacyPrefix) else { continue }
            AudioHardwareDestroyAggregateDevice(id)
        }

        let definitions = ClipboardStore.shared.baseDirectory
            .appendingPathComponent("output-groups.json")
        try? FileManager.default.removeItem(at: definitions)
    }

    /// Where the level is heading, and where it is now. Jumping straight to a
    /// new gain steps the waveform, which is audible as a tick; exponential
    /// smoothing is not.
    private let target: UnsafeMutablePointer<Float>
    private let current: UnsafeMutablePointer<Float>
    private let renders: UnsafeMutablePointer<Int32>

    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?

    private(set) var processIDs: [AudioObjectID] = []
    private(set) var outputUIDs: [String] = []

    init() {
        target = .allocate(capacity: 1)
        target.initialize(to: 1)
        current = .allocate(capacity: 1)
        current.initialize(to: 0)
        renders = .allocate(capacity: 1)
        renders.initialize(to: 0)
    }

    /// The gain pointers must outlive the render block, and since teardown is
    /// now asynchronous "the block has stopped" is no longer true by the time
    /// `deinit` returns. So the same queue that destroys the IO proc frees
    /// them, strictly after — freeing them here would be a use-after-free on
    /// the audio thread for one last buffer.
    deinit {
        let tID = tapID
        let aggID = aggregateID
        let proc = procID
        let target = self.target
        let current = self.current
        let renders = self.renders
        tapID = 0
        aggregateID = 0
        procID = nil

        Self.teardownQueue.async {
            if aggID != 0 {
                if let proc {
                    AudioDeviceStop(aggID, proc)
                    AudioDeviceDestroyIOProcID(aggID, proc)
                }
                AudioHardwareDestroyAggregateDevice(aggID)
            }
            if tID != 0 {
                AudioHardwareDestroyProcessTap(tID)
            }
            target.deallocate()
            current.deallocate()
            renders.deallocate()
        }
    }

    var isRunning: Bool { procID != nil && aggregateID != 0 }
    /// Proof the loop is actually being pumped. "Started" only means the call
    /// returned; a device that never calls back looks identical from outside.
    var renderCount: Int { Int(renders.pointee) }

    func setGain(_ gain: Float) {
        target.pointee = max(0, min(gain, 4.0))
    }

    /// Releases both the aggregate device and the process tap cleanly.
    func stop() {
        let tID = tapID
        let aggID = aggregateID
        let proc = procID
        tapID = 0
        aggregateID = 0
        procID = nil
        processIDs = []
        outputUIDs = []

        guard aggID != 0 || tID != 0 else { return }
        Self.teardownQueue.async {
            if aggID != 0 {
                if let proc {
                    AudioDeviceStop(aggID, proc)
                    AudioDeviceDestroyIOProcID(aggID, proc)
                }
                AudioHardwareDestroyAggregateDevice(aggID)
            }
            if tID != 0 {
                AudioHardwareDestroyProcessTap(tID)
            }
        }
    }

    /// Stops the route and does not return until CoreAudio has released the
    /// wrapped output device. Most callers can use `stop()`, but changing the
    /// system default cannot race an aggregate that still owns the old output:
    /// some drivers simply reject or undo the default-device write in that
    /// window.
    func stopAndWait() async {
        let tID = tapID
        let aggID = aggregateID
        let proc = procID
        tapID = 0
        aggregateID = 0
        procID = nil
        processIDs = []
        outputUIDs = []

        guard aggID != 0 || tID != 0 else { return }
        await withCheckedContinuation { continuation in
            Self.teardownQueue.async {
                if aggID != 0 {
                    if let proc {
                        AudioDeviceStop(aggID, proc)
                        AudioDeviceDestroyIOProcID(aggID, proc)
                    }
                    AudioHardwareDestroyAggregateDevice(aggID)
                }
                if tID != 0 {
                    AudioHardwareDestroyProcessTap(tID)
                }
                continuation.resume()
            }
        }
    }

    /// - Parameters:
    ///   - processIDs: Audio processes to capture for this app.
    ///   - outputUIDs: Destination output device UIDs.
    ///   - gain: Initial gain multiplier (0.0 to 4.0).
    ///   - label: Names the device in the IORegistry.
    ///   - tapDriftCompensation: Whether the tap should be resampled against
    ///     the output's clock.
    @discardableResult
    func start(
        processIDs: [AudioObjectID],
        outputUIDs: [String],
        gain: Float,
        label: String,
        tapDriftCompensation: Bool
    ) -> Bool {
        guard !processIDs.isEmpty, !outputUIDs.isEmpty else {
            stop()
            return false
        }

        // If already running with identical process IDs and outputs, just update gain
        if isRunning, self.processIDs == processIDs, self.outputUIDs == outputUIDs {
            setGain(gain)
            return true
        }

        // Tear down any previous tap & aggregate before building the fresh pair
        stop()

        target.pointee = max(0, min(gain, 4.0))
        current.pointee = 0 // soft start from silence

        // Create process tap
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tapDesc.name = "OneBar \(label)"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.uuid = UUID()

        var newTapID = AudioObjectID(0)
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapStatus == noErr, newTapID != 0 else {
            return false
        }
        tapID = newTapID

        // Build aggregate device
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OneBar Mixer \(label)",
            kAudioAggregateDeviceUIDKey: AppMixer.uidPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUIDs[0],
            kAudioAggregateDeviceClockDeviceKey: outputUIDs[0],
            kAudioAggregateDeviceIsPrivateKey: true,
            // Match FineTune's wrapper exactly: even one ordinary physical
            // destination is stacked. This keeps the wrapper's clock/output
            // topology independent from macOS's default-device ownership.
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputUIDs.enumerated().map { index, uid in
                [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index > 0]
            },
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: tapDriftCompensation
                ]
            ]
        ]

        var device = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &device) == noErr,
              device != 0
        else {
            AudioHardwareDestroyProcessTap(newTapID)
            tapID = 0
            return false
        }
        aggregateID = device

        // The HAL returns the device before it is usable. Pumping the runloop
        // allows the HAL to finish setup.
        guard Self.waitUntilAlive(device) else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(newTapID)
            aggregateID = 0
            tapID = 0
            return false
        }

        renders.pointee = 0
        let target = self.target
        let current = self.current
        let renders = self.renders

        var id: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&id, device, nil) { _, input, _, output, _ in
            renders.pointee &+= 1

            let outputs = UnsafeMutableAudioBufferListPointer(output)
            guard !outputs.isEmpty else { return }
            for buffer in outputs {
                if let destination = buffer.mData {
                    memset(destination, 0, Int(buffer.mDataByteSize))
                }
            }

            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // Hardware input streams precede the one process tap in an
            // aggregate. The stereo-mixdown tap is therefore the final input
            // buffer regardless of how many output devices are stacked.
            guard let buffer = inputs.last else { return }
            guard let source = buffer.mData else { return }
            let inChannels = Int(buffer.mNumberChannels)
            guard inChannels > 0 else { return }

            let count = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * inChannels)
            let samples = source.assumingMemoryBound(to: Float.self)

            let goal = target.pointee
            var level = current.pointee
            let rampCoeff: Float = 0.001

            // FineTune SoftLimiter: 1:1 linear pass-through <= 0.95, asymptotic soft knee > 0.95
            let threshold: Float = 0.95
            let headroom: Float = 0.05

            for frame in 0..<count {
                if abs(goal - level) > 0.00001 {
                    level += (goal - level) * rampCoeff
                } else {
                    level = goal
                }

                var channelOffset = 0
                for outputBuffer in outputs {
                    guard let destination = outputBuffer.mData else {
                        channelOffset += Int(outputBuffer.mNumberChannels)
                        continue
                    }
                    let outChannels = Int(outputBuffer.mNumberChannels)
                    guard outChannels > 0 else { continue }
                    let frames = Int(outputBuffer.mDataByteSize)
                        / (MemoryLayout<Float>.size * outChannels)
                    guard frame < frames else {
                        channelOffset += outChannels
                        continue
                    }
                    let out = destination.assumingMemoryBound(to: Float.self)

                    for channel in 0..<outChannels {
                        // Stacked stereo destinations repeat L/R. The modulo
                        // also handles non-interleaved channel buffers without
                        // sending every one the left channel.
                        let sourceChannel = (channelOffset + channel) % inChannels
                        var sample = samples[frame * inChannels + sourceChannel] * level

                        let magnitude = abs(sample)
                        if magnitude > threshold {
                            let over = magnitude - threshold
                            let compressed = threshold + headroom * (over / (over + headroom))
                            sample = sample < 0 ? -compressed : compressed
                        }

                        out[frame * outChannels + channel] = sample
                    }
                    channelOffset += outChannels
                }
            }
            current.pointee = level
        }

        guard status == noErr, let id else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(newTapID)
            aggregateID = 0
            tapID = 0
            return false
        }
        Self.disableHardwareInputs(device: device, proc: id)

        guard AudioDeviceStart(device, id) == noErr else {
            AudioDeviceDestroyIOProcID(device, id)
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(newTapID)
            aggregateID = 0
            tapID = 0
            return false
        }

        procID = id
        self.processIDs = processIDs
        self.outputUIDs = outputUIDs
        return true
    }

    /// Tells the HAL this IO proc does not read the wrapped device's *hardware*
    /// input streams, so they are never switched on.
    private static func disableHardwareInputs(device: AudioObjectID, proc: AudioDeviceIOProcID) {
        let inputCount = CoreAudioProperty.streamCount(device, scope: kAudioObjectPropertyScopeInput)
        guard inputCount > 0 else { return }

        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: totalSize,
            alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment
        )
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(
            of: UInt32(inputCount),
            toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size,
            as: UInt32.self
        )
        let flags = raw.advanced(by: headerSize)
        for index in 0..<inputCount {
            flags.advanced(by: index * MemoryLayout<UInt32>.size)
                // This aggregate owns exactly one sub-tap, and CoreAudio places
                // it after every wrapped hardware input stream.
                .storeBytes(of: UInt32(index == inputCount - 1 ? 1 : 0), as: UInt32.self)
        }

        var address = CoreAudioProperty.address(
            kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(totalSize), raw)
    }

    private static let teardownQueue = DispatchQueue(
        label: "com.onebar.app.mixer.teardown",
        qos: .userInitiated
    )

    private static func waitUntilAlive(
        _ device: AudioObjectID,
        timeout: TimeInterval = 0.5,
        poll: TimeInterval = 0.005
    ) -> Bool {
        let address = CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        repeat {
            if CoreAudioProperty.value(device, address, seed: UInt32(0)) ?? 0 != 0 { return true }
            CFRunLoopRunInMode(.defaultMode, poll, false)
        } while CFAbsoluteTimeGetCurrent() < deadline
        return false
    }
}
