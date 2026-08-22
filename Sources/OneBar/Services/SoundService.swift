import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// System volume, mute, input gain and device switching, straight off the HAL.
///
/// Reads are cheap, but writes are kept off the main actor and coalesced
/// latest-wins. Output switching additionally coordinates with per-app mixers
/// so their private aggregates release the old device before the HAL default
/// changes.
///
/// Note that the volume keys go dead while Keyboard Cleaning is on — its event
/// tap swallows the `NX_SYSDEFINED` hardware-button subtypes by design (see
/// `KeyboardCleaningManager`). That is not this service's problem to solve, and
/// the volume keys must not be re-implemented off that tap.
@MainActor
@Observable
final class SoundService {
    static let shared = SoundService()

    /// Where a device's volume knob actually lives. "Has a volume control" is a
    /// property of a (selector, scope, element) triple, not of a device, so
    /// this is probed per device rather than assumed.
    enum VolumeControl: Equatable, Sendable {
        /// What Control Center drives. Synthetic, and it preserves the balance
        /// between channels for free.
        case virtualMain
        /// A real scalar on the main element.
        case main
        /// Per-channel scalars only — no main element to write.
        case channels([AudioObjectPropertyElement])
        /// HDMI, DisplayPort, most USB DACs, some AirPlay, and the Continuity
        /// iPhone microphone. The device runs at whatever level its own
        /// hardware is set to and nothing here can move it.
        case none
    }

    enum MuteControl: Equatable, Sendable {
        case main
        case channels([AudioObjectPropertyElement])
        case none
    }

    struct Device: Identifiable, Equatable {
        /// Recycled by the HAL across a boot — fine as a row identity for as
        /// long as the list is live, never persisted.
        let id: AudioObjectID
        /// Survives a replug, unlike `id`.
        let uid: String
        let name: String
        let icon: NSImage?
        /// Output or input. A device can appear in both lists with different
        /// controls on each side.
        let scope: AudioObjectPropertyScope
        let volumeControl: VolumeControl
        let muteControl: MuteControl
        var volume: Double
        var isMuted: Bool
        var isDefault: Bool

        var isAdjustable: Bool { volumeControl != .none }
        var canMute: Bool { muteControl != .none }

        static func == (lhs: Device, rhs: Device) -> Bool {
            lhs.id == rhs.id && lhs.uid == rhs.uid && lhs.name == rhs.name
                && lhs.scope == rhs.scope && lhs.volumeControl == rhs.volumeControl
                && lhs.muteControl == rhs.muteControl && lhs.volume == rhs.volume
                && lhs.isMuted == rhs.isMuted && lhs.isDefault == rhs.isDefault
        }
    }

    private(set) var outputs: [Device] = []
    private(set) var inputs: [Device] = []

    /// Smoothed input peak, 0…1, published only while the meter is running.
    private(set) var inputLevel: Double = 0
    /// Observed, unlike the timer behind it: a meter that has started but is
    /// looking at a silent room publishes nothing, and the bar still has to
    /// appear.
    private(set) var isMetering = false

    /// The HAL's callbacks arrive off the main actor, and never on a thread of
    /// ours if we pass `nil` (that runs on the HAL's own). A dedicated queue
    /// also keeps a burst of them off the main queue — the hop to `@MainActor`
    /// is needed either way.
    @ObservationIgnored private let queue = DispatchQueue(label: "com.onebar.app.sound")

    @ObservationIgnored private var systemListeners: [CoreAudioListener] = []
    /// Re-registered whenever a default changes; there is nothing to listen to
    /// on a device that is no longer the one playing or recording.
    @ObservationIgnored private var deviceListeners: [CoreAudioListener] = []

    /// Values and moments of our own last writes, keyed by device and scope so
    /// an input echo cannot be mistaken for an output echo (or vice versa).
    @ObservationIgnored private var lastWrites: [Target: (value: Double, at: Date)] = [:]

