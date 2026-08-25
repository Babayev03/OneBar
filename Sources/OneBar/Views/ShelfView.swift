import AppKit
import SwiftUI

struct ShelfView: View {
    let controller: ShelfController

    private var model: ShelfModel { controller.model }
    private var manager: ShelfManager { ShelfManager.shared }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            switch model.route {
            case .items:
                if model.items.isEmpty {
                    emptyState
                } else {
                    content
                    footer
                }
            case .customize:
                ShelfCustomizeView(controller: controller)
            }
        }
        .opacity(showsDockHandle ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: shelfCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: shelfCornerRadius, style: .continuous)
                .strokeBorder(
                    model.isDropTargeted ? model.color : Color.primary.opacity(0.1),
                    lineWidth: model.isDropTargeted ? 2 : 1
                )
        }
        .overlay(alignment: collapsedHandleAlignment) {
            if showsDockHandle {
                Image(systemName: model.collapseEdge == .left ? "chevron.right" : "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                    .frame(width: ShelfCollapse.docked.visibleWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { controller.setDockHandleHovered($0) }
                    .accessibilityLabel("Show \(dockHandleLabel)")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: shelfCornerRadius, style: .continuous))
        .opacity(model.isPresented ? 1 : 0)
        .scaleEffect(model.isPresented ? 1 : 0.94)
        .animation(.easeOut(duration: 0.12), value: model.isDropTargeted)
    }

    private var showsDockHandle: Bool {
        model.collapse == .docked && !model.isPeeking
    }

    private var shelfCornerRadius: CGFloat { 18 }

    private var dockHandleLabel: String {
        ShelfHandlePresentation.label(
            shelfName: model.name,
            itemTitles: model.items.map(\.title),
            fallback: model.title
        )
    }

    private var collapsedHandleAlignment: Alignment {
        model.collapseEdge == .left ? .trailing : .leading
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.color)
                .frame(width: 8, height: 8)
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            headerButton(
                model.isPinned ? "pin.fill" : "pin",
                help: model.isPinned
                    ? "Unpin — the shelf stops coming back at launch"
                    : "Pin — the shelf comes back the next time OneBar starts",
                active: model.isPinned
            ) {
                controller.togglePin()
            }

            overflowMenu

            headerButton("xmark", help: "Close the shelf") {
                controller.close()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Run an Action…") { ShelfActionRunner.showCommandBar(in: controller) }
                .keyboardShortcut("k")
                .disabled(model.items.isEmpty)

            Menu("Item Actions") {
                ShelfActionMenuItems(controller: controller, scope: .selection)
            }
            .disabled(model.items.isEmpty)

            Divider()
            Button("Customize…") { controller.showCustomize() }

            Picker("Layout", selection: layoutBinding) {
                ForEach(ShelfLayout.allCases) { layout in
                    Label(layout.title, systemImage: layout.symbol).tag(layout)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Menu("Move Aside") {
                Button("Dock to Left Edge") { controller.dock(to: .left) }
                Button("Dock to Right Edge") { controller.dock(to: .right) }
                Divider()
                Button("Retract to Left Edge") { controller.retract(to: .left) }
                Button("Retract to Right Edge") { controller.retract(to: .right) }
                if model.collapse != nil {
                    Divider()
                    Button("Bring Back") { controller.expand() }
                }
            }
            Toggle("Keep in this Space", isOn: keepInSpaceBinding)

            if !manager.pinned.isEmpty || !manager.recent.isEmpty {
                Divider()
                Menu("Reopen Shelf") {
                    if !manager.pinned.isEmpty {
                        Section("Pinned") {
                            ForEach(manager.pinned) { snapshot in
                                Button(snapshot.displayName) { manager.reopen(snapshot) }
                            }
                        }
                    }
                    if !manager.pinned.isEmpty, !manager.recent.isEmpty { Divider() }
                    ForEach(manager.recent) { snapshot in
                        Button(snapshot.displayName) { manager.reopen(snapshot) }
                    }
                    if !manager.recent.isEmpty {
                        Divider()
                        Button("Clear Recent List") { manager.clearRecents() }
                    }
                }
            }

            Divider()
            Button("New Shelf") { manager.newShelf(at: nil) }
            Button("Clear Shelf") { controller.clear() }
                .disabled(model.items.isEmpty)
            Button("Close All Shelves") { manager.closeAll() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 18, height: 18)
        .help("Shelf actions")
    }

    private func headerButton(
        _ symbol: String,
        help: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active ? model.color : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Contents

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let previous = manager.mostRecentlyClosed {
                Button {
                    controller.restorePrevious()
                } label: {
                    Label("Restore \(previous.displayName)", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.color)
                .help("Bring back the files from the last shelf you closed")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu { shelfMenuItems }
    }

    /// Raised on empty shelf space, where there is no item under the pointer.
    /// Scoped to the shelf rather than the selection so nothing destructive can
    /// run against every item at once from a click on the background.
    @ViewBuilder
    private var shelfMenuItems: some View {
        ShelfActionMenuItems(controller: controller, scope: .shelf)
        Divider()
        Button("New Shelf") { manager.newShelf(at: nil) }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch model.layout {
            case .grid:
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.items) { item in
                        ShelfItemCell(item: item, controller: controller)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            case .list:
                LazyVStack(spacing: 4) {
                    ForEach(model.items) { item in
                        ShelfItemCell(item: item, controller: controller)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
        }
        .scrollIndicators(.never)
        .contextMenu { shelfMenuItems }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let activity = model.activity {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                Text(activity)
            } else if model.selection.isEmpty {
                Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")
                if model.totalSize > 0 {
                    Text("·")
                    Text(size(model.totalSize))
                }
            } else {
                Text("Selected: \(model.selection.count)")
                if model.selectedSize > 0 {
                    Text("·")
                    Text(size(model.selectedSize))
                }
            }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var layoutBinding: Binding<ShelfLayout> {
        Binding(get: { model.layout }, set: { controller.setLayout($0) })
    }

    private var keepInSpaceBinding: Binding<Bool> {
        Binding(get: { model.keepInSpace }, set: { controller.setKeepInSpace($0) })
    }
}

/// Name and colour for one shelf. Shown in place of the items rather than in a
/// popover: a popover anchored to a borderless non-activating panel is fussy
/// about focus, and the shelf already resizes itself.
struct ShelfCustomizeView: View {
    let controller: ShelfController

    private var model: ShelfModel { controller.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Shelf name")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Shelf", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Indicator colour")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(AppState.accentChoices, id: \.name) { choice in
                        Button {
                            controller.setColor(choice.name)
                        } label: {
                            Circle()
                                .fill(choice.color)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    Circle()
                                        .strokeBorder(
                                            Color.primary.opacity(model.colorName == choice.name ? 0.7 : 0),
                                            lineWidth: 2
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .help(choice.name.capitalized)
                    }
                }
            }

            Toggle(isOn: pinBinding) {
                Text("Come back at launch")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: keepInSpaceBinding) {
                Text("Keep in the current Space")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .help("When enabled, this shelf stays in the Space where it was opened")

            HStack {
                Spacer()
                Button("Done") { controller.showItems() }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { model.name ?? "" },
            set: {
                controller.setName($0.isEmpty ? nil : $0)
            }
        )
    }

    private var pinBinding: Binding<Bool> {
        Binding(get: { model.isPinned }, set: { _ in controller.togglePin() })
    }

    private var keepInSpaceBinding: Binding<Bool> {
        Binding(
            get: { model.keepInSpace },
            set: { controller.setKeepInSpace($0) }
        )
    }
}
