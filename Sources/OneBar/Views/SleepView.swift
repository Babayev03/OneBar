import AppKit
import SwiftUI

/// The Prevent Sleep screen: a list of ways to start a session, the way
/// Amphetamine lays them out, plus every setting that used to live in
/// Preferences. Sub-lists (Minutes, Hours, apps) replace the list in place
/// rather than opening anything — the popover is 300pt wide and has nowhere to
/// put a submenu.
struct SleepScreen: View {
    let back: () -> Void
    /// Dropping the popover is the caller's job for anything that takes over
    /// the screen — the open panel, in this case.
    let dismissMenu: () -> Void

    private enum Page: Equatable {
        case root
        case minutes
        case hours
        case until
        case apps
    }

    /// "For 1 h 30 min" and "Until 22:30" are the same two numbers read two
    /// ways, which is why Amphetamine puts them behind one switch.
    private enum UntilMode: Hashable {
        case duration
        case time
    }

    @State private var page: Page = .root
    @State private var hovered: String?
    @State private var untilMode: UntilMode = .duration
    @State private var hours = 1
    @State private var minutes = 0
    @State private var untilTime = Date().addingTimeInterval(3600)

    private var service: SleepPreventionManager { SleepPreventionManager.shared }
    private var state: AppState { AppState.shared }

