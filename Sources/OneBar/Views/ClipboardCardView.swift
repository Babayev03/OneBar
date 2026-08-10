import SwiftUI

struct ClipboardCardView: View {
    let item: ClipboardItem

    var body: some View {
        // Selection background/stroke is drawn by the parent so the highlight
        // can slide between cards with matchedGeometryEffect.
        VStack(alignment: .leading, spacing: 10) {
            switch item.kind {
            case .image:
                imageHeader
                detailRows
            case .text:
                Text(item.text ?? "")
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            footer
        }
        .padding(14)
    }

    private var imageHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text("Copied media")
                    .font(.system(size: 15, weight: .semibold))
                Text(item.sourceAppName ?? "Unknown source")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // Vision badges: recognized text / QR code found in the image.
                HStack(spacing: 6) {
                    if item.ocrText != nil {
                        badge("Text", systemImage: "doc.text")
                    }
                    if item.qrPayload != nil {
                        badge("QR", systemImage: "qrcode")
                    }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = ClipboardStore.shared.imageURL(for: item),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 110, maxHeight: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.1))
                .frame(width: 110, height: 76)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    private var detailRows: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Size").foregroundStyle(.secondary)
                Spacer()
                Text(item.sizeString)
            }
            if let resolution = item.resolutionString {
                HStack {
                    Text("Resolution").foregroundStyle(.secondary)
                    Spacer()
                    Text(resolution)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if let icon = item.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Text(item.sourceAppName ?? "Unknown source")
                .font(.system(size: 12, weight: .medium))

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            if item.kind == .text {
                Text("· \(item.characterCount) chars")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Text(item.timeString)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func badge(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
            Text(title)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}
