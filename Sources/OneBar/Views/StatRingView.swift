import SwiftUI

struct StatRingView: View {
    let value: Double          // 0...1
    let label: String
    let systemImage: String
    let detail: String

    @State private var hovering = false

    private var ringColor: Color {
        let state = AppState.shared
        switch value {
        case ..<state.warnThreshold: return .green
        case ..<state.critThreshold: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: 6)

            Circle()
                .trim(from: 0, to: max(value, 0.02))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Only the inside morphs on hover; the ring itself never changes.
            ZStack {
                if hovering {
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(value >= AppState.shared.warnThreshold ? ringColor : .primary)
                        .contentTransition(.numericText(value: value * 100))
                        .transition(.blurReplace)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: systemImage)
                            .font(.system(size: 16, weight: .medium))
                        Text(label)
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.5)
                    }
                    .foregroundStyle(.primary)
                    .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.3), value: hovering)
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.8), value: value)
        .animation(.easeInOut(duration: 0.8), value: ringColor)
        .help(detail)
    }
}
