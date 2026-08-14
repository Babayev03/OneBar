import SwiftUI

struct AutomationPane: View {
    private var state: AppState { AppState.shared }
    private var clicker: AutoClickService { AutoClickService.shared }
    private var sequence: ClickSequence { ClickSequence.shared }

    private var pointSummary: String {
        let count = sequence.nodes.count
        if count == 0 { return "No points yet — open the canvas and click to add one." }
        return "\(count) point\(count == 1 ? "" : "s") in the sequence."
    }

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

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Auto Click")
                                .font(.system(size: 14))
                            Spacer()
                            Button(state.autoClickEditing ? "Close Points" : "Edit Points…") {
                                ClickCanvasController.shared.toggle()
                                if state.autoClickEditing { NSApp.activate(ignoringOtherApps: true) }
                            }
                            Button(clicker.isRunning ? "Stop" : "Run") {
                                if clicker.isRunning {
                                    clicker.stop()
                                } else {
                                    state.autoClickActive = clicker.start()
                                }
                            }
                            .disabled(sequence.nodes.isEmpty && !clicker.isRunning)
                        }

                        Text(pointSummary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)

                        Divider()

                        HStack {
                            Text("Repeat")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: repeatBinding) {
                                Text("Until stopped").tag(0)
                                Text("Once").tag(1)
                                Text("5 times").tag(5)
                                Text("25 times").tag(25)
                                Text("100 times").tag(100)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        Divider()

                        HStack {
                            Text("Travel speed")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: travelSpeedBinding) {
                                Text("Slow").tag(400.0)
                                Text("Normal").tag(1400.0)
                                Text("Fast").tag(3000.0)
                                Text("Instant").tag(20000.0)
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }

                        Divider()

                        HStack {
                            Text("Click scatter")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(state.autoClickJitter) px")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                            Slider(value: jitterBinding, in: 0...12)
                                .frame(width: 140)
                        }

                        HStack {
                            Text("Timing variation")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(Int(state.autoClickVariance * 100))%")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                            Slider(value: varianceBinding, in: 0...0.5)
                                .frame(width: 140)
                        }

                        HStack {
                            Text("Path curve")
                                .font(.system(size: 14))
                            Spacer()
                            Text("\(Int(state.autoClickCurve * 100))%")
                                .font(.system(size: 13).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                            Slider(value: curveBinding, in: 0...0.4)
                                .frame(width: 140)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stop when you grab the mouse")
                                    .font(.system(size: 14))
                                Text("Moving the pointer yourself ends the run instead of fighting it.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: resistanceBinding)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }

                        Divider()

                        HStack {
                            Text("Auto turn off after")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: clickAutoOffBinding) {
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

                        Text("Open the canvas, click anywhere to drop a point, and drag points where you need them — they fire in order. Press Esc at any time to stop a run. Requires the Accessibility permission, and stops when you quit OneBar.")
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

    private var repeatBinding: Binding<Int> {
        Binding(get: { state.autoClickRepeatCount }, set: { state.autoClickRepeatCount = $0 })
    }

    private var travelSpeedBinding: Binding<Double> {
        Binding(get: { state.autoClickTravelSpeed }, set: { state.autoClickTravelSpeed = $0 })
    }

    private var jitterBinding: Binding<Double> {
        Binding(
            get: { Double(state.autoClickJitter) },
            set: { state.autoClickJitter = Int($0.rounded()) }
        )
    }

    private var varianceBinding: Binding<Double> {
        Binding(get: { state.autoClickVariance }, set: { state.autoClickVariance = $0 })
    }

    private var curveBinding: Binding<Double> {
        Binding(get: { state.autoClickCurve }, set: { state.autoClickCurve = $0 })
    }

    private var resistanceBinding: Binding<Bool> {
        Binding(get: { state.autoClickResistanceStop }, set: { state.autoClickResistanceStop = $0 })
    }

    private var clickAutoOffBinding: Binding<Int> {
        Binding(get: { state.autoClickAutoOffMinutes }, set: { state.autoClickAutoOffMinutes = $0 })
    }
}
