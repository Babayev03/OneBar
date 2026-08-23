import AppKit
import SwiftUI

struct ShelfItemCell: View {
    let item: ShelfItem
    let controller: ShelfController

    @State private var thumbnail: NSImage?

    private var model: ShelfModel { controller.model }
    private var isSelected: Bool { model.selection.contains(item.id) }

    var body: some View {
        VStack(spacing: 4) {
            icon
                .frame(width: 40, height: 40)
            Text(item.title)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(item.kind == .link || item.isOnDisk ? .primary : .secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AppState.shared.accentColor.opacity(0.22) : Color.clear)
        }
        .help(helpText)
        // The drag source sits over the cell and owns its clicks — see
        // ShelfDragSource for why this is AppKit and not `.draggable`.
        .overlay {
            ShelfDragSource(
                itemID: item.id,
                controller: controller,
                onSelect: select,
                onDoubleClick: open
            )
        }
        // Above the drag source, so it stays clickable.
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    controller.remove([item.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(2)
            }
        }
        .task(id: item.id) {
            thumbnail = await ShelfThumbnails.shared.thumbnail(
                for: item,
                size: CGSize(width: 40, height: 40)
            )
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
        }
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
        if event.modifierFlags.contains(.command) {
            if isSelected {
                model.selection.remove(item.id)
            } else {
                model.selection.insert(item.id)
            }
        } else {
            model.selection = [item.id]
        }
    }

    private func open() {
        if let url = item.resolveURL() {
            NSWorkspace.shared.open(url)
        } else if let url = item.linkURL {
            NSWorkspace.shared.open(url)
        }
    }
}

