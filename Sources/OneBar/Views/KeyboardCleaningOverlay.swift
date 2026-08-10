import SwiftUI

struct KeyboardCleaningOverlay: View {
    var onDone: () -> Void

    @State private var remaining = AppState.shared.cleaningDuration
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "keyboard")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.pulse)

                Text("Keyboard Cleaning Mode")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Text("All keys are disabled — wipe away!")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))

                Text("Auto-exit in \(remaining)s")
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 8)

                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 140, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 12)
            }
        }
        .onReceive(timer) { _ in
            remaining -= 1
            if remaining <= 0 { onDone() }
        }
    }
}
