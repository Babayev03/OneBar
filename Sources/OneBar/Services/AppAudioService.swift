import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Per-app volume boost multiplier.
enum BoostLevel: Float, CaseIterable, Codable {
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x4 = 4.0

    var label: String {
        switch self {
        case .x1: "1x"
        case .x2: "2x"
        case .x3: "3x"
        case .x4: "4x"
        }
    }

    var next: BoostLevel {
        switch self {
        case .x1: .x2
        case .x2: .x3
        case .x3: .x4
        case .x4: .x1
        }
    }

    var isBoosted: Bool { self != .x1 }
}

/// One app's saved level.
struct AppAudioSetting: Codable, Equatable {
    var bundleID: String
    var name: String
    var volume: Double
    var isMuted: Bool
    var boost: BoostLevel = .x1
    var outputDeviceUID: String? = nil

    var isDefault: Bool { abs(volume - 1.0) < 0.001 && !isMuted && boost == .x1 && outputDeviceUID == nil }

    enum CodingKeys: String, CodingKey {
        case bundleID, name, volume, isMuted, boost, outputDeviceUID
    }

    init(bundleID: String, name: String, volume: Double, isMuted: Bool, boost: BoostLevel = .x1, outputDeviceUID: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.boost = boost
        self.outputDeviceUID = outputDeviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        volume = try container.decode(Double.self, forKey: .volume)
        isMuted = try container.decode(Bool.self, forKey: .isMuted)
        boost = try container.decodeIfPresent(BoostLevel.self, forKey: .boost) ?? .x1
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
    }
}

/// Per-app volume, boost, mute, and output routing without an audio driver.
@MainActor
@Observable
final class AppAudioService {
    static let shared = AppAudioService()

    struct App: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        let isPlaying: Bool
        let isRunning: Bool
        var volume: Double
        var isMuted: Bool
        var boost: BoostLevel
        var outputDeviceUID: String?

