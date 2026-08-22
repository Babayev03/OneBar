import CoreAudio
import SwiftUI

/// The Sound screen the menu pushes to: one card per direction, each with the
/// device select and whatever controls that device actually has, plus per-app
/// volumes. Sub-pages replace the content in place rather than opening
/// anything — the popover is 300pt wide and has nowhere to put a sheet.
struct SoundScreen: View {
    let back: () -> Void

    private enum Page: Equatable {
        case root
        case apps
        case addApp
    }

    @State private var page: Page = .root
    @State private var appSearch = ""
    /// Owned explicitly so the field can be focused on arrival and, more
    /// importantly, *unfocused* on the way out — a text field that keeps first
    /// responder as the page changes leaves its focus ring drawn around
    /// whichever view lands in its place.
    @FocusState private var searchFocused: Bool
    @State private var hovered: String?
    @State private var routingAppID: String?
    /// AppKit dismisses a child popover before forwarding the outside click to
    /// SwiftUI. Remember that dismissal so the same physical click cannot also
    /// activate the header underneath it.
    @State private var routePopoverDismissedAt = Date.distantPast

    private var service: SoundService { SoundService.shared }
    private var appAudio: AppAudioService { AppAudioService.shared }
    private var state: AppState { AppState.shared }

    var body: some View {
        VStack(spacing: 10) {
            header

            VStack(spacing: 8) {
                switch page {
                case .root: rootPage
                case .apps: appsPage
                case .addApp: addAppPage
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: page)
        // Tighter than the menu's own lifecycle on purpose: the meter holds the
        // microphone open, so it lives and dies with this screen.
        .onAppear {
            service.startTracking()
            // System Settings and other apps write these behind our back, and
            // a read is ~1µs, so they are re-read on the way in rather than
            // watched for.
            SystemSoundService.shared.refresh()
        }
        .onDisappear {
            routingAppID = nil
            service.stopTracking()
        }
    }

    /// The whole header row is the back button, title included: a bare chevron
    /// is a few points across and easy to miss.
    private var header: some View {
        Button(action: navigateBack) {
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

    private func navigateBack() {
        // The route picker is a nested AppKit popover whose presenter lives in
        // the apps page. Removing that row in the same transaction leaves the
        // outer menu temporarily fitting itself against a disappearing anchor.
        // Consume this click as a dismissal; navigation requires a later click.
        searchFocused = false
        guard Date().timeIntervalSince(routePopoverDismissedAt) > 0.35 else { return }
        guard routingAppID != nil else {
            performBackNavigation()
            return
        }

        // Match native/FineTune popover event handling: a click outside the
        // child picker dismisses that picker and is not forwarded into the
        // control underneath it. The next click can navigate normally.
        var dismissal = Transaction(animation: nil)
        dismissal.disablesAnimations = true
        withTransaction(dismissal) {
            routePopoverDismissedAt = Date()
            routingAppID = nil
        }
    }

    private func performBackNavigation() {
        // One layer at a time: Add-an-app goes back to the app list, not out to
        // the Sound screen.
        switch page {
        case .root: back()
        case .addApp: page = .apps
        case .apps: page = .root
        }
    }

    private var title: String {
        switch page {
        case .root: return "Sound"
        case .apps: return "App volumes"
        case .addApp: return "Add an app"
        }
    }

    // MARK: - Root

    @ViewBuilder
    private var rootPage: some View {
        if service.outputs.isEmpty, service.inputs.isEmpty {
            Text("No audio devices found.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else {
            if !service.outputs.isEmpty {
                DeviceCard(title: "Output", devices: service.outputs)
            }
            if !service.inputs.isEmpty {
                DeviceCard(
                    title: "Input",
                    devices: service.inputs,
                    meter: state.soundInputMeterEnabled
                )
            }
            AlertsCard()

            // Last: neither of these is a thing you touch often, unlike the
            // two selects above them.
            if !service.outputs.isEmpty {
                extrasCard
            }
        }
    }

    private var extrasCard: some View {
        VStack(spacing: 6) {
            card {
                row(
                    "App volumes",
                    id: "apps",
                    trailing: "chevron.right",
                    detail: appAudio.adjustedCount > 0 ? "\(appAudio.adjustedCount)" : nil
                ) {
                    appAudio.refresh()
                    page = .apps
                }
            }
        }
    }

    // MARK: - Per-app volumes

    @ViewBuilder
    private var appsPage: some View {
        if let error = appAudio.lastError {
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("macOS calls reading an app's audio \"recording\" — it is played straight back out at the level you picked, and nothing is stored or sent anywhere.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }

        card {
            ForEach(Array(appAudio.apps.enumerated()), id: \.element.id) { index, app in
                if index > 0 { divider }
                appRow(app)
            }

            if !appAudio.apps.isEmpty { divider }

            row("Add an app…", id: "addapp", leading: "plus") {
                appSearch = ""
                // Scanned here, once, rather than while the list is on screen.
                appAudio.refreshCandidates()
                page = .addApp
            }
        }

        // Diagnostics, off by default — developer language, not for everyday
        // use. Uncomment to see, per app, whether a tap exists and whether its
        // render loop is being pumped ("Music: tapped, 4211 renders"). A
        // render count that climbs is healthy; one stuck at zero means the
        // loop never runs, which is the failure that is otherwise
        // indistinguishable from "the slider does nothing".
        //
        // if !appAudio.status.isEmpty {
        //     Text(appAudio.status)
        //         .font(.system(size: 9).monospaced())
        //         .foregroundStyle(.secondary)
        //         .fixedSize(horizontal: false, vertical: true)
        //         .padding(.horizontal, 4)
        // }

        Text(appAudio.apps.isEmpty
             ? "Add an app to give it its own volume. Nothing appears here on its own — only what you add is routed through OneBar."
             : "A listed app is routed through OneBar while it is playing, at any level, so moving a slider is silent. Anything not listed is untouched.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// Everything installed, not only what is running — a level can be set for
    /// an app that isn't open yet and simply waits for it.
    private var addAppPage: some View {
        let candidates = appAudio.candidates(matching: appSearch)
        return VStack(spacing: 8) {
            TextField("Search", text: $appSearch)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 12))
                .focused($searchFocused)
                // Next tick, after the page has laid out: focusing during the
                // transition does not take.
                .onAppear { Task { @MainActor in searchFocused = true } }

            if candidates.isEmpty {
                Text(appSearch.isEmpty ? "Nothing left to add." : "No app matches that.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                card {
                    ScrollView {
                        // Lazy: a hundred rows, each with an icon, are not all
                        // built to show eight of them.
                        LazyVStack(spacing: 0) {
                            ForEach(candidates) { candidate in
                                Button {
                                    searchFocused = false
                                    appAudio.add(bundleID: candidate.bundleID, name: candidate.name)
                                    appSearch = ""
                                    page = .apps
                                } label: {
                                    HStack(spacing: 7) {
                                        if let icon = candidate.icon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .frame(width: 15, height: 15)
                                        }
                                        Text(candidate.name)
                                            .font(.system(size: 13))
                                            .lineLimit(1)

                                        Spacer()

                                        if candidate.isPlaying {
                                            Text("playing")
                                                .font(.system(size: 9))
                                                .foregroundStyle(hovered == candidate.bundleID
                                                                 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                        } else if candidate.isRunning {
                                            Text("open")
                                                .font(.system(size: 9))
                                                .foregroundStyle(hovered == candidate.bundleID
                                                                 ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(state.accentColor.opacity(hovered == candidate.bundleID ? 0.85 : 0))
                                    )
                                    .foregroundStyle(hovered == candidate.bundleID
                                                     ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 4)
                                .onHover { inside in
                                    hovered = inside ? candidate.bundleID
                                        : (hovered == candidate.bundleID ? nil : hovered)
                                }
                            }
                        }
                    }
                    // An explicit height, not a maximum: a ScrollView has no
                    // height of its own, and the popover sizes itself to fit
                    // its content, so `maxHeight` collapses it to a couple of
                    // rows. Sized to the list until it would outgrow the
                    // popover.
                    .frame(height: min(300, CGFloat(candidates.count) * 27 + 8))
                }
            }
        }
    }

    private func appRow(_ app: AppAudioService.App) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 15, height: 15)
                }

                Text(app.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                if app.isMuted {
                    Text("muted")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if app.boost.isBoosted {
                    Text("\(Int((app.volume * 100).rounded()))% · \(app.boost.label)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(state.accentColor)
                } else {
                    Text("\(Int((app.volume * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    appAudio.toggleMute(for: app.bundleID)
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .frame(width: 14)
                        .foregroundStyle(app.isMuted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: {
                            // Read back out of the service so a drag keeps
                            // moving after the first change re-renders the row.
                            appAudio.apps.first { $0.bundleID == app.bundleID }?.volume ?? app.volume
                        },
                        set: { appAudio.setVolume($0, for: app.bundleID) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(app.isMuted)

                BoostChevrons(level: app.boost) {
                    appAudio.cycleBoost(for: app.bundleID)
                }

                // A route can only be applied once CoreAudio exposes an
                // active process for the app. Inactive pinned apps stay in the
                // list, but do not offer a control that cannot act yet.
                if app.isPlaying {
                    Button {
                        if routingAppID != app.bundleID {
                            routePopoverDismissedAt = .distantPast
                        }
                        routingAppID = routingAppID == app.bundleID ? nil : app.bundleID
                    } label: {
                        routeTriggerIcon(for: app)
                            .foregroundStyle(
                                routingAppID == app.bundleID
                                    ? AnyShapeStyle(state.accentColor)
                                    : AnyShapeStyle(.secondary)
                            )
                            .frame(width: 20, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(state.accentColor.opacity(
                                        routingAppID == app.bundleID ? 0.14 : 0
                                    ))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose app output")
                    .popover(
                        isPresented: routePopoverPresented(for: app.bundleID),
                        arrowEdge: .trailing
                    ) {
                        AppOutputRoutePopover(
                            bundleID: app.bundleID,
                            dismiss: { routingAppID = nil }
                        )
                    }
                }

                Button {
                    appAudio.remove(app.bundleID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !app.isRunning {
                Text("Not running")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if !app.isPlaying {
                Text("Not playing right now")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func routeTriggerIcon(for app: AppAudioService.App) -> some View {
        if app.outputMode == .multi {
            let selected = service.routingOutputs.filter {
                app.multiOutputDeviceUIDs.contains($0.uid)
            }
            if let first = selected.first {
                AudioDeviceIcon(device: first, size: 17)
                    .overlay(alignment: .bottomTrailing) {
                        if selected.count > 1 {
                            Text("\(selected.count)")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .background(Capsule().fill(state.accentColor))
                                .offset(x: 4, y: 3)
                        }
                    }
            } else {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 13))
                    .symbolRenderingMode(.hierarchical)
            }
        } else if app.outputDeviceUID == nil {
            Image(systemName: "globe")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
        } else if let device = service.routingOutputs.first(where: {
            $0.uid == app.outputDeviceUID
        }) {
            AudioDeviceIcon(device: device, size: 17)
        } else {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 13))
                .symbolRenderingMode(.hierarchical)
        }
    }

    private func routePopoverPresented(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { routingAppID == bundleID },
            set: { presented in
                if !presented, routingAppID == bundleID {
                    routePopoverDismissedAt = Date()
                    routingAppID = nil
                }
            }
        )
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

    private func row(
        _ title: String,
        id: String,
        leading: String? = nil,
        trailing: String? = nil,
        detail: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leading {
                    Image(systemName: leading)
                        .font(.system(size: 11, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                if let detail {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(hovered == id ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }

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
                    .fill((destructive ? Color.red : state.accentColor)
                        .opacity(hovered == id ? 0.85 : 0))
            )
            .foregroundStyle(hovered == id
                             ? AnyShapeStyle(.white)
                             : AnyShapeStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            hovered = inside ? id : (hovered == id ? nil : hovered)
        }
    }
}

/// FineTune-style per-app route picker, kept compact enough to sit beside
/// OneBar's 300-point menu. Single can follow System Audio or pin one device;
/// Multi mirrors to every checked physical destination.
private struct AppOutputRoutePopover: View {
    let bundleID: String
    let dismiss: () -> Void

    private var appAudio: AppAudioService { AppAudioService.shared }
    private var sound: SoundService { SoundService.shared }

    private var app: AppAudioService.App? {
        appAudio.apps.first { $0.bundleID == bundleID }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: mode) {
                Text("Single").tag(AppOutputMode.single)
                Text("Multi").tag(AppOutputMode.multi)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            if app?.outputMode == .multi {
                multiRows
            } else {
                singleRows
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private var mode: Binding<AppOutputMode> {
        Binding(
            get: { app?.outputMode ?? .single },
            set: { appAudio.setOutputMode($0, for: bundleID) }
        )
    }

    @ViewBuilder
    private var singleRows: some View {
        routeButton(
            title: "System Audio",
            subtitle: "Follows macOS default",
            symbol: "globe",
            device: nil,
            selected: app?.outputDeviceUID == nil
        ) {
            appAudio.setSingleOutput(nil, for: bundleID)
            dismiss()
        }

        ForEach(sound.routingOutputs) { device in
            routeButton(
                title: device.name,
                symbol: "speaker.wave.2",
                device: device,
                selected: app?.outputDeviceUID == device.uid
            ) {
                appAudio.setSingleOutput(device.uid, for: bundleID)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var multiRows: some View {
        HStack(spacing: 8) {
            Image(systemName: "square")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("System Audio")
                    .font(.system(size: 12, weight: .medium))
                Text("Not available in Multi")
                    .font(.system(size: 9))
            }
            .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)

        ForEach(sound.routingOutputs) { device in
            let selected = app?.multiOutputDeviceUIDs.contains(device.uid) == true
            routeButton(
                title: device.name,
                symbol: "speaker.wave.2",
                device: device,
                selected: selected,
                checkbox: true
            ) {
                appAudio.toggleMultiOutput(device.uid, for: bundleID)
            }
        }

        if sound.routingOutputs.count < 2 {
            Text("Connect another output to mirror this app to multiple devices.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    private func routeButton(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        device: SoundService.Device?,
        selected: Bool,
        checkbox: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if checkbox {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                    } else if selected {
                        Image(systemName: "checkmark")
                    } else {
                        Color.clear
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? AnyShapeStyle(AppState.shared.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)

                if let device {
                    AudioDeviceIcon(device: device, size: 16)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if device?.isDefault == true {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AudioDeviceIcon: View {
    let device: SoundService.Device
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = device.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "speaker.wave.2")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .frame(width: size, height: size)
    }
}

/// One direction: which device is in use, and the controls it has. A select
/// rather than a list — a Mac with a dock and a headset has more devices than
/// the popover has height for, and a scrolling list clips whichever row is
/// unlucky.
/// Alert volume and UI sound effects. Drawn as a peer of the Output and Input
/// cards because that is what it is — the level of a third thing the Mac
/// plays, which no device slider on this page moves.
struct AlertsCard: View {
    private var system: SystemSoundService { SystemSoundService.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Alerts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int((system.alertVolume * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                // Previewed on release, not during the drag: one beep per
                // step would be a stutter rather than a demonstration, and
                // the alert sound is long enough to overlap itself.
                Slider(value: volume, in: 0...1) { editing in
                    if !editing { system.previewAlert() }
                }
                .controlSize(.small)

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound effects")
                        .font(.system(size: 12))
                    Text("Clicks, drag and drop, emptying the trash.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Toggle("", isOn: effects)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var volume: Binding<Double> {
        Binding(get: { system.alertVolume }, set: { system.alertVolume = $0 })
    }

    private var effects: Binding<Bool> {
        Binding(get: { system.soundEffectsEnabled }, set: { system.soundEffectsEnabled = $0 })
    }
}

struct DeviceCard: View {
    let title: String
    let devices: [SoundService.Device]
    var meter = false

    private var service: SoundService { SoundService.shared }

    private var isInput: Bool { devices.first?.scope == kAudioObjectPropertyScopeInput }

    /// Falls back to the first device so the card still renders during the
    /// moment after a default disappears and before the new one is read.
    private var device: SoundService.Device? {
        devices.first { $0.isDefault } ?? devices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device {
                HStack {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    // A percentage on a device with no volume control would
                    // read 0% and mean nothing.
                    if device.isAdjustable {
                        Text("\(Int((device.volume * 100).rounded()))%")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Picker("", selection: selection) {
                        ForEach(devices) { option in
                            // Keyed on the UID, not the AudioObjectID: ids are
                            // handed out per connection, so plugging in AirPods
                            // or rebuilding a group renumbers them and the
                            // selection stops matching any row — which reads as
                            // a select that won't change.
                            Text(option.name).tag(option.uid)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)

                    // Mute normally rides on the slider row. A device that can
                    // mute but not change level has no slider row to ride on.
                    if device.canMute, !device.isAdjustable {
                        muteButton(device)
                    }
                }

                if device.isAdjustable {
                    HStack(spacing: 8) {
                        if device.canMute {
                            muteButton(device)
                        } else {
                            icon(for: device).foregroundStyle(.secondary)
                        }

                        Slider(value: volume(of: device), in: 0...1)
                            .controlSize(.small)

                        Image(systemName: isInput ? "mic.fill" : "speaker.wave.3.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(isInput
                         ? "This microphone sets its own level — nothing here can move it"
                         : "This device sets its own volume — use its own controls")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if meter, isInput, service.isMetering {
                    LevelBar(level: service.inputLevel)

                    Text("The orange dot in the menu bar is macOS saying the microphone is open — this meter is the only thing using it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func muteButton(_ device: SoundService.Device) -> some View {
        Button {
            service.toggleMute(for: device.id, scope: device.scope)
        } label: {
            icon(for: device)
                .foregroundStyle(device.isMuted ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func icon(for device: SoundService.Device) -> some View {
        let symbol: String
        if isInput {
            symbol = device.isMuted ? "mic.slash.fill" : "mic.fill"
        } else {
            symbol = device.isMuted ? "speaker.slash.fill" : "speaker.fill"
        }
        return Image(systemName: symbol)
            .font(.system(size: 10))
            .frame(width: 14)
    }

    private var selection: Binding<String> {
        Binding(
            get: { device?.uid ?? "" },
            set: { uid in
                guard let picked = devices.first(where: { $0.uid == uid }) else { return }
                service.makeDefault(picked.id, scope: picked.scope)
            }
        )
    }

    private func volume(of device: SoundService.Device) -> Binding<Double> {
        Binding(
            get: {
                // Read back out of the service, not the captured copy, so a
                // drag keeps moving after the first change re-renders the card.
                let list = isInput ? service.inputs : service.outputs
                return list.first { $0.id == device.id }?.volume ?? device.volume
            },
            set: { service.setVolume($0, for: device.id, scope: device.scope) }
        )
    }
}

/// A plain peak bar. No animation of its own — the value already arrives
/// smoothed, and a second easing on top would only add lag.
struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.25))

                Capsule()
                    .fill(AppState.shared.accentColor)
                    .frame(width: max(0, min(level, 1)) * geometry.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// Stacked chevron boost indicator matching FineTune — 3 SF Symbol chevrons that light up based on boost level.
/// Click to cycle: 1x → 2x → 3x → 4x → 1x
struct BoostChevrons: View {
    let level: BoostLevel
    let onTap: () -> Void

    @State private var isHovered = false

    private var litCount: Int {
        switch level {
        case .x1: return 0
        case .x2: return 1
        case .x3: return 2
        case .x4: return 3
        }
    }

    private func chevronColor(at index: Int) -> Color {
        if index < litCount {
            return AppState.shared.accentColor
        } else {
            return isHovered ? .primary.opacity(0.35) : .primary.opacity(0.18)
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: -3) {
                ForEach((0..<3).reversed(), id: \.self) { index in
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(chevronColor(at: index))
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Volume boost: \(level.label)")
        .animation(.snappy(duration: 0.2), value: level)
    }
}
