import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// The HAL's view of who is playing audio.
///
/// Note that this is a list of *processes*, not of apps, and the difference
/// matters: a browser plays through a helper, so Safari's audio belongs to
/// `com.apple.WebKit.GPU` while `com.apple.Safari` reports no audio at all.
/// Electron apps do the same. The process is what can be tapped, so the process
/// is what is stored — only the name shown is cleaned up.
enum AudioProcess {
    struct Info: Identifiable, Equatable {
        /// The HAL's process object, which is what a tap is built on.
        let id: AudioObjectID
        let pid: pid_t
        /// Identity across launches. Empty for the handful of system processes
        /// that have none, which are skipped.
        let bundleID: String
        /// Cleaned up for display — "Safari", not "Safari Graphics and Media".
        let name: String
        let icon: NSImage?
        let isPlaying: Bool
        /// The app macOS holds *responsible* for this process. A browser's
        /// audio runs in a helper whose parent is launchd, so neither the
        /// bundle id nor the parent pid leads back to the app — but the
        /// responsibility chain does.
        let responsibleBundleID: String?
    }

    /// `responsibility_get_pid_responsible_for_pid` is how the system itself
    /// attributes a helper to the app that caused it — it is what puts a TCC
    /// prompt for a WebKit process under Safari's name. Not in any header, so
    /// it is looked up by symbol and stays optional: without it, helper
    /// processes simply fall back to name matching.
    private static let responsibleForPID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Everything the HAL knows about, playing or not. Callers decide what to
    /// show; most of this list is daemons nobody means by "an app".
    static func all() -> [Info] {
        let objects = CoreAudioProperty.objectIDs(
            AudioObjectID(kAudioObjectSystemObject),
            CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        )

        return objects.compactMap { object in
            let bundleID = CoreAudioProperty.string(
                object,
                CoreAudioProperty.address(kAudioProcessPropertyBundleID)
            ) ?? ""
            // Tapping ourselves would be a fine way to mute our own HUD.
            guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return nil }

            let pid: pid_t = CoreAudioProperty.value(
                object,
                CoreAudioProperty.address(kAudioProcessPropertyPID),
                seed: pid_t(0)
            ) ?? 0
            let playing: UInt32 = CoreAudioProperty.value(
                object,
                CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput),
                seed: UInt32(0)
            ) ?? 0

            let running = NSRunningApplication(processIdentifier: pid)
            let rawName = running?.localizedName ?? bundleID
            let cleaned = displayName(rawName)
            // The helper's own icon is a generic one; the app it belongs to has
            // the icon people recognise.
            let owner = ownerApplication(named: cleaned)

            var responsible: String?
            if let lookup = responsibleForPID {
                let responsiblePID = lookup(pid)
                if responsiblePID > 0, responsiblePID != pid {
                    responsible = NSRunningApplication(processIdentifier: responsiblePID)?.bundleIdentifier
                }
            }

            return Info(
                id: object,
                pid: pid,
                bundleID: bundleID,
                name: cleaned,
                icon: owner?.icon ?? running?.icon,
                isPlaying: playing == 1,
                responsibleBundleID: responsible
            )
        }
    }

    /// Strips the suffixes macOS gives to media and renderer helpers, which is
    /// what turns "Safari Graphics and Media" into "Safari" and "Google Chrome
    /// Helper (Renderer)" into "Google Chrome". Generic on purpose — a table of
    /// known bundle ids would need a new entry per browser.
    static func displayName(_ raw: String) -> String {
        var name = raw
        for suffix in [
            " Graphics and Media",
            " Helper (Renderer)",
            " Helper (GPU)",
            " Helper (Plugin)",
            " Helper",
            " Web Content",
            " Media Services"
        ] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// The Dock-visible app a helper belongs to, matched by the cleaned name.
    private static func ownerApplication(named name: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