        static func == (lhs: App, rhs: App) -> Bool {
            lhs.bundleID == rhs.bundleID && lhs.isPlaying == rhs.isPlaying
                && lhs.isRunning == rhs.isRunning
                && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
                && lhs.boost == rhs.boost && lhs.outputDeviceUID == rhs.outputDeviceUID
        }
    }

    /// The apps on the page: every one you added, plus anything currently making sound.
    private(set) var apps: [App] = []

    /// The last failure from the HAL, shown rather than swallowed.
    private(set) var lastError: String?

    @ObservationIgnored private var settings: [String: AppAudioSetting] = [:]
    /// Apps the user added by hand, which stay listed at 100% too.
    @ObservationIgnored private var pinned: Set<String> = []

    /// One mixer per app, managing its tap and aggregate device atomically.
    @ObservationIgnored private var mixers: [String: AppMixer] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var processListener: CoreAudioListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.onebar.app.appaudio")
    /// While the system output is changing, no process-list or device-list
    /// notification may rebuild a mixer onto the device we are releasing.
    @ObservationIgnored private var isChangingSystemOutput = false

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("app-volumes.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([AppAudioSetting].self, from: data) {
            let usable = decoded.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
            }
            settings = Dictionary(uniqueKeysWithValues: usable.map { ($0.bundleID, $0) })
            pinned = Set(usable.map(\.bundleID))
            if usable.count != decoded.count { write() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard processListener == nil else { return }
        processListener = CoreAudioListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList),
            queue: queue
        ) { _, _ in
            Task { @MainActor in AppAudioService.shared.refresh() }
        }
        refresh()
    }

    func tearDown() {
        processListener = nil
        for (_, running) in mixers { running.stop() }
        mixers = [:]
        apps = []
    }

    var adjustedCount: Int {
        settings.values.filter { !$0.isDefault }.count
    }

    var status: String {
        let adjusted = settings.values.filter { !$0.isDefault }
        guard !adjusted.isEmpty else { return "" }
        return adjusted
            .sorted { $0.name < $1.name }
            .map { setting in
                let mixer = mixers[setting.bundleID]
                return "\(setting.name): "
                    + (mixer?.isRunning == true ? "\(mixer?.renderCount ?? 0) renders" : "NO MIXER")
            }
            .joined(separator: " · ")
    }

    // MARK: - Which processes belong to an app

    private func processes(for setting: AppAudioSetting, live: [AudioProcess.Info]) -> [AudioObjectID] {
        var matched: [AudioProcess.Info] = []
        for process in live {
            if process.bundleID == setting.bundleID
                || process.responsibleBundleID == setting.bundleID
                || process.name.caseInsensitiveCompare(setting.name) == .orderedSame {
                matched.append(process)
            }
        }
        return matched.map(\.id).sorted()
    }

    // MARK: - Listing

    func refresh() {
        let live = AudioProcess.all()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }

        var listed: [App] = []

        for bundleID in pinned {
            let setting = settings[bundleID] ?? AppAudioSetting(
                bundleID: bundleID, name: bundleID, volume: 1, isMuted: false
            )
            settings[bundleID] = setting
            let app = running.first { $0.bundleIdentifier == bundleID }
            listed.append(App(
                bundleID: bundleID,
                name: app?.localizedName ?? setting.name,
                icon: app?.icon ?? icon(forBundleID: bundleID),
                isPlaying: !processes(for: setting, live: live).isEmpty,
                isRunning: app != nil,
                volume: setting.volume,
                isMuted: setting.isMuted,
                boost: setting.boost,
                outputDeviceUID: setting.outputDeviceUID
            ))
        }

        apps = listed.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        syncTaps(live: live)
    }

    struct Candidate: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage?
        let isRunning: Bool
        let isPlaying: Bool
    }

    @ObservationIgnored private var candidateCache: [Candidate] = []

    func refreshCandidates() {
        let live = AudioProcess.all()
        var found: [String: Candidate] = [:]

        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = app.localizedName ?? bundleID
            let playing = live.contains {
                $0.bundleID == bundleID || $0.responsibleBundleID == bundleID
                    || $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            found[bundleID] = Candidate(
                bundleID: bundleID, name: name, icon: app.icon,
                isRunning: true, isPlaying: playing
            )
        }

        for url in Self.installedApplications() {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier,
                  found[bundleID] == nil else { continue }
            found[bundleID] = Candidate(
                bundleID: bundleID,
                name: FileManager.default.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""),
                icon: NSWorkspace.shared.icon(forFile: url.path),
                isRunning: false,
                isPlaying: false
            )
        }

        candidateCache = found.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func candidates(matching query: String = "") -> [Candidate] {
        let already = Set(apps.map(\.bundleID))
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return candidateCache.filter {
            !already.contains($0.bundleID)
                && (trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed))
        }
    }

    private static let installedCache: [URL] = {
        let manager = FileManager.default
        var roots = ["/Applications", "/Applications/Utilities", "/System/Applications"]
        if let home = manager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(home.path)
        }
        var found: [URL] = []
        for root in roots {
            guard let names = try? manager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                found.append(URL(fileURLWithPath: root).appendingPathComponent(name))
            }
        }
        return found
    }()

    private static func installedApplications() -> [URL] { installedCache }

    private func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Adding and removing

    func add(bundleID: String, name: String) {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return }
        pinned.insert(bundleID)
        if settings[bundleID] == nil {
            settings[bundleID] = AppAudioSetting(
                bundleID: bundleID, name: name, volume: 1, isMuted: false
            )
        }
        write()
        refresh()
    }

    func remove(_ bundleID: String) {
        pinned.remove(bundleID)
        settings.removeValue(forKey: bundleID)
        mixers[bundleID]?.stop()
        mixers.removeValue(forKey: bundleID)
        write()
        refresh()
    }

    // MARK: - Changing a level

    func setVolume(_ value: Double, for bundleID: String) {
        let clamped = min(max(value, 0), 1.0)
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.volume = clamped
        if clamped > 0 { setting.isMuted = false }
        apply(setting)
    }

    func setBoost(_ boost: BoostLevel, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.boost = boost
        apply(setting)
    }

    func cycleBoost(for bundleID: String) {
        let current = settings[bundleID]?.boost ?? .x1
        setBoost(current.next, for: bundleID)
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        var setting = settings[bundleID] ?? blankSetting(for: bundleID)
        setting.isMuted = muted
        apply(setting)
    }

    func toggleMute(for bundleID: String) {
        setMuted(!(settings[bundleID]?.isMuted ?? false), for: bundleID)
    }

    private func blankSetting(for bundleID: String) -> AppAudioSetting {
        AppAudioSetting(
            bundleID: bundleID,
            name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID,
            volume: 1,
            isMuted: false
        )
    }

    private func apply(_ setting: AppAudioSetting) {
        var setting = setting
        if let name = apps.first(where: { $0.bundleID == setting.bundleID })?.name {
            setting.name = name
        }

        settings[setting.bundleID] = setting
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: setting.bundleID) != nil {
            pinned.insert(setting.bundleID)
        }
        write()

        if let index = apps.firstIndex(where: { $0.bundleID == setting.bundleID }) {
            apps[index].volume = setting.volume
            apps[index].isMuted = setting.isMuted
            apps[index].boost = setting.boost
            apps[index].outputDeviceUID = setting.outputDeviceUID
        }

        // Direct gain update in the running RT loop without touching hardware or rebuilding
        mixers[setting.bundleID]?.setGain(gain(for: setting))
    }

    // MARK: - Taps & Mixers

    private func needsRendering(_ setting: AppAudioSetting?) -> Bool {
        setting != nil
    }

    private func gain(for setting: AppAudioSetting?) -> Float {
        guard let setting, !setting.isMuted else { return 0 }
        let vol = Float(setting.volume)
        let boost = setting.boost.rawValue
        // x^2 perceptual curve * boost multiplier (protected by SoftLimiter)
        return (vol * vol) * boost
    }

    private func syncTaps(live: [AudioProcess.Info]) {
        guard !isChangingSystemOutput else { return }

        let systemOutputUIDs = SoundService.shared.currentOutputDeviceUIDs
        var wanted: [String: (processes: [AudioObjectID], outputUIDs: [String])] = [:]

        for setting in settings.values where needsRendering(setting) {
            let ids = processes(for: setting, live: live)
            if !ids.isEmpty {
                let targets = setting.outputDeviceUID.map { [$0] } ?? systemOutputUIDs
                if !targets.isEmpty {
                    wanted[setting.bundleID] = (ids, targets)
                }
            }
        }

        // Drop mixers for apps that were removed or stopped playing
        for bundleID in mixers.keys where wanted[bundleID] == nil {
            mixers[bundleID]?.stop()
            mixers.removeValue(forKey: bundleID)
        }

        for (bundleID, info) in wanted {
            let wantedGain = gain(for: settings[bundleID])
            let mixer = mixers[bundleID] ?? AppMixer()
            mixers[bundleID] = mixer

            let tapDrift = info.outputUIDs.first.map { !SoundService.shared.isBluetooth(uid: $0) } ?? true
            let started = mixer.start(
                processIDs: info.processes,
                outputUIDs: info.outputUIDs,
                gain: wantedGain,
                label: settings[bundleID]?.name ?? bundleID,
                tapDriftCompensation: tapDrift
            )
            if !started {
                lastError = "Couldn't route audio for \(settings[bundleID]?.name ?? bundleID)."
                mixer.stop()
                mixers.removeValue(forKey: bundleID)
            } else {
                lastError = nil
            }
        }
    }

    func outputDeviceChanged() {
        guard !isChangingSystemOutput else { return }

        let current = SoundService.shared.currentOutputDeviceUIDs
        let changed = current != lastOutputUIDs
        lastOutputUIDs = current

        if changed {
            refresh()
        }
    }

    @ObservationIgnored private var lastOutputUIDs: [String] = []

    /// Releases every aggregate before `SoundService` asks the HAL to change
    /// its default output. `AppMixer.stop()` is intentionally asynchronous for
    /// ordinary cleanup; output switching is the one place that must wait.
    func prepareForSystemOutputChange() async {
        isChangingSystemOutput = true
        let activeMixers = Array(mixers.values)
        mixers = [:]
        for mixer in activeMixers {
            await mixer.stopAndWait()
        }
    }

    /// Rebuilds pinned, playing apps against whichever output the HAL accepted.
    /// This also safely restores the old route if the device switch failed.
    func finishSystemOutputChange() {
        lastOutputUIDs = SoundService.shared.currentOutputDeviceUIDs
        isChangingSystemOutput = false
        refresh()
    }

    private func write() {
        var list: [AppAudioSetting] = []
        for bundleID in pinned {
            list.append(settings[bundleID] ?? AppAudioSetting(
                bundleID: bundleID,
                name: apps.first { $0.bundleID == bundleID }?.name ?? bundleID,
                volume: 1,
                isMuted: false
            ))
        }
        guard let data = try? JSONEncoder().encode(list.sorted { $0.bundleID < $1.bundleID }) else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}
