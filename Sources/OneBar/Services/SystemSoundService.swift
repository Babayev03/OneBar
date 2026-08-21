import AppKit

/// Alert volume and UI sound effects — the two sound settings that are not in
/// CoreAudio at all. They live as keys in `NSGlobalDomain`, which is the
/// system's own storage rather than a mirror of it: setting alert volume by
/// any other route (System Settings' slider, AppleScript's `set volume alert
/// volume`) rewrites the same key, and writing it here is read back
/// immediately by everything else.
///
/// `UserDefaults.standard` cannot reach that domain — it would write into
/// OneBar's own — so this goes through `CFPreferences` with
/// `kCFPreferencesAnyApplication`. The keys are stored any-host, not
/// current-host: `defaults -currentHost read -g` does not find them.
@MainActor
@Observable
final class SystemSoundService {
    static let shared = SystemSoundService()

    /// 0...1 and linear, the same scale System Settings' slider draws. Note
    /// AppleScript reports this on a different, logarithmic scale that goes
    /// negative below ~0.37, so its number is not this one.
    var alertVolume: Double = 1 {
        didSet {
            guard !reloading, alertVolume != oldValue else { return }
            Self.write(Self.volumeKey, alertVolume as CFNumber)
        }
    }

    /// The "Play user interface sound effects" switch: clicks, the screenshot
    /// shutter, empty trash. Stored as an integer, not a boolean.
    var soundEffectsEnabled = true {
        didSet {
            guard !reloading, soundEffectsEnabled != oldValue else { return }
            Self.write(Self.effectsKey, (soundEffectsEnabled ? 1 : 0) as CFNumber)
        }
    }

    private var reloading = false

    private static let volumeKey = "com.apple.sound.beep.volume" as CFString
    private static let effectsKey = "com.apple.sound.uiaudio.enabled" as CFString

    private init() {
        refresh()
    }

    /// Re-reads both, since System Settings and the keyboard can move them
    /// behind our back. A read measured ~1µs, so the screen can just do this
    /// when it appears rather than watching for changes.
    func refresh() {
        reloading = true
        defer { reloading = false }

        if let volume = Self.read(Self.volumeKey) as? Double {
            alertVolume = min(max(volume, 0), 1)
        }
        if let effects = Self.read(Self.effectsKey) as? Int {
            soundEffectsEnabled = effects != 0
        }
    }

    // MARK: - NSGlobalDomain

    private static func read(_ key: CFString) -> Any? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// Written inline: a set measured ~1µs and a set plus synchronize ~3µs,
    /// because cfprefsd does the real work after the call returns. This is the
    /// opposite of `SoundService`, where a single CoreAudio write costs
    /// milliseconds and has to be queued off the main actor.
    private static func write(_ key: CFString, _ value: CFNumber) {
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }
}
