import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// System volume, mute, input gain and device switching, straight off the HAL.
///
/// Deliberately none of the machinery `BrightnessService` needs: no write
/// queue, no lock, no coalescer, no async refresh, no last-known cache.
/// `DDCBackend` has all of that because every I2C exchange sleeps for tens of
/// milliseconds; `AudioObjectSetPropertyData` is a mach message that returns in
/// tens of microseconds. Sixty writes a second straight off the main actor is
/// what Control Center itself does.
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
    enum VolumeControl: Equatable {
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

    enum MuteControl: Equatable {
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

    /// The value and the moment of our own last write, for telling our echo
    /// apart from a real change. See `shouldIgnoreEcho`.
    @ObservationIgnored private var lastWrite: (value: Double, at: Date)?

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
                Task { @MainActor in SoundService.shared.refresh() }
            }
            if let listener { systemListeners.append(listener) }
        }

        refresh()
    }

    func tearDown() {
        stopTracking()
        systemListeners.removeAll()
        deviceListeners.removeAll()
        outputs = []
        inputs = []
    }

    // MARK: - Enumeration

    /// Synchronous and complete on return — unlike displays there is nothing to
    /// probe off-thread, every answer here is a local property read.
    func refresh() {
        guard AppState.shared.soundEnabled else {
            outputs = []
            inputs = []
            deviceListeners.removeAll()
            stopTracking()
            return
        }

        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let ids = CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        )

        outputs = ids.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeOutput, isDefault: $0 == defaultOutput)
        }
        inputs = ids.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeInput, isDefault: $0 == defaultInput)
        }

        observeDefaults(output: defaultOutput, input: defaultInput)

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
            scope: scope,
            volumeControl: volumeControl,
            muteControl: muteControl,
            volume: readVolume(id, scope: scope, control: volumeControl) ?? 0,
            isMuted: readMute(id, scope: scope, control: muteControl),
            isDefault: isDefault
        )
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
            return scalar(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        case .main:
            return scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope)
        case .channels(let elements):
            // The loudest channel is the level; a channel deliberately pulled
            // down is balance, not volume.
            let values = elements.compactMap {
                scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0)
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

    private func scalar(
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

        self[list][index].volume = clamped
        lastWrite = (clamped, Date())

        switch control {
        case .virtualMain:
            write(clamped, id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        case .main:
            write(clamped, id, kAudioDevicePropertyVolumeScalar, scope: scope)
        case .channels(let elements):
            // Scale each channel by its ratio to the loudest one, so a channel
            // the user pulled down stays proportionally down.
            let current = elements.map {
                scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: $0) ?? 0
            }
            let peak = current.max() ?? 0
            for (element, level) in zip(elements, current) {
                let ratio = peak > 0.001 ? level / peak : 1
                write(clamped * ratio, id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            }
        case .none:
            return
        }

        // Control Center's own behaviour: turning it up is how you unmute.
        if clamped > 0, self[list][index].isMuted {
            setMuted(false, for: id, scope: scope)
        }
    }

    func setMuted(_ muted: Bool, for id: AudioObjectID, scope: AudioObjectPropertyScope) {
        guard let (list, index) = locate(id, scope: scope) else { return }
        let value = UInt32(muted ? 1 : 0)

        switch self[list][index].muteControl {
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
            return
        }

        self[list][index].isMuted = muted
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

        CoreAudioProperty.setValue(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice),
            id
        )

        // A driver that can't take the system default would otherwise leave the
        // two halves pointing at different devices.
        let canTakeSystem = CoreAudioProperty.value(
            id,
            CoreAudioProperty.address(kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, scope: scope),
            seed: UInt32(0)
        ) == 1
        if canTakeSystem {
            CoreAudioProperty.setValue(
                AudioObjectID(kAudioObjectSystemObject),
                CoreAudioProperty.address(kAudioHardwarePropertyDefaultSystemOutputDevice),
                id
            )
        }

        refresh()
    }

    private func write(
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
                    Task { @MainActor in SoundService.shared.syncDeviceValues() }
                }
                if let listener { deviceListeners.append(listener) }
            }
        }
    }

    /// Re-reads volume and mute for every listed device. Idempotent, so it does
    /// not matter how many listeners call it for one change.
    private func syncDeviceValues() {
        for list in [List.output, .input] {
            var devices = self[list]
            for index in devices.indices {
                let device = devices[index]

                if let volume = readVolume(device.id, scope: device.scope, control: device.volumeControl),
                   abs(volume - device.volume) > 0.001,
                   !shouldIgnoreEcho(volume) {
                    devices[index].volume = volume
                }

                let muted = readMute(device.id, scope: device.scope, control: device.muteControl)
                if muted != device.isMuted { devices[index].isMuted = muted }
            }
            self[list] = devices
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
    private func shouldIgnoreEcho(_ value: Double) -> Bool {
        guard let last = lastWrite, Date().timeIntervalSince(last.at) < 0.2 else { return false }
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
