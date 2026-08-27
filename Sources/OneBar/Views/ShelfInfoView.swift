import AppKit
import ImageIO
import SwiftUI

/// What Get Info shows: the facts about the selected items that the shelf cell
/// has no room for.
struct ShelfInfoView: View {
    let items: [ShelfItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.label) { row in
                HStack(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 78, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Spacer()
                Button("Done") { ShelfDialog.shared.dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private struct Row {
        let label: String
        let value: String
    }

    private var rows: [Row] {
        items.count == 1 ? single(items[0]) : many
    }

    private var many: [Row] {
        let total = items.compactMap(\.byteSize).reduce(0, +)
        var rows = [
            Row(label: "Items", value: "\(items.count)"),
            Row(label: "Total size", value: ByteCountFormatter.string(
                fromByteCount: Int64(total), countStyle: .file
            )),
        ]
        let missing = items.filter { $0.kind != .link && !$0.isOnDisk }.count
        if missing > 0 {
            rows.append(Row(label: "Missing", value: "\(missing) no longer on disk"))
        }
        return rows
    }

    private func single(_ item: ShelfItem) -> [Row] {
        var rows = [Row(label: "Name", value: item.title)]

        if let url = item.resolveURL() {
            let values = try? url.resourceValues(forKeys: [
                .contentTypeKey, .creationDateKey, .contentModificationDateKey, .isDirectoryKey,
            ])
            rows.append(Row(
                label: "Kind",
                value: values?.contentType?.localizedDescription
                    ?? (values?.isDirectory == true ? "Folder" : "Document")
            ))
            if let size = item.byteSize ?? ShelfStore.shared.fileSize(of: url) {
                rows.append(Row(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                ))
            }
            if let dimensions = Self.pixelDimensions(of: url) {
                rows.append(Row(label: "Dimensions", value: dimensions))
            }
            rows.append(Row(label: "Where", value: url.deletingLastPathComponent().path))
            if let created = values?.creationDate {
                rows.append(Row(label: "Created", value: Self.formatter.string(from: created)))
            }
            if let modified = values?.contentModificationDate {
                rows.append(Row(label: "Modified", value: Self.formatter.string(from: modified)))
            }
        } else if let link = item.linkString {
            rows.append(Row(label: "Kind", value: "Link"))
            rows.append(Row(label: "URL", value: link))
        } else if item.kind == .text, let text = item.text {
            rows.append(Row(label: "Kind", value: "Text"))
            rows.append(Row(
                label: "Length",
                value: text.count == 1 ? "1 character" : "\(text.count) characters"
            ))
        } else {
            // The item outlived whatever it pointed at.
            rows.append(Row(label: "Kind", value: "Missing"))
            if let path = item.path {
                rows.append(Row(label: "Was at", value: path))
            }
        }

        rows.append(Row(label: "Added", value: Self.formatter.string(from: item.addedAt)))
        return rows
    }

    /// Read from the file's own header rather than by decoding it, so a large
    /// photo costs nothing to describe.
    private static func pixelDimensions(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(width) × \(height)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
