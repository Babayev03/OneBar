import AppKit
import SwiftUI

struct ShelfItemCell: View {
    let item: ShelfItem
    let controller: ShelfController

    @State private var thumbnail: NSImage?

    private var model: ShelfModel { controller.model }
    private var isSelected: Bool { model.selection.contains(item.id) }
    private var isRenaming: Bool { model.renamingItemID == item.id }

    var body: some View {
        Group {
            switch model.layout {
            case .grid: gridCell
            case .list: listRow
            }
        }
        .background {
            RoundedRectangle(cornerRadius: model.layout == .grid ? 10 : 7, style: .continuous)
                .fill(isSelected ? model.color.opacity(0.22) : Color.clear)
        }
        .help(helpText)
        // The drag source sits over the cell and owns its clicks — see
        // ShelfDragSource for why this is AppKit and not `.draggable`. It is
        // left off while the name is being edited, or it would swallow every
        // click meant for the field.
        .overlay {
            if !isRenaming {
                ShelfDragSource(
                    itemID: item.id,
                    controller: controller,
                    onSelect: select,
                    onClickRelease: finishSelection,
                    onDoubleClick: open
                )
            }
        }
        // Above the drag source, so it stays clickable.
        .overlay(alignment: model.layout == .grid ? .topTrailing : .trailing) {
            if isSelected, !isRenaming {
                Button {
                    controller.remove([item.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(model.layout == .grid ? 2 : 6)
            }
        }
        .task(id: item.id) {
            thumbnail = await ShelfThumbnails.shared.thumbnail(
                for: item,
                size: CGSize(width: 40, height: 40)
            )
        }
    }

    private var gridCell: some View {
        VStack(spacing: 4) {
            icon
                .frame(width: 40, height: 40)
            if isRenaming {
                renameField(centred: true)
                    .frame(height: 20)
            } else {
                Text(item.title)
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isPresentOnDisk ? .primary : .secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: ShelfController.cellHeight)
    }

    private var listRow: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    renameField(centred: false)
                        .frame(height: 20)
                } else {
                    Text(item.title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(isPresentOnDisk ? .primary : .secondary)
                }
                if let subtitle = item.subtitle, !isRenaming {
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: isSelected ? 22 : 0)
        }
        .padding(.horizontal, 7)
        .frame(height: ShelfController.rowHeight)
    }

    private func renameField(centred: Bool) -> some View {
        ShelfRenameField(
            name: item.title,
            centred: centred,
            onCommit: { controller.commitRename(item.id, to: $0) },
            onCancel: { controller.cancelRename() }
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: model.layout == .grid ? 24 : 14, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    /// A link has no file and is never missing; anything else greys out once
    /// whatever it points at has been moved or deleted behind our back.
    private var isPresentOnDisk: Bool {
        item.kind == .link || item.isOnDisk
    }

    private var symbolName: String {
        switch item.kind {
        case .file: return "doc"
        case .image: return "photo"
        case .text: return "doc.text"
        case .link: return "globe"
        }
    }

    private var helpText: String {
        if let subtitle = item.subtitle { return "\(item.title)\n\(subtitle)" }
        return item.title
    }

    private func select(_ event: NSEvent) {
        ShelfSelectionLogic.mouseDown(
            on: item.id,
            orderedIDs: model.items.map(\.id),
            modifiers: event.modifierFlags,
            selection: &model.selection,
            anchor: &model.selectionAnchor
        )
    }

    private func finishSelection(_ event: NSEvent) {
        ShelfSelectionLogic.mouseUpWithoutDrag(
            on: item.id,
            modifiers: event.modifierFlags,
            selection: &model.selection,
            anchor: &model.selectionAnchor
        )
    }

    private func open() {
        guard let url = item.activationURL else { return }
        NSWorkspace.shared.open(url)
    }
}