    /// Writes waiting to go down to the HAL, newest value per control only.
    @ObservationIgnored private var pending: [Target: PendingWrite] = [:]
    @ObservationIgnored private var activeWriteTargets: Set<Target> = []
    @ObservationIgnored private var draining = false
    /// Separate from `queue`, which delivers HAL notifications: a slow write
    /// must not hold up the echo of the one before it.
    @ObservationIgnored private let writeQueue = DispatchQueue(
        label: "com.onebar.app.sound.write",
        qos: .userInitiated
    )
    @ObservationIgnored private var valueSyncTask: Task<Void, Never>?
    @ObservationIgnored private var outputSwitchTask: Task<Void, Never>?

    /// Each device's own controls, cached at refresh rather than re-probed on
    /// every tick of a slider drag.
    @ObservationIgnored private var memberControls: [AudioObjectID: (VolumeControl, MuteControl)] = [:]
    @ObservationIgnored private var deviceIDsByUID: [String: AudioObjectID] = [:]
    @ObservationIgnored private var deviceIconCache: [String: NSImage] = [:]

    @ObservationIgnored private let meter = InputMeter()
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var meteredDevice: AudioObjectID = 0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard systemListeners.isEmpty else { return }

        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice
        ] {
            let listener = CoreAudioListener(
                object: AudioObjectID(kAudioObjectSystemObject),
                address: CoreAudioProperty.address(selector),
                queue: queue
            ) { _, _ in
                // Carry nothing across the hop: the address pointer is only
                // valid for the duration of this call.
                Task { @MainActor in SoundService.shared.scheduleRefresh() }
            }
            if let listener { systemListeners.append(listener) }
        }

        refresh()
    }

    func tearDown() {
        stopTracking()
        refreshTask?.cancel()
        refreshTask = nil
        valueSyncTask?.cancel()
        valueSyncTask = nil
        outputSwitchTask?.cancel()
        outputSwitchTask = nil
        systemListeners.removeAll()
        deviceListeners.removeAll()
        outputs = []
        inputs = []
    }

    // MARK: - Enumeration

    /// Coalesces a burst of HAL notifications into one pass.
    ///
    /// A Bluetooth connect fires the device-list, default-output and
    /// default-input properties within a few milliseconds of each other, and a
    /// full `refresh()` re-probes every device's controls. Answering each one
    /// separately also means enumerating while the HAL is still mid-change,
    /// which reads back half-built devices.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Synchronous and complete on return — unlike displays there is nothing to
    /// probe off-thread, every answer here is a local property read.
    func refresh() {
        guard AppState.shared.soundEnabled else {
            outputs = []
            inputs = []
            deviceListeners.removeAll()
            stopTracking()
            // Without this the tap outlives the feature: it goes on swallowing
            // every F10/F11/F12 press system-wide, while the handler behind it
            // finds `outputs` empty and does nothing. The keys would look
            // broken everywhere until Sound was switched back on.
            return
        }

        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let ids = CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        )

        deviceIDsByUID = [:]
        memberControls = [:]
        // Our own per-app mixers are aggregates too, and a private aggregate is
        // still visible to the process that made it — so they arrive here as
        // ordinary devices. Dropped before anything else looks at the list, or
        // every app playing through OneBar contributes a phantom output.
        var listable: [AudioObjectID] = []
        for id in ids {
            guard let uid = CoreAudioProperty.string(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ) else { continue }
            deviceIDsByUID[uid] = id
            guard !AppMixer.isInternal(uid) else { continue }
            listable.append(id)
            memberControls[id] = (
                volumeControl(for: id, scope: kAudioObjectPropertyScopeOutput),
                muteControl(for: id, scope: kAudioObjectPropertyScopeOutput)
            )
        }

        outputs = listable.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeOutput, isDefault: $0 == defaultOutput)
        }
        inputs = listable.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeInput, isDefault: $0 == defaultInput)
        }

        observeDefaults(output: defaultOutput, input: defaultInput)
        // Per-app rendering plays into the current output, so it follows a
        // change of device.
        AppAudioService.shared.outputDeviceChanged()

        // A meter left running on a device that is no longer the default would
        // be metering the wrong microphone, and holding it open for nothing.
        if meterTimer != nil, meteredDevice != defaultInput {
            stopTracking()
            startTracking()
        }
    }

    /// Cheap re-read of the values the menu cares about, for a notification
    /// missed during launch or across a wake.
    func refreshSystemValues() {
        guard AppState.shared.soundEnabled else { return }
        if outputs.isEmpty, inputs.isEmpty {
            refresh()
        } else {
            syncDeviceValues()
        }
    }

    private func device(
        id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        isDefault: Bool
    ) -> Device? {
        // Channels on the scope alone are not enough to list a device: the
        // Teams loopback driver has two output channels and cannot be made
        // default, and System Settings hides it for exactly that reason.
        guard CoreAudioProperty.channelCount(id, scope: scope) > 0,
              CoreAudioProperty.value(
                  id,
                  CoreAudioProperty.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: scope),
                  seed: UInt32(0)
              ) == 1,
              CoreAudioProperty.value(
                  id,
                  CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive, scope: scope),
                  seed: UInt32(0)
              ) == 1,
              let uid = CoreAudioProperty.string(
                  id,
                  CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
              )
        else { return nil }

        // `kAudioDevicePropertyDeviceNameCFString` is literally the same
        // selector under a deprecated name.
        let name = CoreAudioProperty.string(
            id,
            CoreAudioProperty.address(kAudioObjectPropertyName)
        ) ?? "Audio Device"

        let volumeControl = volumeControl(for: id, scope: scope)
        let muteControl = muteControl(for: id, scope: scope)

        return Device(
            id: id,
            uid: uid,
            name: name,
            icon: deviceIcon(for: id, uid: uid, name: name, scope: scope),
            scope: scope,
            volumeControl: volumeControl,
            muteControl: muteControl,
            volume: readVolume(id, scope: scope, control: volumeControl) ?? 0,
            isMuted: readMute(id, scope: scope, control: muteControl),
            isDefault: isDefault
        )
    }

    /// FineTune's display precedence: CoreAudio driver image first, then a
    /// name-aware SF Symbol, then a transport-aware generic symbol.
    private func deviceIcon(
        for id: AudioObjectID,
        uid: String,
        name: String,
        scope: AudioObjectPropertyScope
    ) -> NSImage? {
        if let cached = deviceIconCache[uid] { return cached }

        let icon: NSImage?
        var address = CoreAudioProperty.address(kAudioDevicePropertyIcon)
        var size = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        var iconURL: Unmanaged<CFURL>?
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &iconURL) == noErr,
           let url = iconURL?.takeRetainedValue() as URL?,
           let driverIcon = NSImage(contentsOf: url) {
            icon = driverIcon
        } else {
            let symbol = suggestedDeviceSymbol(for: id, name: name, scope: scope)
            icon = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        }

        if let icon { deviceIconCache[uid] = icon }
        return icon
    }

    private func suggestedDeviceSymbol(
        for id: AudioObjectID,
        name: String,
        scope: AudioObjectPropertyScope
    ) -> String {
        if name.contains("iPhone") { return "iphone" }
        if name.contains("iPad") { return "ipad" }
        if name.contains("AirPods Pro") { return "airpodspro" }
        if name.contains("AirPods Max") { return "airpodsmax" }
        if name.contains("AirPods") { return "airpods.gen3" }
        if name.contains("HomePod mini") { return "homepodmini" }
        if name.contains("HomePod") { return "homepod" }
        if name.contains("Apple TV") { return "appletv" }
        if name.contains("Beats") { return "beats.headphones" }
        if name.contains("Mac Studio") { return "macstudio.fill" }
        if name.contains("Mac mini") { return "macmini.fill" }
        if name.contains("MacBook") {
            return scope == kAudioObjectPropertyScopeInput ? "laptopcomputer" : "macbook"
        }
        if name.contains("iMac") { return "desktopcomputer" }
        if name.contains("Studio Display") || name.contains("Pro Display XDR") {
            return "display"
        }

        let transport = CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(kAudioDevicePropertyTransportType),
            seed: UInt32(0)
        ) ?? 0
        if scope == kAudioObjectPropertyScopeInput {
            return transport == kAudioDeviceTransportTypeUSB ? "cable.connector" : "mic"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "hifispeaker"
        case kAudioDeviceTransportTypeUSB: return "headphones"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        case kAudioDeviceTransportTypeThunderbolt: return "bolt.horizontal"
        case kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAggregate: return "speaker.wave.2"
        default: return "hifispeaker"
        }
    }

    private func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        CoreAudioProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(selector),
            seed: AudioObjectID(0)
        ) ?? 0
    }

    // MARK: - The volume ladder

    /// Each rung needs the property to exist *and* to be settable.
    private func volumeControl(for id: AudioObjectID, scope: AudioObjectPropertyScope) -> VolumeControl {
        // The `AudioHardwareService*` functions are deprecated; this selector
        // is not, and it answers through ordinary property calls.
        let virtual = CoreAudioProperty.address(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: scope
        )
        if CoreAudioProperty.exists(id, virtual), CoreAudioProperty.isSettable(id, virtual) {
            return .virtualMain
        }

        let main = CoreAudioProperty.address(kAudioDevicePropertyVolumeScalar, scope: scope)
        if CoreAudioProperty.exists(id, main), CoreAudioProperty.isSettable(id, main) {
            return .main
        }

        let channels = stereoChannels(for: id, scope: scope).filter { element in
            let address = CoreAudioProperty.address(
                kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: element
            )
            return CoreAudioProperty.exists(id, address) && CoreAudioProperty.isSettable(id, address)
        }
        return channels.isEmpty ? .none : .channels(channels)
    }

    private func muteControl(for id: AudioObjectID, scope: AudioObjectPropertyScope) -> MuteControl {
        let main = CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope)
        if CoreAudioProperty.exists(id, main), CoreAudioProperty.isSettable(id, main) {
            return .main
        }

        let channels = stereoChannels(for: id, scope: scope).filter { element in
            let address = CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope, element: element)
            return CoreAudioProperty.exists(id, address) && CoreAudioProperty.isSettable(id, address)
        }
        return channels.isEmpty ? .none : .channels(channels)
    }

    /// The device's own idea of which two elements are left and right; 1 and 2
    /// is only the usual answer, not a guaranteed one.
    private func stereoChannels(
        for id: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        let pair = CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope),
            seed: (UInt32(1), UInt32(2))
        ) ?? (1, 2)
        return [pair.0, pair.1]
    }

    // MARK: - Reading

    private func readVolume(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        control: VolumeControl
    ) -> Double? {
        switch control {
        case .virtualMain:
            return Self.scalar(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        case .main:
            return Self.scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope)
        case .channels(let elements):
            // The loudest channel is the level; a channel deliberately pulled
            // down is balance, not volume.
            let values = elements.compactMap {
                Self.scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0)
            }
            return values.max()
        case .none:
            return nil
        }
    }

    private func readMute(
        _ id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        control: MuteControl
    ) -> Bool {
        switch control {
        case .main:
            return CoreAudioProperty.value(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope),
                seed: UInt32(0)
            ) == 1
        case .channels(let elements):
            // Muted only when every channel is; one silent side is balance.
            return !elements.isEmpty && elements.allSatisfy { element in
                CoreAudioProperty.value(
                    id,
                    CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope, element: element),
                    seed: UInt32(0)
                ) == 1
            }
        case .none:
            return false
        }
    }

    nonisolated private static func scalar(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Double? {
        CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(selector, scope: scope, element: element),
            seed: Float32(0)
        ).map(Double.init)
    }

    // MARK: - Writing

    func setVolume(_ value: Double, for id: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard let (list, index) = locate(id, scope: scope) else { return }
        let clamped = min(max(value, 0), 1)
        let control = self[list][index].volumeControl

        guard control != .none else { return }

        self[list][index].volume = clamped
        let target = Target(id: id, scope: scope)
        lastWrites[target] = (clamped, Date())

        var job = pending[target] ?? PendingWrite()
        job.volume = clamped
        job.volumeControl = control

        // Control Center's own behaviour: turning it up is how you unmute.
        if clamped > 0, self[list][index].isMuted {
            let muteControl = self[list][index].muteControl
            if muteControl != .none {
                self[list][index].isMuted = false
                job.mute = false
                job.muteControl = muteControl
            }
        }

        pending[target] = job
        drain()
    }

    func setMuted(_ muted: Bool, for id: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard let (list, index) = locate(id, scope: scope) else { return }
        let control = self[list][index].muteControl
        guard control != .none else { return }

        self[list][index].isMuted = muted

        var job = pending[Target(id: id, scope: scope)] ?? PendingWrite()
        job.mute = muted
        job.muteControl = control
        pending[Target(id: id, scope: scope)] = job
        drain()
    }

    func toggleMute(for id: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard let (list, index) = locate(id, scope: scope) else { return }
        setMuted(!self[list][index].isMuted, for: id, scope: scope)
    }

    /// On output, app audio and alert sounds are two separate defaults and
    /// Sound Settings sets both — move only the first and your beeps keep
    /// coming out of the speakers you just switched away from. On input there
    /// is only the one default; the HAL has no system input.
    func makeDefault(_ id: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard scope == kAudioObjectPropertyScopeOutput else {
            CoreAudioProperty.setValue(
                AudioObjectID(kAudioObjectSystemObject),
                CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice),
                id
            )
            refresh()
            return
        }

        guard outputs.first(where: { $0.id == id })?.isDefault != true,
              outputSwitchTask == nil else { return }

        guard let target = outputs.first(where: { $0.id == id }) else { return }
        let targetUID = target.uid
        let bluetoothTarget = isBluetooth(uid: targetUID)
        let queue = writeQueue
        outputSwitchTask = Task { @MainActor in
            await AppAudioService.shared.prepareForSystemOutputChange()

            // Destroying a private aggregate returns before every device-list
            // notification has settled. The first default-device write in that
            // window is commonly ignored while an app is playing, especially
            // by Bluetooth drivers.
            try? await Task.sleep(
                for: .milliseconds(bluetoothTarget ? 220 : 70)
            )

            // Default-device writes can block just like volume writes, and the
            // menu should remain responsive while Bluetooth settles.
            let switched = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.setDefaultOutputVerified(
                        uid: targetUID,
                        fallbackID: id,
                        scope: scope,
                        bluetooth: bluetoothTarget
                    ))
                }
            }

            refresh()
            AppAudioService.shared.finishSystemOutputChange()
            if !switched {
                // A later device notification may make the target writable;
                // leave the service in a fully rebuilt state so the next click
                // is safe rather than stranded behind `outputSwitchTask`.
                scheduleRefresh()
            }
            outputSwitchTask = nil
        }
    }

    /// Resolve by UID after tearing aggregates down because HAL object IDs are
    /// only live handles. Write, read back, and retry a bounded number of times
    /// so one user click corresponds to one confirmed macOS output change.
    nonisolated private static func setDefaultOutputVerified(
        uid: String,
        fallbackID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        bluetooth: Bool
    ) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let outputAddress = CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        let systemAddress = CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice)

        for attempt in 0..<4 {
            let targetID = outputDeviceID(for: uid) ?? fallbackID
            let wrote = CoreAudioProperty.setValue(system, outputAddress, targetID)

            let canTakeSystem = CoreAudioProperty.value(
                targetID,
                CoreAudioProperty.address(
                    kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                    scope: scope
                ),
                seed: UInt32(0)
            ) == 1
            if canTakeSystem {
                _ = CoreAudioProperty.setValue(system, systemAddress, targetID)
            }

            usleep(useconds_t(bluetooth ? 90_000 : 35_000))
            let acceptedID = CoreAudioProperty.value(
                system,
                outputAddress,
                seed: AudioObjectID(0)
            ) ?? 0
            let acceptedUID = CoreAudioProperty.string(
                acceptedID,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            )
            if wrote, acceptedUID == uid { return true }

            if attempt < 3 {
                usleep(useconds_t(bluetooth ? 120_000 : 55_000))
            }
        }
        return false
    }

    nonisolated private static func outputDeviceID(for uid: String) -> AudioObjectID? {
        CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        ).first { id in
            CoreAudioProperty.string(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ) == uid
        }
    }

    /// A HAL write is *not* the free thing the top of this file once claimed.
    /// Measured on the main thread it is ~5ms to the built-in speakers, ~11ms
    /// to AirPods and ~17ms to a virtual driver, against a 16ms frame — so a
    /// slider drag posting one per tick stalled the UI outright. The writes
    /// therefore go off the main actor, latest-wins: `pending` never holds more than the newest
    /// value per control, so letting go of a slider leaves no backlog still
    /// draining into the device.
    ///
    /// This is `BrightnessService`'s coalescer with the timing turned around.
    /// There the point is that an I2C exchange *sleeps* for tens of
    /// milliseconds; here the point is only that the main thread must not be
    /// the one waiting. There is still no ramp to wait out and no lock.
    private struct Target: Hashable {
        let id: AudioObjectID
        let scope: AudioObjectPropertyScope
    }

    private struct PendingWrite {
        var volume: Double?
        var volumeControl: VolumeControl = .none
        var mute: Bool?
        var muteControl: MuteControl = .none
    }

    private func drain() {
        guard !draining else { return }
        draining = true

        Task { @MainActor in
            while let target = pending.keys.first {
                guard let job = pending.removeValue(forKey: target) else { continue }
                activeWriteTargets.insert(target)
                // Snapshotted per write, not once for the whole drain: a
                // device can appear or vanish mid-drag.
                let members = memberControls

                await withCheckedContinuation { continuation in
                    writeQueue.async {
                        if let volume = job.volume {
                            Self.writeVolume(
                                volume, to: target.id, scope: target.scope,
                                control: job.volumeControl, members: members
                            )
                        }
                        if let mute = job.mute {
                            Self.writeMute(
                                mute, to: target.id, scope: target.scope,
                                control: job.muteControl, members: members
                            )
                        }
                        continuation.resume()
                    }
                }

                // The echo comes back once the write has actually landed, so
                // the window that recognises it has to be measured from there
                // rather than from the moment the slider moved.
                activeWriteTargets.remove(target)
                if let volume = job.volume {
                    lastWrites[target] = (volume, Date())
                }
            }
            draining = false
        }
    }

    /// Sends one level to whichever control a device actually has.
    ///
    /// `static` and off the main actor because the write queue is what calls
    /// it, so the controls arrive as a snapshot rather than being read from
    /// `memberControls` here.
    nonisolated private static func writeVolume(
        _ value: Double,
        to id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        control: VolumeControl,
        members: [AudioObjectID: (VolumeControl, MuteControl)]
    ) {
        switch control {
        case .virtualMain:
            write(value, id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        case .main:
            write(value, id, kAudioDevicePropertyVolumeScalar, scope: scope)
        case .channels(let elements):
            // Scale each channel by its ratio to the loudest one, so a channel
            // the user pulled down stays proportionally down.
            let current = elements.map {
                Self.scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0) ?? 0
            }
            let peak = current.max() ?? 0
            for (element, level) in zip(elements, current) {
                let ratio = peak > 0.001 ? level / peak : 1
                write(value * ratio, id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            }
        case .none:
            break
        }
    }

    nonisolated private static func writeMute(
        _ muted: Bool,
        to id: AudioObjectID,
        scope: AudioObjectPropertyScope,
        control: MuteControl,
        members: [AudioObjectID: (VolumeControl, MuteControl)]
    ) {
        let value = UInt32(muted ? 1 : 0)
        switch control {
        case .main:
            CoreAudioProperty.setValue(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope),
                value
            )
        case .channels(let elements):
            for element in elements {
                CoreAudioProperty.setValue(
                    id,
                    CoreAudioProperty.address(kAudioDevicePropertyMute, scope: scope, element: element),
                    value
                )
            }
        case .none:
            break
        }
    }

    nonisolated private static func write(
        _ value: Double,
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        // Hog mode means another process owns the device and the write simply
        // fails. There is nothing useful to do about it and nothing to retry.
        CoreAudioProperty.setValue(
            id,
            CoreAudioProperty.address(selector, scope: scope, element: element),
            Float32(min(max(value, 0), 1))
        )
    }

    /// The UID of whatever is playing right now.
    var currentOutputUID: String {
        outputs.first { $0.isDefault }?.uid ?? outputs.first?.uid ?? ""
    }

    /// Physical destinations offered by the per-app route picker. An existing
    /// aggregate cannot be nested inside the private aggregate `AppMixer`
    /// creates; users can reproduce it explicitly with Multi instead.
    var routingOutputs: [Device] {
        outputs.filter { !isAggregate(uid: $0.uid) }
    }

    /// The device `AppMixer` has to render into. An array because a mixer can
    /// mirror to several at once, which is what per-app routing will use.
    var currentOutputDeviceUIDs: [String] {
        guard let device = outputs.first(where: { $0.isDefault }) ?? outputs.first else { return [] }
        return expandedOutputUIDs(device.uid)
    }

    private func isAggregate(uid: String) -> Bool {
        guard let id = deviceIDsByUID[uid] else { return false }
        let transport = CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(kAudioDevicePropertyTransportType),
            seed: UInt32(0)
        ) ?? 0
        return transport == kAudioDeviceTransportTypeAggregate
    }

    /// CoreAudio forbids aggregate-inside-aggregate. Flatten a system
    /// Multi-Output/Aggregate Device to the hardware UIDs `AppMixer` can wrap.
    private func expandedOutputUIDs(_ uid: String) -> [String] {
        guard isAggregate(uid: uid), let id = deviceIDsByUID[uid] else { return [uid] }
        let members = CoreAudioProperty.objectIDs(
            id,
            CoreAudioProperty.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        ).compactMap {
            CoreAudioProperty.string(
                $0,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            )
        }
        var seen: Set<String> = []
        return members.filter { seen.insert($0).inserted }
    }

    /// Whether a device is reached over Bluetooth, from the ids cached by the
    /// last `refresh()`. `kAudioDevicePropertyTransportType` answers in
    /// four-character codes; `'blue'` is classic and `'blea'` is LE.
    func isBluetooth(uid: String) -> Bool {
        guard let id = deviceIDsByUID[uid] else { return false }
        let transport = CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(kAudioDevicePropertyTransportType),
            seed: UInt32(0)
        ) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - The two lists as one

    private enum List { case output, input }

    private subscript(list: List) -> [Device] {
        get { list == .output ? outputs : inputs }
        set { if list == .output { outputs = newValue } else { inputs = newValue } }
    }

    private func locate(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> (List, Int)? {
        let list: List = scope == kAudioObjectPropertyScopeOutput ? .output : .input
        guard let index = self[list].firstIndex(where: { $0.id == id }) else { return nil }
        return (list, index)
    }

    // MARK: - Following the hardware

    private func observeDefaults(output: AudioObjectID, input: AudioObjectID) {
        deviceListeners.removeAll()

        // `vmvc` is synthetic and ought to fire `volm` as well, but two
        // listeners into one idempotent sync cost nothing and guessing wrong
        // costs a slider that doesn't move.
        let selectors = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute
        ]

        for (id, scope) in [
            (output, kAudioObjectPropertyScopeOutput),
            (input, kAudioObjectPropertyScopeInput)
        ] where id != 0 {
            for selector in selectors {
                let listener = CoreAudioListener(
                    object: id,
                    address: CoreAudioProperty.address(
                        selector,
                        scope: scope,
                        element: kAudioObjectPropertyElementWildcard
                    ),
                    queue: queue
                ) { _, _ in
                    Task { @MainActor in SoundService.shared.scheduleValueSync() }
                }
                if let listener { deviceListeners.append(listener) }
            }
        }
    }

    /// A virtual-main write can fire several property notifications. Debounce
    /// them into one read, and while a slider is moving let its optimistic
    /// value remain authoritative instead of re-rendering the whole card for
    /// every hardware echo.
    private func scheduleValueSync() {
        valueSyncTask?.cancel()
        valueSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            valueSyncTask = nil
            syncDeviceValues()
        }
    }

    /// Re-reads volume and mute for every listed device. Idempotent, so it does
    /// not matter how many listeners call it for one change.
    private func syncDeviceValues() {
        for list in [List.output, .input] {
            var devices = self[list]
            var changed = false
            for index in devices.indices {
                let device = devices[index]
                let target = Target(id: device.id, scope: device.scope)

                if let volume = readVolume(device.id, scope: device.scope, control: device.volumeControl),
                   abs(volume - device.volume) > 0.001,
                   !shouldIgnoreEcho(volume, for: target) {
                    devices[index].volume = volume
                    changed = true
                }

                let muted = readMute(device.id, scope: device.scope, control: device.muteControl)
                if muted != device.isMuted {
                    devices[index].isMuted = muted
                    changed = true
                }
            }
            if changed { self[list] = devices }
        }
    }

    /// The HAL fires our own writes straight back at us. Unlike DDC there is no
    /// ramp to wait out, so this is not `BrightnessService`'s blanket window —
    /// a held volume key steps every ~100ms and a blanket window would eat
    /// those. What comes back is the value we wrote snapped to the hardware's
    /// own step (a 0.5 write reads back as 0.4999999701976776), so only a value
    /// that is *near* what we just wrote is treated as an echo.
    ///
    /// An echo that lands far away is not an echo at all: it is a device that
    /// took the write and ignored it — some virtual drivers, some AirPlay — and
    /// the slider should snap back and show that truth rather than poll for a
    /// value that is never coming.
    private func shouldIgnoreEcho(_ value: Double, for target: Target) -> Bool {
        if activeWriteTargets.contains(target) || pending[target]?.volume != nil {
            return true
        }
        guard let last = lastWrites[target], Date().timeIntervalSince(last.at) < 0.2 else {
            return false
        }
        return abs(value - last.value) < 0.02
    }

    // MARK: - Input level meter

    /// Started from `SoundScreen.onAppear` rather than the menu's, because the
    /// meter opens the microphone: while it runs the orange dot is in the
    /// menubar and OneBar is in Control Center's recently-used list. That is
    /// also why it does nothing unless the user has opted in.
    func startTracking() {
        guard AppState.shared.soundEnabled,
              AppState.shared.soundInputMeterEnabled,
              meterTimer == nil,
              let device = inputs.first(where: { $0.isDefault }),
              meter.start(device: device.id)
        else { return }

        meteredDevice = device.id
        isMetering = true
        // 30fps is as fast as a level bar can be read; the IOProc itself runs
        // at the device's rate regardless.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in SoundService.shared.publishInputLevel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopTracking() {
        meterTimer?.invalidate()
        meterTimer = nil
        meter.stop()
        meteredDevice = 0
        inputLevel = 0
        isMetering = false
    }

    private func publishInputLevel() {
        let level = meter.currentLevel
        if abs(level - inputLevel) > 0.001 { inputLevel = level }
    }
}
