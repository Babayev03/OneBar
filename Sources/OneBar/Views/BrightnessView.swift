import SwiftUI

/// The Display screen the menu pushes to: every controllable display with its
/// own slider.
struct BrightnessScreen: View {
    let back: () -> Void

    private var service: BrightnessService { BrightnessService.shared }

    var body: some View {
        VStack(spacing: 10) {
            // The whole header row goes back, title included: a bare chevron
            // is a few points across and easy to miss.
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Display")
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if service.displays.isEmpty {
                Text("No adjustable displays found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 8) {
                    ForEach(service.displays) { display in
                        DisplayCard(display: display)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 14)
    }
}

/// One display: name, percentage, slider, and an honest note when the dimming
/// is only a gamma table.
struct DisplayCard: View {
    let display: BrightnessService.Display

    private var service: BrightnessService { BrightnessService.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(display.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text("\(Int((display.brightness * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            BrightnessSlider(value: binding, isEnabled: display.isAdjustable)

            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // The probe can only guess whether a monitor really answers DDC.
            // Where it can be wrong, let it be overruled.
            if display.method == .ddc || display.method == .gamma {
                Toggle(isOn: Binding(
                    get: { service.usesSoftwareDimming(display.id) },
                    set: { _ in service.toggleSoftwareDimming(for: display.id) }
                )) {
                    Text("Software dimming")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var note: String? {
        switch display.method {
        case .gamma: return "Dimming the picture, not the backlight"
        case .virtual: return "AirPlay display — brightness is set on the device itself"
        case .unsupported: return "This display doesn't support brightness control"
        case .builtin, .ddc: return nil
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: {
                // Read back out of the service, not the captured copy, so a
                // drag keeps moving after the first change re-renders the row.
                service.displays.first { $0.id == display.id }?.brightness ?? display.brightness
            },
            set: { service.setBrightness($0, for: display.id) }
        )
    }
}

/// A slider bracketed by a small and a large sun, the way macOS draws its own.
struct BrightnessSlider: View {
    @Binding var value: Double
    var isEnabled = true

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.min")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .disabled(!isEnabled)

            Image(systemName: "sun.max")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
