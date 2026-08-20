import CoreAudio
import Foundation

/// A named set of output devices played to at once — what Audio MIDI Setup
/// calls a Multi-Output Device, and what SoundSource calls a group.
///
/// Only the definition lives here. The device itself is built by
/// `AggregateDevice` and lives in the HAL.
struct OutputGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Device UIDs, not `AudioObjectID`s — ids are recycled per boot, and a
    /// group has to survive a replug and a restart.
    var memberUIDs: [String]

    /// Whose clock the others follow. Two devices have two crystals ticking at
    /// slightly different rates, so one has to be the timekeeper.
    var clockUID: String { memberUIDs.first ?? "" }

    /// Stable across restarts, so a definition always rebuilds into the same
    /// aggregate device rather than accumulating duplicates.
    var deviceUID: String { AggregateDevice.uidPrefix + id.uuidString }
}

/// Creating and destroying the aggregate devices behind `OutputGroup`.
///
/// `kAudioAggregateDeviceIsStackedKey` must be **1**, and do not "fix" that
/// from the header — its wording says a value of 0 means "the output streams
/// are all fed the same data", and the measured behaviour is the opposite:
///
///     stacked = 0 → 4 channels, TWO streams (start 1 and start 3)
///     stacked = 1 → 2 channels, ONE stream  (start 1)
///
/// Two streams means ordinary stereo playback writes channels 1-2 and reaches
/// the first member only, which is exactly what a broken group sounds like.
/// One stream is what feeds every member the same audio.
enum AggregateDevice {
    /// Ours are recognised by their UID, which is also how a stray one left by
    /// a crash gets cleaned up.
    static let uidPrefix = "com.onebar.app.group."

    static func isOurs(_ uid: String) -> Bool { uid.hasPrefix(uidPrefix) }

    /// The device id, or 0 if the HAL refused.
    ///
    /// Every member must itself be selectable as a default device: an
    /// aggregate inherits `canBeDefaultDevice` from what is in it, so one
    /// member that can't be default (the Teams loopback driver, say) produces
    /// a group that is silently missing from every device list, with no error
    /// anywhere to say why.
    @discardableResult
    static func create(_ group: OutputGroup) -> AudioObjectID {
        let subDevices: [[String: Any]] = group.memberUIDs.map { uid in
            [
                kAudioSubDeviceUIDKey: uid,
                // The clock master must not drift-compensate against itself.
                kAudioSubDeviceDriftCompensationKey: uid == group.clockUID ? 0 : 1
            ]
        }

        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: group.name,
            kAudioAggregateDeviceUIDKey: group.deviceUID,
            // Private would keep it out of other apps entirely — and out of
            // being selectable at all, which is the whole point of a group.
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: group.clockUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices
        ]

        var deviceID = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &deviceID) == noErr else {
            return 0
        }
        return deviceID
    }

    @discardableResult
    static func destroy(_ deviceID: AudioObjectID) -> Bool {
        AudioHardwareDestroyAggregateDevice(deviceID) == noErr
    }

    /// Every aggregate device the HAL is holding for us right now, by UID.
    static func existing() -> [String: AudioObjectID] {
        let ids = CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        )

        var found: [String: AudioObjectID] = [:]
        for id in ids {
            guard let uid = CoreAudioProperty.string(
                id,
                CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ), isOurs(uid) else { continue }
            found[uid] = id
        }
        return found
    }

    /// Whether the HAL built this device as a single mirrored stream. A group
    /// built the other way round plays to its first member only, so it is
    /// rebuilt rather than left silently half-working.
    static func isMirrored(_ deviceID: AudioObjectID) -> Bool {
        var address = CoreAudioProperty.address(kAudioAggregateDevicePropertyComposition)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return true }

        var composition: Unmanaged<CFDictionary>?
        guard withUnsafeMutablePointer(to: &composition, {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }) == noErr, let dictionary = composition?.takeRetainedValue() as? [String: Any] else { return true }

        // Anything unreadable is treated as fine. Answering "not mirrored"
        // here means destroying and recreating the device, and doing that to a
        // group that is currently playing is far worse than leaving a
        // suspicious one alone.
        guard let stacked = dictionary[kAudioAggregateDeviceIsStackedKey] as? Int else { return true }
        return stacked == 1
    }

    /// Which members are actually live. A group whose AirPods have wandered off
    /// still exists, just with fewer devices under it.
    static func activeMembers(of deviceID: AudioObjectID) -> Int {
        CoreAudioProperty.objectIDs(
            deviceID,
            CoreAudioProperty.address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        ).count
    }
}

/// The group definitions, on disk beside the clipboard history and the click
/// layouts.
///
/// The HAL keeps the devices themselves, but this is the source of truth: a
/// definition whose device is missing is rebuilt at launch, so a group survives
/// whatever the HAL decides to forget across a reboot.
@MainActor
@Observable
final class OutputGroupStore {
    static let shared = OutputGroupStore()

    private let fileURL: URL
    private(set) var groups: [OutputGroup] = []

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("output-groups.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([OutputGroup].self, from: data) {
            groups = decoded
        }
    }

    /// A group needs two devices; one is just the device itself.
    @discardableResult
    func add(name: String, memberUIDs: [String]) -> OutputGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard memberUIDs.count > 1 else { return nil }

        let group = OutputGroup(
            name: trimmed.isEmpty ? Self.defaultName(for: memberUIDs) : trimmed,
            memberUIDs: memberUIDs
        )
        groups.append(group)
        write()
        return group
    }

    func remove(_ id: UUID) {
        groups.removeAll { $0.id == id }
        write()
    }

    func group(withDeviceUID uid: String) -> OutputGroup? {
        groups.first { $0.deviceUID == uid }
    }

    private static func defaultName(for memberUIDs: [String]) -> String {
        "Group of \(memberUIDs.count)"
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
