import SwiftUI

struct AutomationPane: View {
    private var state: AppState { AppState.shared }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Auto Mouse Move")
                                .font(.system(size: 14))
                            Spacer()
                            Toggle("", isOn: activeBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        Divider()

                        HStack {
                            Text("Move after")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: intervalBinding) {
                                Text("15 seconds").tag(15.0)
                                Text("30 seconds").tag(30.0)
                                Text("1 minute").tag(60.0)
                                Text("2 minutes").tag(120.0)
                                Text("4 minutes").tag(240.0)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        HStack {
                            Text("Movement distance")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(state.mouseMoveDistance) px")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                            // No `step:` — SwiftUI draws a tick-mark track under any
                            // stepped slider. Rounding happens in the binding instead.
                            Slider(value: distanceBinding, in: 10...500)
                                .frame(width: 140)
                        }

                        HStack {
                            Text("Movement speed")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: speedBinding) {
                                Text("Slow").tag(300.0)
                                Text("Normal").tag(700.0)
                                Text("Fast").tag(1400.0)
                                Text("Instant").tag(6000.0)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Only while you're away")
                                    .font(.system(size: 14))
                                Text("Waits for real input to stop, so it never tugs the cursor mid-drag.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: onlyWhenIdleBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
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
                                Text("4 hours").tag(240)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        Divider()

                        Text("Glides the pointer out and back along a smooth path, which resets the idle timer apps like Teams and Slack watch to decide you're away. Grab the mouse mid-sweep and it stops immediately. Nothing is ever clicked or typed. Requires the Accessibility permission, and turns off when you quit OneBar.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Bindings

    private var activeBinding: Binding<Bool> {
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

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { state.mouseMoveInterval },
            set: { value in
                state.mouseMoveInterval = value
                MouseMoveService.shared.reapply()
            }
        )
    }

    private var distanceBinding: Binding<Double> {
        Binding(
            get: { Double(state.mouseMoveDistance) },
            set: { state.mouseMoveDistance = Int(($0 / 10).rounded()) * 10 }
        )
    }

    private var speedBinding: Binding<Double> {
        Binding(get: { state.mouseMoveSpeed }, set: { state.mouseMoveSpeed = $0 })
    }

    private var onlyWhenIdleBinding: Binding<Bool> {
        Binding(
            get: { state.mouseMoveOnlyWhenIdle },
            set: { value in
                state.mouseMoveOnlyWhenIdle = value
                MouseMoveService.shared.reapply()
            }
        )
    }

    private var autoOffBinding: Binding<Int> {
        Binding(get: { state.mouseMoveAutoOffMinutes }, set: { state.mouseMoveAutoOffMinutes = $0 })
    }
}
