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
                            Text("Prevent Sleep mode")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: .constant("temporary")) {
                                Text("Temporary & safe").tag("temporary")
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Auto turn off after")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: autoOffBinding) {
                                Text("Never").tag(0)
                                Text("30 minutes").tag(30)
                                Text("1 hour").tag(60)
                                Text("2 hours").tag(120)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Allow the display to sleep")
                                    .font(.system(size: 14))
                                Text("Keeps the Mac awake but lets the screen turn off.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: allowDisplaySleepBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        Divider()

                        Text("This option works as long as your MacBook lid is open. It is automatically turned off if you exit OneBar, which makes it safer – impossible to forget that it's on.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    private var autoOffBinding: Binding<Int> {
        Binding(get: { state.sleepAutoOffMinutes }, set: { state.sleepAutoOffMinutes = $0 })
    }

    private var allowDisplaySleepBinding: Binding<Bool> {
        Binding(
            get: { state.allowDisplaySleep },
            set: { allowed in
                state.allowDisplaySleep = allowed
                SleepPreventionManager.shared.reapply()
            }
        )
    }

    private var colorFormatBinding: Binding<ColorFormat> {
        Binding(get: { state.colorPickerFormat }, set: { state.colorPickerFormat = $0 })
    }

    private var cleaningBinding: Binding<Int> {
        Binding(get: { state.cleaningDuration }, set: { state.cleaningDuration = $0 })
    }
}
