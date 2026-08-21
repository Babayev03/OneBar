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

    /// 0...1 on the scale System Settings' slider *draws*, which is not the
    /// scale the key is *stored* on: the stored number is `exp(shown - 1)`, so
    /// the bottom third of the raw range (everything under 1/e ≈ 0.368) is off
    /// the left end of that slider. Writing a raw 0.3 therefore reads as zero
    /// and silences alerts outright — the failure this conversion exists for.
    /// AppleScript's `set volume alert volume` takes the shown scale as 0...100,
    /// which is why its number never matched the key's.
    var alertVolume: Double = 1 {
        didSet {
            guard !reloading, alertVolume != oldValue else { return }
            Self.write(Self.volumeKey, Self.stored(alertVolume) as CFNumber)
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

    /// Held across previews so a drag does not reload the file each release.
    private var preview: NSSound?
    private var previewPath: String?

    private static let volumeKey = "com.apple.sound.beep.volume" as CFString
    private static let effectsKey = "com.apple.sound.uiaudio.enabled" as CFString
    private static let soundKey = "com.apple.sound.beep.sound" as CFString

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
            alertVolume = Self.shown(volume)
        }
        if let effects = Self.read(Self.effectsKey) as? Int {
            soundEffectsEnabled = effects != 0
        }
    }

    /// The alert sound at the level just set, played by us rather than by the
    /// system. `AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)`
    /// is the obvious call and the wrong one: it leaves the level to the sound
    /// server, which applies whatever it last read from the key rather than
    /// what was just written, so that preview came out the same loudness at
    /// every position on the slider. Owning the playback and setting `volume`
    /// makes it track the slider by construction — the same trade FineTune
    /// makes for its volume-change pop.
    func previewAlert() {
        let path = Self.alertSoundPath
        if previewPath != path {
            // By path rather than `NSSound(named:)`: a cached named instance
            // stops honouring the output device after long uptime.
            preview = NSSound(contentsOfFile: path, byReference: true)
            previewPath = path
        }
        guard let preview else { return }
        preview.stop() // rewinds — play() on a playing sound returns false
        preview.volume = Float(alertVolume)
        preview.play()
    }

    /// The chosen alert sound. The key stores a bare name on some systems and
    /// a full path on others, and it goes stale — it has been seen reading
    /// `Bottle.aiff` while the Sound pane showed "Pebble" — so anything that
    /// does not resolve to a real file falls back rather than going silent,
    /// since a preview that plays nothing reads as a broken slider.
    private static var alertSoundPath: String {
        let fallback = "/System/Library/Sounds/Funk.aiff"
        guard let chosen = read(soundKey) as? String, !chosen.isEmpty else { return fallback }
        let candidates = chosen.hasPrefix("/")
            ? [chosen]
            : ["\(NSHomeDirectory())/Library/Sounds/\(chosen).aiff",
               "/Library/Sounds/\(chosen).aiff",
               "/System/Library/Sounds/\(chosen).aiff"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? fallback
    }

    // MARK: - Slider scale

    /// Zero is stored as a literal 0 rather than as `exp(-1)`, because that is
    /// what System Settings writes at the bottom of its own slider.
    private static func stored(_ shown: Double) -> Double {
        shown <= 0 ? 0 : exp(min(shown, 1) - 1)
    }

    private static func shown(_ stored: Double) -> Double {
        stored <= 0 ? 0 : min(max(1 + log(stored), 0), 1)
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
