import CoreAudio
import SwiftUI

/// The Sound screen the menu pushes to: one card per direction, each with the
/// device select and whatever controls that device actually has, plus the
/// output groups. Sub-pages replace the content in place rather than opening
/// anything — the popover is 300pt wide and has nowhere to put a sheet.
struct SoundScreen: View {
    let back: () -> Void

    private enum Page: Equatable {
        case root
        case newGroup
        case group(UUID)
    }

    @State private var page: Page = .root
    /// Member UIDs in the order they were picked — the first is the clock the
    /// others follow.
    @State private var picked: [String] = []
    @State private var groupName = ""
    @State private var hovered: String?

    private var service: SoundService { SoundService.shared }
    private var state: AppState { AppState.shared }

    var body: some View {
        VStack(spacing: 10) {
            header

            VStack(spacing: 8) {
                switch page {
                case .root: rootPage
                case .newGroup: newGroupPage
                case .group(let id): groupPage(id)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 14)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: page)
        // Tighter than the menu's own lifecycle on purpose: the meter holds the
        // microphone open, so it lives and dies with this screen.
        .onAppear { service.startTracking() }
        .onDisappear { service.stopTracking() }
    }

    /// The whole header row is the back button, title included: a bare chevron
    /// is a few points across and easy to miss.
    private var header: some View {
        Button {
            if page == .root { back() } else { page = .root }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var title: String {
        switch page {
        case .root: return "Sound"
        case .newGroup: return "New group"
        case .group(let id):
            return OutputGroupStore.shared.groups.first { $0.id == id }?.name ?? "Group"
        }
    }

    // MARK: - Root

    @ViewBuilder
    private var rootPage: some View {
        if service.outputs.isEmpty, service.inputs.isEmpty {
            Text("No audio devices found.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else {
            if !service.outputs.isEmpty {
                DeviceCard(title: "Output", devices: service.outputs)
                groupsCard
            }
            if !service.inputs.isEmpty {
                DeviceCard(
                    title: "Input",
                    devices: service.inputs,
                    meter: state.soundInputMeterEnabled
                )
            }
        }
    }

    private var groupsCard: some View {
        VStack(spacing: 6) {
            sectionLabel("Groups")

            card {
                ForEach(OutputGroupStore.shared.groups) { group in
                    row(group.name, id: "g\(group.id)", trailing: "chevron.right") {
                        page = .group(group.id)
                    }
                    divider
                }

                if service.groupCandidates.count > 1 {
                    row("New group…", id: "newgroup", leading: "plus") {
                        picked = []
                        groupName = ""
                        page = .newGroup
                    }
                } else {
                    // Saying nothing at all here reads as a missing feature
                    // rather than as a Mac with one speaker in it.
                    Text("Connect a second output device — headphones, AirPods, a display — to play to both at once.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Creating a group

    private var newGroupPage: some View {
        VStack(spacing: 8) {
            Text("Pick two or more. Sound plays to all of them at once.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            card {
                ForEach(Array(service.groupCandidates.enumerated()), id: \.element.id) { index, device in
                    if index > 0 { divider }
                    memberRow(device)
                }
            }

            TextField(suggestedName, text: $groupName)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 12))

            Button {
                service.createGroup(
                    name: groupName.isEmpty ? suggestedName : groupName,
                    memberUIDs: picked
                )
                page = .root
            } label: {
                Text("Create")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .liquidGlass(in: Capsule())
            .disabled(picked.count < 2)
            .opacity(picked.count < 2 ? 0.4 : 1)
        }
    }

    private func memberRow(_ device: SoundService.Device) -> some View {
        let index = picked.firstIndex(of: device.uid)
        return Button {
            if let index {
                picked.remove(at: index)
            } else {
                picked.append(device.uid)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: index == nil ? "square" : "checkmark.square.fill")
                    .font(.system(size: 12))

                Text(device.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                // The first one picked keeps time; the others are told to
                // follow it, or they slowly drift apart.
                if index == 0 {
                    Text("clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var suggestedName: String {
        let names = picked.compactMap { uid in
            service.groupCandidates.first { $0.uid == uid }?.name
        }
        return names.isEmpty ? "New group" : names.joined(separator: " + ")
    }

    // MARK: - One group

    @ViewBuilder
    private func groupPage(_ id: UUID) -> some View {
        if let group = OutputGroupStore.shared.groups.first(where: { $0.id == id }) {
            VStack(spacing: 8) {
                card {
                    let names = service.memberNames(of: group)
                    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                        if index > 0 { divider }
                        HStack(spacing: 8) {
                            Text(name)
                                .font(.system(size: 13))
                                .lineLimit(1)

                            Spacer()

                            if index == 0 {
                                Text("clock")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                }

                Text("The volume slider moves every device in the group together — a group has no volume control of its own.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                card {
                    row("Delete group", id: "delete", destructive: true) {
                        service.deleteGroup(group)
                        page = .root
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.vertical, 4)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var divider: some View {
        Divider().padding(.horizontal, 10)
    }

    private func row(
        _ title: String,
        id: String,
        leading: String? = nil,
        trailing: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leading {
                    Image(systemName: leading)
                        .font(.system(size: 11, weight: .semibold))
                }

                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Spacer()

                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered == id ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((destructive ? Color.red : state.accentColor)
                        .opacity(hovered == id ? 0.85 : 0))
            )
            .foregroundStyle(hovered == id
                             ? AnyShapeStyle(.white)
                             : AnyShapeStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { inside in
            hovered = inside ? id : (hovered == id ? nil : hovered)
        }
    }
}

/// One direction: which device is in use, and the controls it has. A select
/// rather than a list — a Mac with a dock and a headset has more devices than
/// the popover has height for, and a scrolling list clips whichever row is
/// unlucky.
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
