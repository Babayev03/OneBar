import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var systemMonitoringEnabled: Bool {
        didSet { UserDefaults.standard.set(systemMonitoringEnabled, forKey: "systemMonitoringEnabled") }
    }

    var clipboardEnabled: Bool {
        didSet { UserDefaults.standard.set(clipboardEnabled, forKey: "clipboardEnabled") }
    }

    /// Live CPU/MEM percentages in the menubar label (samples continuously).
    var menubarLiveStats: Bool {
        didSet { UserDefaults.standard.set(menubarLiveStats, forKey: "menubarLiveStats") }
    }

    // MARK: - Tunables (Preferences)

    /// Max unpinned images kept in history.
    var maxImages: Int {
        didSet { UserDefaults.standard.set(maxImages, forKey: "maxImages") }
    }

    /// Max unpinned items overall; 0 = unlimited.
    var historyCap: Int {
        didSet { UserDefaults.standard.set(historyCap, forKey: "historyCap") }
    }

    /// Ring turns orange at this fraction.
    var warnThreshold: Double {
        didSet { UserDefaults.standard.set(warnThreshold, forKey: "warnThreshold") }
    }

    /// Ring turns red at this fraction.
    var critThreshold: Double {
        didSet { UserDefaults.standard.set(critThreshold, forKey: "critThreshold") }
    }

    /// Seconds between system-stat samples.
    var statsInterval: Double {
        didSet { UserDefaults.standard.set(statsInterval, forKey: "statsInterval") }
    }

    /// Keyboard-cleaning auto-exit, in seconds.
    var cleaningDuration: Int {
        didSet { UserDefaults.standard.set(cleaningDuration, forKey: "cleaningDuration") }
    }

    /// Prevent-sleep auto-off, in minutes; 0 = never.
    var sleepAutoOffMinutes: Int {
        didSet { UserDefaults.standard.set(sleepAutoOffMinutes, forKey: "sleepAutoOffMinutes") }
    }

    /// Let the screen turn off while Prevent Sleep keeps the Mac itself awake.
    var allowDisplaySleep: Bool {
        didSet { UserDefaults.standard.set(allowDisplaySleep, forKey: "allowDisplaySleep") }
    }

    /// Seconds of idle time Auto Mouse Move tolerates before nudging the cursor.
    var mouseMoveInterval: Double {
        didSet { UserDefaults.standard.set(mouseMoveInterval, forKey: "mouseMoveInterval") }
    }

    /// How far the cursor travels before being put back, in points.
    var mouseMoveDistance: Int {
        didSet { UserDefaults.standard.set(mouseMoveDistance, forKey: "mouseMoveDistance") }
    }

    /// Glide speed in points per second — distance divided by this is how long
    /// the sweep takes, so long and short moves look equally smooth.
    var mouseMoveSpeed: Double {
        didSet { UserDefaults.standard.set(mouseMoveSpeed, forKey: "mouseMoveSpeed") }
    }

    /// Nudge only after real input has stopped, so it never fights the cursor
    /// while the Mac is actually in use.
    var mouseMoveOnlyWhenIdle: Bool {
        didSet { UserDefaults.standard.set(mouseMoveOnlyWhenIdle, forKey: "mouseMoveOnlyWhenIdle") }
    }

    /// Auto Mouse Move auto-off, in minutes; 0 = never.
    var mouseMoveAutoOffMinutes: Int {
        didSet { UserDefaults.standard.set(mouseMoveAutoOffMinutes, forKey: "mouseMoveAutoOffMinutes") }
    }

    /// Selection-highlight accent in the clipboard panel.
    var accentName: String {
        didSet { UserDefaults.standard.set(accentName, forKey: "accentName") }
    }

    static let accentChoices: [(name: String, color: Color)] = [
        ("blue", .blue), ("purple", .purple), ("pink", .pink),
        ("red", .red), ("orange", .orange), ("green", .green), ("teal", .teal)
    ]

    var accentColor: Color {
        Self.accentChoices.first { $0.name == accentName }?.color ?? .blue
    }

    // Deliberately not persisted: these all reset to off on every launch.
    var keyboardCleaningActive = false
    var preventSleepActive = false
    var mouseMoveActive = false

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "systemMonitoringEnabled": true,
            "clipboardEnabled": true,
            "menubarLiveStats": true,
            "maxImages": 20,
            "historyCap": 0,
            "warnThreshold": 0.70,
            "critThreshold": 0.85,
            "statsInterval": 5.0,
            "cleaningDuration": 60,
            "sleepAutoOffMinutes": 0,
            "allowDisplaySleep": false,
            "mouseMoveInterval": 60.0,
            "mouseMoveDistance": 250,
            "mouseMoveSpeed": 700.0,
            "mouseMoveOnlyWhenIdle": true,
            "mouseMoveAutoOffMinutes": 0,
            "accentName": "blue"
        ])
        systemMonitoringEnabled = defaults.bool(forKey: "systemMonitoringEnabled")
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        menubarLiveStats = defaults.bool(forKey: "menubarLiveStats")
        maxImages = defaults.integer(forKey: "maxImages")
        historyCap = defaults.integer(forKey: "historyCap")
        warnThreshold = defaults.double(forKey: "warnThreshold")
        critThreshold = defaults.double(forKey: "critThreshold")
        statsInterval = defaults.double(forKey: "statsInterval")
        cleaningDuration = defaults.integer(forKey: "cleaningDuration")
        sleepAutoOffMinutes = defaults.integer(forKey: "sleepAutoOffMinutes")
        allowDisplaySleep = defaults.bool(forKey: "allowDisplaySleep")
        mouseMoveInterval = defaults.double(forKey: "mouseMoveInterval")
        // Clamped on read: the slider's ceiling came down after release, and a
        // value stored above it would otherwise stick around unreachable.
        mouseMoveDistance = min(defaults.integer(forKey: "mouseMoveDistance"), 500)
        mouseMoveSpeed = defaults.double(forKey: "mouseMoveSpeed")
        mouseMoveOnlyWhenIdle = defaults.bool(forKey: "mouseMoveOnlyWhenIdle")
        mouseMoveAutoOffMinutes = defaults.integer(forKey: "mouseMoveAutoOffMinutes")
        accentName = defaults.string(forKey: "accentName") ?? "blue"
    }
}
