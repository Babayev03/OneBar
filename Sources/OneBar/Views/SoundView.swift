import CoreAudio
import SwiftUI

/// The Sound screen the menu pushes to: one card per direction, each with the
/// device picker and whatever controls that device actually has.
struct SoundScreen: View {
    let back: () -> Void

    private var service: SoundService { SoundService.shared }
    private var state: AppState { AppState.shared }

    var body: some View {
        VStack(spacing: 10) {
            // The whole header row is the back button, title included: a bare
            // chevron is a few points across and easy to miss.
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Sound")
                        .font(.system(size: 15, weight: .semibold))

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 6)

            if service.outputs.isEmpty, service.inputs.isEmpty {
                Text("No audio devices found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            } else {
                VStack(spacing: 8) {
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
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 14)
        // Tighter than the menu's own lifecycle on purpose: the meter holds the
        // microphone open, so it lives and dies with this screen.
        .onAppear { service.startTracking() }
        .onDisappear { service.stopTracking() }
    }
}

/// One direction: which device is in use, and the controls it has. A picker
/// rather than a list — a Mac with a dock and a headset lists more devices than
/// the popover has height for, and a scrolling list inside a 300pt popover
/// clips whichever row is unlucky.
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
                            Text(option.name).tag(option.id)
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

    private var selection: Binding<AudioObjectID> {
        Binding(
            get: { device?.id ?? 0 },
            set: { id in
                guard let picked = devices.first(where: { $0.id == id }) else { return }
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
