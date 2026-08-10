import SwiftUI

struct MenuView: View {
    @Environment(\.openWindow) private var openWindow

    private var state: AppState { AppState.shared }
    private var stats: SystemStatsService { SystemStatsService.shared }

    @State private var appeared = false

    var body: some View {
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
                toggleRow("Prevent Sleep", isOn: preventSleepBinding)
            }
            .padding(.vertical, 10)

            scanRow

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
        .frame(width: 300)
        .animation(.smooth(duration: 0.35), value: state.systemMonitoringEnabled)
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
        }
        .onDisappear { appeared = false }
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

    private var preventSleepBinding: Binding<Bool> {
        Binding(
            get: { state.preventSleepActive },
            set: { enabled in
                if enabled {
                    SleepPreventionManager.shared.start()
                } else {
                    SleepPreventionManager.shared.stop()
                }
                state.preventSleepActive = SleepPreventionManager.shared.isActive
            }
        )
    }
}
