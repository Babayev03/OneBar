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

    /// Let the screen turn off while Prevent Sleep keeps the Mac itself awake.
    var allowDisplaySleep: Bool {
        didSet { UserDefaults.standard.set(allowDisplaySleep, forKey: "allowDisplaySleep") }
    }

    /// Keep a session running with the lid shut — the part macOS otherwise
    /// refuses on battery.
    var sleepLidClosed: Bool {
        didSet { UserDefaults.standard.set(sleepLidClosed, forKey: "sleepLidClosed") }
    }

    /// End the session rather than let a forgotten one flatten the battery.
    var sleepEndOnLowBattery: Bool {
        didSet { UserDefaults.standard.set(sleepEndOnLowBattery, forKey: "sleepEndOnLowBattery") }
    }

    /// Charge percentage the cutoff above fires at.
    var sleepLowBatteryPercent: Int {
        didSet { UserDefaults.standard.set(sleepLowBatteryPercent, forKey: "sleepLowBatteryPercent") }
    }

    /// HUD when a session starts and when it ends.
    var sleepNotifications: Bool {
        didSet { UserDefaults.standard.set(sleepNotifications, forKey: "sleepNotifications") }
    }

    /// Seconds a watched download may go without growing before its session
    /// ends.
    var sleepDownloadTimeout: Double {
        didSet { UserDefaults.standard.set(sleepDownloadTimeout, forKey: "sleepDownloadTimeout") }
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

    /// Curve the sweep, vary its length and angle, and jitter the timing, so
    /// the movement doesn't read as a machine drawing the same line forever.
    var mouseMoveNatural: Bool {
        didSet { UserDefaults.standard.set(mouseMoveNatural, forKey: "mouseMoveNatural") }
    }

    /// Auto Mouse Move auto-off, in minutes; 0 = never.
    var mouseMoveAutoOffMinutes: Int {
        didSet { UserDefaults.standard.set(mouseMoveAutoOffMinutes, forKey: "mouseMoveAutoOffMinutes") }
    }

    /// Times the click sequence runs; 0 = until stopped.
    var autoClickRepeatCount: Int {
        didSet { UserDefaults.standard.set(autoClickRepeatCount, forKey: "autoClickRepeatCount") }
    }

    /// Points per second the cursor travels between nodes.
    var autoClickTravelSpeed: Double {
        didSet { UserDefaults.standard.set(autoClickTravelSpeed, forKey: "autoClickTravelSpeed") }
    }

    /// Radius in points that a click may land off its node's centre, so a long
    /// run never stacks every click on one pixel.
    var autoClickJitter: Int {
        didSet { UserDefaults.standard.set(autoClickJitter, forKey: "autoClickJitter") }
    }

    /// Fraction each delay is randomly stretched or squeezed by, so the rhythm
    /// isn't metronomic.
    var autoClickVariance: Double {
        didSet { UserDefaults.standard.set(autoClickVariance, forKey: "autoClickVariance") }
    }

    /// Bow of the travel path away from a straight line, as a fraction of the
    /// distance; 0 moves in straight lines.
    var autoClickCurve: Double {
        didSet { UserDefaults.standard.set(autoClickCurve, forKey: "autoClickCurve") }
    }

    /// Characters per second a text node types at.
    var autoClickTypingSpeed: Double {
        didSet { UserDefaults.standard.set(autoClickTypingSpeed, forKey: "autoClickTypingSpeed") }
    }

    /// Stop the sequence the moment the cursor is taken over by hand.
    var autoClickResistanceStop: Bool {
        didSet { UserDefaults.standard.set(autoClickResistanceStop, forKey: "autoClickResistanceStop") }
    }

    /// Turbo clicks per second.
    var turboClickRate: Double {
        didSet { UserDefaults.standard.set(turboClickRate, forKey: "turboClickRate") }
    }

    var turboClickButton: ClickButton {
        didSet { UserDefaults.standard.set(turboClickButton.rawValue, forKey: "turboClickButton") }
    }

    /// Auto Click auto-off, in minutes; 0 = never.
    var autoClickAutoOffMinutes: Int {
        didSet { UserDefaults.standard.set(autoClickAutoOffMinutes, forKey: "autoClickAutoOffMinutes") }
    }

    /// Show the Display brightness controls in the menu.
    var brightnessEnabled: Bool {
        didSet { UserDefaults.standard.set(brightnessEnabled, forKey: "brightnessEnabled") }
    }

    /// Dim a monitor that won't talk DDC with its gamma table instead. Off
    /// leaves such a display listed but uncontrollable.
    var brightnessSoftwareFallback: Bool {
        didSet { UserDefaults.standard.set(brightnessSoftwareFallback, forKey: "brightnessSoftwareFallback") }
    }

    /// Format a picked screen colour is copied in.
    var colorPickerFormat: ColorFormat {
        didSet { UserDefaults.standard.set(colorPickerFormat.rawValue, forKey: "colorPickerFormat") }
    }

    /// Selection-highlight accent in the clipboard panel.
    var accentName: String {
        didSet { UserDefaults.standard.set(accentName, forKey: "accentName") }
    }

    /// Taken from AppKit rather than SwiftUI: `Color.blue` is #0091FF, a notch
    /// cyanier than the #007AFF every native control draws with, and a filled
    /// button beside a segmented control shows the difference immediately.
    static let accentChoices: [(name: String, color: Color)] = [
        ("blue", Color(.sRGB, red: 0, green: 122 / 255, blue: 1)),
        ("purple", Color(nsColor: .systemPurple)),
        ("pink", Color(nsColor: .systemPink)),
        ("red", Color(nsColor: .systemRed)),
        ("orange", Color(nsColor: .systemOrange)),
        ("green", Color(nsColor: .systemGreen)),
        ("teal", Color(nsColor: .systemTeal))
    ]

    var accentColor: Color {
        Self.accentChoices.first { $0.name == accentName }?.color ?? .blue
    }

    // Deliberately not persisted: these all reset to off on every launch.
    var keyboardCleaningActive = false
    var preventSleepActive = false
    var mouseMoveActive = false
    var autoClickActive = false
    var turboClickActive = false
    /// Canvas is open for editing (not the same as the sequence running).
    var autoClickEditing = false

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
            "allowDisplaySleep": false,
            "sleepLidClosed": false,
            "sleepEndOnLowBattery": true,
            "sleepLowBatteryPercent": 10,
            "sleepNotifications": true,
            "sleepDownloadTimeout": 30.0,
            "mouseMoveInterval": 60.0,
            "mouseMoveDistance": 250,
            "mouseMoveSpeed": 700.0,
            "mouseMoveOnlyWhenIdle": true,
            "mouseMoveNatural": true,
            "mouseMoveAutoOffMinutes": 0,
            "autoClickRepeatCount": 0,
            "autoClickTravelSpeed": 1400.0,
            "autoClickJitter": 2,
            "autoClickVariance": 0.15,
            "autoClickCurve": 0.12,
            "autoClickTypingSpeed": 12.0,
            "autoClickResistanceStop": true,
            "autoClickAutoOffMinutes": 0,
            "turboClickRate": 25.0,
            "turboClickButton": "left",
            "brightnessEnabled": true,
            "brightnessSoftwareFallback": true,
            "colorPickerFormat": "hex",
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
        allowDisplaySleep = defaults.bool(forKey: "allowDisplaySleep")
        sleepLidClosed = defaults.bool(forKey: "sleepLidClosed")
        sleepEndOnLowBattery = defaults.bool(forKey: "sleepEndOnLowBattery")
        sleepLowBatteryPercent = defaults.integer(forKey: "sleepLowBatteryPercent")
        sleepNotifications = defaults.bool(forKey: "sleepNotifications")
        sleepDownloadTimeout = defaults.double(forKey: "sleepDownloadTimeout")
        mouseMoveInterval = defaults.double(forKey: "mouseMoveInterval")
        // Clamped on read: the slider's ceiling came down after release, and a
        // value stored above it would otherwise stick around unreachable.
        mouseMoveDistance = min(defaults.integer(forKey: "mouseMoveDistance"), 500)
        mouseMoveSpeed = defaults.double(forKey: "mouseMoveSpeed")
        mouseMoveOnlyWhenIdle = defaults.bool(forKey: "mouseMoveOnlyWhenIdle")
        mouseMoveNatural = defaults.bool(forKey: "mouseMoveNatural")
        mouseMoveAutoOffMinutes = defaults.integer(forKey: "mouseMoveAutoOffMinutes")
        autoClickRepeatCount = defaults.integer(forKey: "autoClickRepeatCount")
        autoClickTravelSpeed = defaults.double(forKey: "autoClickTravelSpeed")
        autoClickJitter = defaults.integer(forKey: "autoClickJitter")
        autoClickVariance = defaults.double(forKey: "autoClickVariance")
        autoClickCurve = defaults.double(forKey: "autoClickCurve")
        autoClickTypingSpeed = defaults.double(forKey: "autoClickTypingSpeed")
        autoClickResistanceStop = defaults.bool(forKey: "autoClickResistanceStop")
        autoClickAutoOffMinutes = defaults.integer(forKey: "autoClickAutoOffMinutes")
        turboClickRate = defaults.double(forKey: "turboClickRate")
        turboClickButton = ClickButton(rawValue: defaults.string(forKey: "turboClickButton") ?? "") ?? .left
        brightnessEnabled = defaults.bool(forKey: "brightnessEnabled")
        brightnessSoftwareFallback = defaults.bool(forKey: "brightnessSoftwareFallback")
        colorPickerFormat = ColorFormat(rawValue: defaults.string(forKey: "colorPickerFormat") ?? "") ?? .hex
        accentName = defaults.string(forKey: "accentName") ?? "blue"
    }
}
