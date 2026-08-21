import SwiftUI

struct GeneralPane: View {
    @State private var launchOnStart = LaunchAtLogin.isEnabled

    private var state: AppState { AppState.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GroupBox {
                    HStack {
                        Text("Launch on start")
                            .font(.system(size: 14))
                        Spacer()
                        Toggle("", isOn: $launchOnStart)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: launchOnStart) { _, enabled in
                                if !LaunchAtLogin.set(enabled) {
                                    launchOnStart = LaunchAtLogin.isEnabled
                                }
                            }
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Live stats in menu bar")
                                .font(.system(size: 14))
                            Spacer()
                            Toggle("", isOn: liveStatsBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        Divider()

                        HStack {
                            Text("Update frequency")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: intervalBinding) {
                                Text("2 seconds").tag(2.0)
                                Text("5 seconds").tag(5.0)
                                Text("10 seconds").tag(10.0)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        Divider()

                        HStack {
                            Text("Warning level")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(Int(state.warnThreshold * 100))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.orange)
                            Slider(value: warnBinding, in: 0.5...0.9, step: 0.05)
                                .frame(width: 140)
                        }

                        HStack {
                            Text("Critical level")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(Int(state.critThreshold * 100))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.red)
                            Slider(value: critBinding, in: 0.6...0.95, step: 0.05)
                                .frame(width: 140)
                        }
                    }
                    .padding(6)
                } label: {
                    Text("System Monitoring")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Show sound controls")
                                .font(.system(size: 14))
                            Spacer()
                            Toggle("", isOn: soundBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Microphone level meter")
                                    .font(.system(size: 14))
                                Text("CoreAudio has no level property, so a meter has to open the microphone. The orange dot stays in the menu bar while the Sound screen is open, and nothing is recorded.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: inputMeterBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Sound")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Show display brightness")
                                .font(.system(size: 14))
                            Spacer()
                            Toggle("", isOn: brightnessBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Software dimming fallback")
                                    .font(.system(size: 14))
                                Text("For monitors that don't answer DDC. Dims the picture rather than the backlight, so it also shows up in screenshots.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: softwareDimmingBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Display Brightness")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("When ⌘Q is pressed")
                                    .font(.system(size: 14))
                                Text("Only applies while a OneBar window is focused. The Quit button in the menu always quits, and Force Quit is never affected.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Picker("", selection: quitBehaviorBinding) {
                                ForEach(QuitShortcutBehavior.allCases) { behavior in
                                    Text(behavior.title).tag(behavior)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                    }
                    .padding(6)
                }

                GroupBox {
                    HStack {
                        Text("Keyboard cleaning duration")
                            .font(.system(size: 14))
                        Spacer()
                        Picker("", selection: cleaningBinding) {
                            Text("30 seconds").tag(30)
                            Text("60 seconds").tag(60)
                            Text("2 minutes").tag(120)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Copy picked colors as")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: colorFormatBinding) {
                                ForEach(ColorFormat.allCases) { format in
                                    Text(format.title).tag(format)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        Text(state.colorPickerFormat.example)
                            .font(.system(size: 12).monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                } label: {
                    Text("Pick Color")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    HStack(spacing: 10) {
                        Text("Accent color")
                            .font(.system(size: 14))
                        Spacer()
                        ForEach(AppState.accentChoices, id: \.name) { choice in
                            Button {
                                state.accentName = choice.name
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 18, height: 18)
                                    .overlay(
                                        Circle().strokeBorder(
                                            Color.primary.opacity(state.accentName == choice.name ? 0.9 : 0),
                                            lineWidth: 2
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Bindings

    private var soundBinding: Binding<Bool> {
        Binding(
            get: { state.soundEnabled },
            set: { enabled in
                state.soundEnabled = enabled
                SoundService.shared.refresh()
            }
        )
    }

    private var inputMeterBinding: Binding<Bool> {
        Binding(
            get: { state.soundInputMeterEnabled },
            set: { enabled in
                state.soundInputMeterEnabled = enabled
                // Turning it off must let go of the microphone now, not
                // whenever the Sound screen next closes.
                if !enabled { SoundService.shared.stopTracking() }
            }
        )
    }

    private var brightnessBinding: Binding<Bool> {
        Binding(
            get: { state.brightnessEnabled },
            set: { enabled in
                state.brightnessEnabled = enabled
                // Hiding the controls must not leave a screen we dimmed dark.
                if !enabled { BrightnessService.shared.restoreDimming() }
                BrightnessService.shared.refresh()
            }
        )
    }

    private var softwareDimmingBinding: Binding<Bool> {
        Binding(
            get: { state.brightnessSoftwareFallback },
            set: { enabled in
                state.brightnessSoftwareFallback = enabled
                if !enabled { BrightnessService.shared.restoreDimming() }
                BrightnessService.shared.refresh()
            }
        )
    }

    private var liveStatsBinding: Binding<Bool> {
        Binding(
            get: { state.menubarLiveStats },
            set: { enabled in
                state.menubarLiveStats = enabled
                if enabled {
                    SystemStatsService.shared.start()
                } else {
                    SystemStatsService.shared.stop()
                }
            }
        )
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { state.statsInterval },
            set: { value in
                state.statsInterval = value
                SystemStatsService.shared.restart()
            }
        )
    }

    private var warnBinding: Binding<Double> {
        Binding(
            get: { state.warnThreshold },
            set: { value in
                state.warnThreshold = min(value, state.critThreshold - 0.05)
            }
        )
    }

    private var critBinding: Binding<Double> {
        Binding(
            get: { state.critThreshold },
            set: { value in
                state.critThreshold = max(value, state.warnThreshold + 0.05)
            }
        )
    }

    private var colorFormatBinding: Binding<ColorFormat> {
        Binding(get: { state.colorPickerFormat }, set: { state.colorPickerFormat = $0 })
    }

    private var quitBehaviorBinding: Binding<QuitShortcutBehavior> {
        Binding(get: { state.quitShortcutBehavior }, set: { state.quitShortcutBehavior = $0 })
    }

    private var cleaningBinding: Binding<Int> {
        Binding(get: { state.cleaningDuration }, set: { state.cleaningDuration = $0 })
    }
}
