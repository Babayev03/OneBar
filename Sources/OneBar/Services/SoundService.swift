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
    enum VolumeControl: Equatable, Sendable {
        /// What Control Center drives. Synthetic, and it preserves the balance
        /// between channels for free.
        case virtualMain
        /// A real scalar on the main element.
        case main
        /// Per-channel scalars only — no main element to write.
        case channels([AudioObjectPropertyElement])
        /// An output group. The aggregate device the HAL builds has no volume
        /// control of its own — this is the long-standing complaint about
        /// macOS multi-output devices, that the volume keys stop working — so
        /// the level is fanned out to the members instead.
        case group([AudioObjectID])
        /// HDMI, DisplayPort, most USB DACs, some AirPlay, and the Continuity
        /// iPhone microphone. The device runs at whatever level its own
        /// hardware is set to and nothing here can move it.
        case none
    }

    enum MuteControl: Equatable, Sendable {
        case main
        case channels([AudioObjectPropertyElement])
        /// Fanned out to the group's members, like `VolumeControl.group`.
        case group([AudioObjectID])
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
        var isGroup: Bool { AggregateDevice.isOurs(uid) }
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

    /// Writes waiting to go down to the HAL, newest value per control only.
    @ObservationIgnored private var pending: [Target: PendingWrite] = [:]
    @ObservationIgnored private var draining = false
    /// Separate from `queue`, which delivers HAL notifications: a slow write
    /// must not hold up the echo of the one before it.
    @ObservationIgnored private let writeQueue = DispatchQueue(
        label: "com.onebar.app.sound.write",
        qos: .userInitiated
    )

    /// Each plain device's own controls, so a group can drive its members
    /// without re-probing every one of them on every tick of a slider drag.
    @ObservationIgnored private var memberControls: [AudioObjectID: (VolumeControl, MuteControl)] = [:]
    @ObservationIgnored private var deviceIDsByUID: [String: AudioObjectID] = [:]
    /// Creating or destroying an aggregate device fires the device-list
    /// listener, which would call straight back into here.
    @ObservationIgnored private var reconciling = false

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
        VolumeKeyMonitor.shared.stop()
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

        reconcileGroups()

        let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let ids = CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        )

        // A group's members are ordinary devices, so their controls have to be
        // known before any group can be described in terms of them.
        deviceIDsByUID = [:]
        memberControls = [:]
        for id in ids {
            guard let uid = CoreAudioProperty.string(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ) else { continue }
            deviceIDsByUID[uid] = id
            guard !AggregateDevice.isOurs(uid) else { continue }
            memberControls[id] = (
                volumeControl(for: id, scope: kAudioObjectPropertyScopeOutput),
                muteControl(for: id, scope: kAudioObjectPropertyScopeOutput)
            )
        }

        outputs = ids.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeOutput, isDefault: $0 == defaultOutput)
        }
        inputs = ids.compactMap {
            device(id: $0, scope: kAudioObjectPropertyScopeInput, isDefault: $0 == defaultInput)
        }

        observeDefaults(output: defaultOutput, input: defaultInput)
        updateVolumeKeyMonitor()
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

        var volumeControl = volumeControl(for: id, scope: scope)
        var muteControl = muteControl(for: id, scope: scope)

        // A group reports no controls at all; it borrows its members'.
        if AggregateDevice.isOurs(uid), scope == kAudioObjectPropertyScopeOutput {
            let memberIDs = OutputGroupStore.shared.group(withDeviceUID: uid)?
                .memberUIDs.compactMap { deviceIDsByUID[$0] } ?? []
            if !memberIDs.isEmpty {
                volumeControl = .group(memberIDs)
                muteControl = memberIDs.contains { memberControls[$0]?.1 != MuteControl.none }
                    ? .group(memberIDs)
                    : .none
            }
        }

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
        case .group(let memberIDs):
            // The loudest member is the group's level, the same way the loudest
            // channel is a device's.
            let values = memberIDs.compactMap { member -> Double? in
                guard let control = memberControls[member]?.0 else { return nil }
                return readVolume(member, scope: scope, control: control)
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
        case .group(let memberIDs):
            // Muted only when every member that *can* mute is muted — one
            // member without a mute control would otherwise make the group
            // permanently unmuted.
            let mutable = memberIDs.filter { memberControls[$0]?.1 != MuteControl.none }
            return !mutable.isEmpty && mutable.allSatisfy { member in
                guard let control = memberControls[member]?.1 else { return false }
                return readMute(member, scope: scope, control: control)
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
        lastWrite = (clamped, Date())

        var job = pending[Target(id: id, scope: scope)] ?? PendingWrite()
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

        pending[Target(id: id, scope: scope)] = job
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

    /// A HAL write is *not* the free thing the top of this file once claimed.
    /// Measured on the main thread it is ~5ms to the built-in speakers, ~11ms
    /// to AirPods and ~17ms to a virtual driver, against a 16ms frame — so a
    /// slider drag posting one per tick stalled the UI outright, and a group
    /// multiplied that by its member count. The writes therefore go off the
    /// main actor, latest-wins: `pending` never holds more than the newest
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
                if let volume = job.volume { lastWrite = (volume, Date()) }
            }
            draining = false
        }
    }

    /// Sends one level to whichever control a device actually has. A group
    /// recurses into its members exactly once — a member is always a plain
    /// device, never a group of its own.
    ///
    /// `static` and off the main actor because the write queue is what calls
    /// it, so the member controls arrive as a snapshot rather than being read
    /// from `memberControls` here.
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
        case .group(let memberIDs):
            for member in memberIDs {
                guard let memberControl = members[member]?.0 else { continue }
                writeVolume(value, to: member, scope: scope, control: memberControl, members: members)
                // A member muted on its own stays silent while the group looks
                // perfectly fine — the group only reads as muted when *every*
                // member is. Raising the level clears it, the same way it does
                // on a single device.
                if value > 0, let muteControl = members[member]?.1, muteControl != .none {
                    writeMute(false, to: member, scope: scope, control: muteControl, members: members)
                }
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
        case .group(let memberIDs):
            for member in memberIDs {
                guard let memberControl = members[member]?.1 else { continue }
                writeMute(muted, to: member, scope: scope, control: memberControl, members: members)
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

    // MARK: - Output groups

    /// Devices that may join a group: everything already listed for output,
    /// minus the groups themselves.
    ///
    /// The filter matters more than it looks. An aggregate device inherits
    /// `canBeDefaultDevice` from its members, so a single member that cannot be
    /// a default device produces a group that is missing from every device list
    /// with no error to explain it. `outputs` is already filtered on exactly
    /// that property, so drawing candidates from it is what keeps groups
    /// selectable.
    var groupCandidates: [Device] {
        outputs.filter { !$0.isGroup }
    }

    /// The definition behind a listed group device, for renaming or deleting.
    func group(for device: Device) -> OutputGroup? {
        OutputGroupStore.shared.group(withDeviceUID: device.uid)
    }

    /// Members in the order they were picked; the first is the clock master.
    func memberNames(of group: OutputGroup) -> [String] {
        group.memberUIDs.map { uid in
            guard let id = deviceIDsByUID[uid] else { return "Not connected" }
            return outputs.first { $0.id == id }?.name
                ?? CoreAudioProperty.string(id, CoreAudioProperty.address(kAudioObjectPropertyName))
                ?? "Audio Device"
        }
    }

    @discardableResult
    func createGroup(name: String, memberUIDs: [String]) -> Bool {
        guard let group = OutputGroupStore.shared.add(name: name, memberUIDs: memberUIDs) else {
            return false
        }
        guard AggregateDevice.create(group) != 0 else {
            // Don't keep a definition the HAL refused — it would be rebuilt and
            // refused again on every launch.
            OutputGroupStore.shared.remove(group.id)
            return false
        }
        refresh()
        return true
    }

    func deleteGroup(_ group: OutputGroup) {
        // If the group is what is currently playing, move somewhere sensible
        // first: destroying the default output leaves the HAL to pick for us,
        // and it does not pick what you would. The group's own clock member is
        // the closest thing to "where the sound already was".
        if let device = outputs.first(where: { $0.uid == group.deviceUID }), device.isDefault {
            let fallback = groupCandidates.first { $0.uid == group.clockUID } ?? groupCandidates.first
            if let fallback {
                makeDefault(fallback.id, scope: kAudioObjectPropertyScopeOutput)
            }
        }
        if let id = AggregateDevice.existing()[group.deviceUID] {
            AggregateDevice.destroy(id)
        }
        OutputGroupStore.shared.remove(group.id)
        refresh()
    }

    /// The UID of whatever is playing right now.
    var currentOutputUID: String {
        outputs.first { $0.isDefault }?.uid ?? outputs.first?.uid ?? ""
    }

    /// The *real* devices behind the current output, which is what `AppMixer`
    /// has to render into.
    ///
    /// One aggregate device cannot contain another — building a mixer over a
    /// group yields a device with no channels whose start fails outright — so
    /// a group is expanded into its members here and the mixer mirrors to them
    /// itself, exactly as the group would have.
    var currentOutputDeviceUIDs: [String] {
        guard let device = outputs.first(where: { $0.isDefault }) ?? outputs.first else { return [] }
        guard device.isGroup, let group = OutputGroupStore.shared.group(withDeviceUID: device.uid) else {
            return [device.uid]
        }
        return group.memberUIDs
    }

    /// The volume keys only need taking over while a group is playing —
    /// every other device answers them itself.
    private func updateVolumeKeyMonitor() {
        if outputs.contains(where: { $0.isDefault && $0.isGroup }) {
            VolumeKeyMonitor.shared.start()
        } else {
            VolumeKeyMonitor.shared.stop()
        }
    }

    /// A volume key press, redirected into the group fan-out. Returns false
    /// when there is nothing here for it to do, so the press is left alone.
    @discardableResult
    func handleVolumeKey(keyType: Int32) -> Bool {
        guard let device = outputs.first(where: { $0.isDefault }), device.isGroup else { return false }
        let scope = kAudioObjectPropertyScopeOutput

        // 7 is NX_KEYTYPE_MUTE; 0 and 1 are sound up and down.
        if keyType == 7 {
            let muted = !device.isMuted
            setMuted(muted, for: device.id, scope: scope)
            HUD.show(
                muted ? "Muted" : "Unmuted",
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            return true
        }

        let step = VolumeKeyMonitor.step
        // Snap to the step grid, so a level that started at some odd value
        // lands on round numbers after a press or two rather than staying off
        // by a fraction forever.
        let moved = device.volume + (keyType == 0 ? step : -step)
        let target = min(max((moved / step).rounded() * step, 0), 1)
        setVolume(target, for: device.id, scope: scope)

        let percent = Int((target * 100).rounded())
        HUD.show("\(percent)%", symbol: target == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
        return true
    }

    /// Rebuilds any group the HAL has lost and destroys any aggregate device of
    /// ours that no definition claims — a stray left by a crash, say.
    private func reconcileGroups() {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }

        let existing = AggregateDevice.existing()
        let wanted = OutputGroupStore.shared.groups

        for group in wanted {
            guard let id = existing[group.deviceUID] else {
                AggregateDevice.create(group)
                continue
            }
            // Never rebuild the group that is currently playing: destroying
            // the default output makes the HAL pick a replacement and hands
            // the new device a different id, which looks from the outside like
            // the output select refusing to change.
            let isPlaying = id == defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            // Self-heal a group built by an older version in the wrong mode —
            // it would otherwise play to its first member only, forever.
            if !isPlaying, !AggregateDevice.isMirrored(id) {
                AggregateDevice.destroy(id)
                AggregateDevice.create(group)
            }
        }

        let wantedUIDs = Set(wanted.map(\.deviceUID))
        let playing = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        for (uid, id) in existing where !wantedUIDs.contains(uid) {
            // Never pull the device out from under the audio that is playing
            // through it. An unclaimed group is usually a stray left by a
            // crash, but if it is the current output then destroying it makes
            // the HAL fall back to some other device mid-listen — which is
            // indistinguishable from "the output keeps changing by itself".
            // It will be cleaned up on a later pass, once it is idle.
            guard id != playing else { continue }
            AggregateDevice.destroy(id)
        }
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
