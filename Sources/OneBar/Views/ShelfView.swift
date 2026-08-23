import AppKit
import SwiftUI

struct ShelfView: View {
    let controller: ShelfController

    private var model: ShelfModel { controller.model }
    private var accent: Color { AppState.shared.accentColor }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                grid
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    model.isDropTargeted ? accent : Color.primary.opacity(0.1),
                    lineWidth: model.isDropTargeted ? 2 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(model.isPresented ? 1 : 0)
        .scaleEffect(model.isPresented ? 1 : 0.94)
        .animation(.easeOut(duration: 0.12), value: model.isDropTargeted)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !model.items.isEmpty {
                headerButton("trash", help: "Clear the shelf") {
                    controller.clear()
                }
            }
            headerButton("xmark", help: "Close the shelf") {
                controller.close()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.items) { item in
                    ShelfItemCell(item: item, controller: controller)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")
            if model.totalSize > 0 {
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: Int64(model.totalSize), countStyle: .file))
            }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
    }
}