    private static let minuteChoices = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]
    private static let hourChoices = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 24]

    var body: some View {
        VStack(spacing: 10) {
            header

            VStack(spacing: 8) {
                switch page {
                case .root:
                    if service.isActive { statusCard }
                    startCard
                    optionsCard
                case .minutes:
                    card {
                        ForEach(Self.minuteChoices, id: \.self) { choice in
                            actionRow("\(choice) minutes", id: "m\(choice)") {
                                service.start(.lasting(choice))
                                page = .root
                            }
                        }
                    }
                case .hours:
                    card {
                        ForEach(Self.hourChoices, id: \.self) { choice in
                            actionRow(choice == 1 ? "1 hour" : "\(choice) hours", id: "h\(choice)") {
                                service.start(.lasting(choice * 60))
                                page = .root
                            }
                        }
                    }
                case .until:
                    untilCard
                case .apps:
                    appsCard
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: page)
    }

    /// The whole header row is the back button, title included: a bare chevron
    /// is a few points across and easy to miss.
    private var header: some View {
        Button {
            if page == .root { back() } else { page = .root }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var title: String {
        switch page {
        case .root: return "Prevent Sleep"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        case .until: return "Custom time"
        case .apps: return "While an app is running"
        }
    }

    // MARK: - Running session

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)

                Text(service.session?.summary ?? "On")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer()

                if let remaining = service.remaining {
                    Text(Countdown.short(remaining))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                service.stop()
            } label: {
                Text("Stop")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Starting one

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(service.isActive ? "Replace with" : "Start a session")

            card {
                actionRow("Indefinitely", id: "indefinitely") { service.start(.indefinite) }
                divider
                pushRow("Minutes", id: "minutes") { page = .minutes }
                divider
                pushRow("Hours", id: "hours") { page = .hours }
                divider
                pushRow("Custom time", id: "until") { page = .until }
                divider
                pushRow("While an app is running", id: "apps") { page = .apps }
                divider
                actionRow("While a file is downloading…", id: "file") {
                    // The panel comes up in front of everything; the popover
                    // would otherwise cover it, the way it covers the colour
                    // loupe in ColorPickerService.
                    dismissMenu()
                    service.startFileSession()
                }
            }
        }
    }

    /// Two genuinely different questions behind one switch: how long, or until
    /// when. Sharing a pair of numbers between them read as a copy of the same
    /// control, so "Until" gets a real time field.
    private var untilCard: some View {
        VStack(spacing: 12) {
            Picker("", selection: $untilMode) {
                Text("For").tag(UntilMode.duration)
                Text("Until").tag(UntilMode.time)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if untilMode == .duration {
                numberRow("hours", value: $hours, range: 0...999)
                numberRow("minutes", value: $minutes, range: 0...999, step: 5)
            } else {
                // The stepper field, not the clock face: it types, it steps,
                // and it is the same control macOS puts in its own date and
                // time settings.
                DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            }

            Text(untilPreview)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Button {
                service.start(.until(untilDate))
                page = .root
            } label: {
                Text("Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.accentColor)
            .controlSize(.large)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Typeable as well as steppable — a number you can only reach by clicking
    /// 45 times is not an input.
    private func numberRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1
    ) -> some View {
        let clamped = Binding(
            get: { value.wrappedValue },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )

        return HStack(spacing: 10) {
            TextField("", value: clamped, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .frame(minWidth: 64, maxWidth: 96, minHeight: 26)
                .fixedSize(horizontal: true, vertical: false)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(label)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Stepper("", value: clamped, in: range, step: step)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var canContinue: Bool {
        switch untilMode {
        case .duration: return hours > 0 || minutes > 0
        case .time: return true
        }
    }

    private var untilDate: Date {
        switch untilMode {
        case .duration:
            return Date().addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60))
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
            return Self.nextOccurrence(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
    }

    private var untilPreview: String {
        switch untilMode {
        case .duration:
            guard canContinue else { return "Pick a length" }
            return "Awake until \(Self.stamp(untilDate))"
        case .time:
            let away = Countdown.long(untilDate.timeIntervalSinceNow)
                .replacingOccurrences(of: " left", with: "")
            return "Awake for \(away)"
        }
    }

    private var appsCard: some View {
        card {
            // Long enough on a busy Mac to need its own scroller, short enough
            // that the popover doesn't grow past the screen.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        actionRow(
                            app.localizedName ?? "App",
                            id: "app\(app.processIdentifier)",
                            icon: app.icon
                        ) {
                            service.start(.whileAppRuns(
                                bundleID: app.bundleIdentifier ?? "",
                                name: app.localizedName ?? "App"
                            ))
                            page = .root
                        }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    /// Only apps with a Dock presence — the background agents behind every
    /// running Mac would bury the ones you meant. Amphetamine hides the same
    /// ones behind its "don't show helper apps" checkbox.
    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// A time that has already gone by today means tomorrow — nobody picks
    /// 08:00 at noon meaning four hours ago.
    private static func nextOccurrence(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        guard let today = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: Date()
        ) else { return Date() }
        return today > Date() ? today : today.addingTimeInterval(24 * 3600)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Naming the day as well, since nothing stops a session running past
    /// midnight and "until 07:00" would be ambiguous by two days.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Settings

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Options")

            card {
                settingRow("Let the display sleep") {
                    Toggle("", isOn: Binding(
                        get: { state.allowDisplaySleep },
                        set: { allowed in
                            state.allowDisplaySleep = allowed
                            service.reapply()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
                divider
                settingRow(
                    "Keep going with the lid closed",
                    note: "Works on battery, which macOS otherwise refuses."
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.sleepLidClosed },
                        set: { closed in
                            state.sleepLidClosed = closed
                            service.reapply()
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
                divider
                settingRow("Stop below battery") {
                    Picker("", selection: Binding(
                        get: { state.sleepEndOnLowBattery ? state.sleepLowBatteryPercent : 0 },
                        set: { percent in
                            state.sleepEndOnLowBattery = percent > 0
                            if percent > 0 { state.sleepLowBatteryPercent = percent }
                        }
                    )) {
                        Text("Never").tag(0)
                        Text("5%").tag(5)
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 86)
                }
                divider
                settingRow("Download timeout") {
                    Picker("", selection: Binding(
                        get: { state.sleepDownloadTimeout },
                        set: { state.sleepDownloadTimeout = $0 }
                    )) {
                        Text("5 sec").tag(5.0)
                        Text("30 sec").tag(30.0)
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 86)
                }
                divider
                settingRow("Notify on start and end") {
                    Toggle("", isOn: Binding(
                        get: { state.sleepNotifications },
                        set: { state.sleepNotifications = $0 }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)
                }
            }
        }
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 4)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var divider: some View {
        Divider().padding(.horizontal, 10)
    }

    private func actionRow(
        _ title: String,
        id: String,
        icon: NSImage? = nil,
        action: @escaping () -> Void
    ) -> some View {
        row(title, id: id, icon: icon, trailing: nil, action: action)
    }

    private func pushRow(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        row(title, id: id, icon: nil, trailing: "chevron.right", action: action)
    }

    private func row(
        _ title: String,
        id: String,
        icon: NSImage?,
        trailing: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowLabel(title, id: id, icon: icon, trailing: trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            hovered = inside ? id : (hovered == id ? nil : hovered)
        }
    }

    private func rowLabel(
        _ title: String,
        id: String,
        icon: NSImage?,
        trailing: String?
    ) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            }

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered == id ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(state.accentColor.opacity(hovered == id ? 0.85 : 0))
        )
        .foregroundStyle(hovered == id ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
    }

    private func settingRow<Control: View>(
        _ title: String,
        note: String? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
