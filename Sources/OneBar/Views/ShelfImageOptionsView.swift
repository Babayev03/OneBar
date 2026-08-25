import SwiftUI

/// Format, size and quality for the image actions, shown in place of the items
/// for the same reason `ShelfCustomizeView` is: a popover hung off a borderless
/// non-activating panel is fussy about focus, and the shelf already resizes.
struct ShelfImageOptionsView: View {
    let controller: ShelfController

    private var model: ShelfModel { controller.model }
    private var request: ImageActionRequest { model.imageRequest ?? ImageActionRequest(urls: []) }

    @State private var customEdge = "1024"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(countLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Text("Format")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: formatBinding) {
                    Text("Keep Original").tag(ImageFormat?.none)
                    ForEach(ImageFormat.allCases) { Text($0.title).tag(ImageFormat?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            HStack {
                Text("Size")
                    .font(.system(size: 12))
                Spacer()
                Picker("", selection: sizeBinding) {
                    Text("Original").tag(SizeChoice.original)
                    Text("25%").tag(SizeChoice.percent(25))
                    Text("50%").tag(SizeChoice.percent(50))
                    Text("Longest edge").tag(SizeChoice.longestEdge)
                }
                .labelsHidden()
                .frame(width: 110)
            }

            if sizeBinding.wrappedValue == .longestEdge {
                HStack {
                    Text("Pixels")
                        .font(.system(size: 12))
                    Spacer()
                    TextField("1024", text: $customEdge)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 110)
                }
            }

            if request.showsQuality {
                HStack(spacing: 8) {
                    Text("Quality")
                        .font(.system(size: 12))
                    Slider(value: qualityBinding, in: 0.1...1)
                    Text("\(Int((request.quality * 100).rounded()))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel") { controller.showItems() }
                    .controlSize(.small)
                Button("Convert") { convert() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var countLabel: String {
        let count = request.urls.count
        return count == 1 ? "1 image" : "\(count) images"
    }

    private func convert() {
        var outgoing = request
        if sizeBinding.wrappedValue == .longestEdge {
            // A field that will not parse means the number was not usable, and
            // silently converting at full size would look like nothing happened.
            guard let pixels = Int(customEdge.trimmingCharacters(in: .whitespaces)), pixels > 0 else {
                HUD.show("Enter a size in pixels", symbol: "exclamationmark.circle")
                return
            }
            outgoing.resize = .longestEdge(pixels)
        }
        controller.showItems()
        ShelfActionRunner.convertImages(outgoing, in: controller)
    }

    // MARK: - Bindings

    private enum SizeChoice: Hashable {
        case original
        case percent(Int)
        case longestEdge
    }

    private var formatBinding: Binding<ImageFormat?> {
        Binding(
            get: { request.format },
            set: { model.imageRequest?.format = $0 }
        )
    }

    private var qualityBinding: Binding<Double> {
        Binding(
            get: { request.quality },
            set: { model.imageRequest?.quality = $0 }
        )
    }

    private var sizeBinding: Binding<SizeChoice> {
        Binding(
            get: {
                switch request.resize {
                case .original: return .original
                case .percent(let value): return .percent(value)
                case .longestEdge: return .longestEdge
                }
            },
            set: { choice in
                switch choice {
                case .original: model.imageRequest?.resize = .original
                case .percent(let value): model.imageRequest?.resize = .percent(value)
                case .longestEdge:
                    if case .longestEdge(let pixels) = request.resize {
                        customEdge = String(pixels)
                    }
                    model.imageRequest?.resize = .longestEdge(Int(customEdge) ?? 1024)
                }
            }
        )
    }
}
