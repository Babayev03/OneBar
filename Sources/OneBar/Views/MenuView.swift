import SwiftUI

struct MenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var state: AppState { AppState.shared }
    private var stats: SystemStatsService { SystemStatsService.shared }
    private var clicker: AutoClickService { AutoClickService.shared }
    private var canvas: ClickCanvasController { ClickCanvasController.shared }
    private var turbo: TurboClickService { TurboClickService.shared }
    private var brightness: BrightnessService { BrightnessService.shared }
    private var sleep: SleepPreventionManager { SleepPreventionManager.shared }

    /// Control Center pushes a section's detail over the whole popover rather
    /// than opening a window; the menu does the same.
    private enum Route {
        case main
        case brightness
        case sleep
    }

    @State private var route: Route = .main
    @State private var appeared = false

    /// Measured so the Display screen can grow out of the row that opened it.
    @State private var rowFrame: CGRect = .zero
    @State private var mainSize: CGSize = .zero
    @State private var panelHeight: CGFloat = 0

    private static let menuSpace = "onebar.menu"

    var body: some View {
        VStack(spacing: 0) {
            switch route {
            case .main:
                mainScreen
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { mainSize = $0 }
                    .transition(transition(into: mainSize.height))
            case .brightness:
                BrightnessScreen { route = .main }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    .transition(transition(into: panelHeight))
            case .sleep:
                SleepScreen(back: { route = .main }, dismissMenu: { dismiss() })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    .transition(transition(into: panelHeight))
            }
        }
        .coordinateSpace(.named(Self.menuSpace))
        .frame(width: 300)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: route)
        // Entrance: fade + blur + slight scale each time the popover opens.
        // Scoped .animation (not withAnimation): a global transaction would
        // also capture the window's first-open size fitting, making the whole
        // popover grow in from the top-left corner.
        .opacity(appeared ? 1 : 0)
        .blur(radius: appeared ? 0 : 6)
        .scaleEffect(appeared ? 1 : 0.94, anchor: .top)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appeared)
        .onAppear {
            Task { @MainActor in appeared = true } // next tick, after first layout
            brightness.refreshSystemValues()
            brightness.startTracking()
        }
        .onDisappear {
            appeared = false
            route = .main
            brightness.stopTracking()
        }
    }

    // MARK: - Pushing to the Display screen

    /// Anchored at the Display row, so the screen appears to come out of the
    /// thing that was clicked rather than out of nowhere. `height` is the
    /// height of the view being transformed — the anchor is in that view's own
    /// unit space, not the popover's, so the row's position has to be
    /// re-expressed against it.
    private func transition(into height: CGFloat) -> AnyTransition {
        .scale(scale: 0.92, anchor: rowAnchor(in: height)).combined(with: .opacity)
    }

    private func rowAnchor(in height: CGFloat) -> UnitPoint {
        guard height > 0, mainSize.width > 0, rowFrame != .zero else { return .center }
        return UnitPoint(
            x: min(max(rowFrame.midX / mainSize.width, 0), 1),
            y: min(max(rowFrame.midY / height, 0), 1)
        )
    }

    private var mainScreen: some View {
        VStack(spacing: 0) {
            if state.systemMonitoringEnabled {
                ringsRow
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                Divider()
                    .padding(.horizontal, 14)
            }

            VStack(spacing: 2) {
                toggleRow("System Monitoring", isOn: systemMonitoringBinding)
                toggleRow("Clipboard History", isOn: clipboardBinding) {
                    ClipboardPanelController.shared.show()
                }
                toggleRow("Keyboard Cleaning", isOn: keyboardCleaningBinding)
                toggleRow("Auto Mouse Move", isOn: mouseMoveBinding)
            }
            .padding(.vertical, 10)

            autoClickRow

            turboRow

            scanRow

            screensRow

            Divider()
                .padding(.horizontal, 14)

            HStack {
                Button("Preferences") {
                    openWindow(id: "preferences")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .animation(.smooth(duration: 0.35), value: state.systemMonitoringEnabled)
    }

    /// Doorways, not controls: the sliders live on the Display screen and the
    /// session buttons on the Prevent Sleep one. Both screens grow out of this
    /// row, so it is the one that gets measured.
    private var screensRow: some View {
        // Each on its own full-width row rather than paired: these open
        // screens, and a doorway reads better wide than squeezed beside
        // another one.
        VStack(spacing: 8) {
            if state.brightnessEnabled, !brightness.displays.isEmpty {
                scanButton("Display", systemImage: "sun.max") { route = .brightness }
            }
            scanButton(
                sleepTitle,
                systemImage: sleep.isActive ? "cup.and.saucer.fill" : "moon.zzz"
            ) { route = .sleep }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.menuSpace)) } action: { rowFrame = $0 }
    }

    private var sleepTitle: String {
        guard sleep.isActive else { return "Prevent Sleep" }
        if let remaining = sleep.remaining { return "Awake \(Countdown.short(remaining))" }
        return "Awake"
    }

    private var ringsRow: some View {
        HStack(spacing: 24) {
            StatRingView(
                value: stats.cpuUsage,
                label: "CPU",
                systemImage: "cpu",
                detail: String(format: "CPU usage: %.0f%%", stats.cpuUsage * 100)
            )
            StatRingView(
                value: stats.memUsage,
                label: "MEM",
                systemImage: "memorychip",
                detail: String(format: "Memory: %.1f / %.0f GB", stats.memUsedGB, stats.memTotalGB)
            )
            StatRingView(
                value: stats.diskUsage,
                label: "DISK",
                systemImage: "internaldrive",
                detail: String(format: "Disk free: %.0f GB of %.0f GB", stats.diskFreeGB, stats.diskTotalGB)
            )
        }
        .padding(.vertical, 16)
        .onAppear { stats.start() }
        .onDisappear {
            // Keep sampling in the background only for the menubar readout.
            if !state.menubarLiveStats { stats.stop() }
        }
    }

    /// Not a toggle: Auto Click opens the point canvas, and running is a
    /// decision you make there once the points are placed.
    private var autoClickRow: some View {
        HStack(spacing: 8) {
            scanButton(
                state.autoClickEditing ? "Close Click Points" : "Click Points",
                systemImage: "cursorarrow.click.badge.clock"
            ) {
                // Drop the popover first: it sits above the canvas and would
                // otherwise hang around covering the corner you're placing into.
                dismiss()
                canvas.toggle()
                if state.autoClickEditing { NSApp.activate(ignoringOtherApps: true) }
            }
            scanButton(
                clicker.isRunning ? "Stop Auto Click" : "Run Auto Click",
                systemImage: clicker.isRunning ? "stop.fill" : "play.fill"
            ) {
                dismiss()
                if clicker.isRunning {
                    clicker.stop()
                } else {
                    state.autoClickActive = clicker.start()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var turboRow: some View {
        HStack(spacing: 8) {
            scanButton(
                turbo.isRunning ? "Stop Turbo" : "Turbo Click",
                systemImage: turbo.isRunning ? "bolt.slash.fill" : "bolt.fill"
            ) {
                dismiss()
                turbo.toggle()
            }
            scanButton("Pick Color", systemImage: "eyedropper") {
                // The loupe takes over the pointer; the popover would sit on
                // top of whatever you're trying to sample.
                dismiss()
                ColorPickerService.pick()
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var scanRow: some View {
        HStack(spacing: 8) {
            scanButton("Scan Text", systemImage: "text.viewfinder") {
                ScreenCaptureService.scan(.text)
            }
            scanButton("Scan QR", systemImage: "qrcode.viewfinder") {
                ScreenCaptureService.scan(.qr)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func scanButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlass(in: Capsule())
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, onLabelTap: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .contentShape(Rectangle())
                .onTapGesture { onLabelTap?() }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    // MARK: - Bindings with side effects

    private var systemMonitoringBinding: Binding<Bool> {
        Binding(
            get: { state.systemMonitoringEnabled },
            set: { enabled in
                state.systemMonitoringEnabled = enabled
                if enabled { stats.start() } else { stats.stop() }
            }
        )
    }

    private var clipboardBinding: Binding<Bool> {
        Binding(
            get: { state.clipboardEnabled },
            set: { enabled in
                state.clipboardEnabled = enabled
                if enabled {
                    ClipboardManager.shared.startPolling()
                } else {
                    ClipboardManager.shared.stopPolling()
                }
            }
        )
    }

    private var keyboardCleaningBinding: Binding<Bool> {
        Binding(
            get: { state.keyboardCleaningActive },
            set: { enabled in
                if enabled {
                    state.keyboardCleaningActive = KeyboardCleaningManager.shared.start()
                } else {
                    KeyboardCleaningManager.shared.stop()
                }
            }
        )
    }

    private var mouseMoveBinding: Binding<Bool> {
        Binding(
            get: { state.mouseMoveActive },
            set: { enabled in
                if enabled {
                    state.mouseMoveActive = MouseMoveService.shared.start()
                } else {
                    MouseMoveService.shared.stop()
                    state.mouseMoveActive = false
                }
            }
        )
    }
}
