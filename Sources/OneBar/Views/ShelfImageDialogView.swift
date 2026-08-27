import AppKit
import SwiftUI

/// Format, size, quality and where the result goes.
struct ShelfImageDialogView: View {
    let controller: ShelfController
    let action: ShelfAction
    @State var request: ImageActionRequest
    @State private var customEdge = "1024"
    @State private var sizeChoice: SizeChoice

    init(controller: ShelfController, action: ShelfAction, request: ImageActionRequest) {
        self.controller = controller
        self.action = action
        _request = State(initialValue: request)
        switch request.resize {
        case .original: _sizeChoice = State(initialValue: .original)
        case .percent(let value): _sizeChoice = State(initialValue: .percent(value))
        case .longestEdge(let pixels):
            _sizeChoice = State(initialValue: .longestEdge)
            _customEdge = State(initialValue: String(pixels))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Target format") {
                Picker("", selection: $request.format) {
                    Text("Keep Original").tag(ImageFormat?.none)
                    ForEach(ImageFormat.available) { Text($0.title).tag(ImageFormat?.some($0)) }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            row("Size") {
                Picker("", selection: $sizeChoice) {
                    Text("Original").tag(SizeChoice.original)
                    Text("25%").tag(SizeChoice.percent(25))
                    Text("50%").tag(SizeChoice.percent(50))
                    Text("Longest edge").tag(SizeChoice.longestEdge)
                }
                .labelsHidden()
                .frame(width: 130)
            }

            if sizeChoice == .longestEdge {
                row("Pixels") {
                    TextField("1024", text: $customEdge)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 130)
                }
            }

            if request.showsQuality {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Image quality")
                            .font(.system(size: 12))
                        Slider(value: $request.quality, in: 0.1...1)
                        Text("\(Int((request.quality * 100).rounded()))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    Text(qualityHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            row("Show output in") {
                Picker("", selection: revealBinding) {
                    ForEach(ShelfOutputReveal.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            if request.reveal.usesChosenFolder {
                row("Save in") {
                    HStack(spacing: 6) {
                        Text(folderLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseFolder() }
                            .controlSize(.small)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { ShelfDialog.shared.dismiss() }
                    .controlSize(.small)
                Button("Continue") { run() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
    }

    private func row(_ label: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer(minLength: 8)
            trailing()
        }
    }

    private var qualityHint: String {
        switch request.quality {
        case ..<0.4: return "Small file, visible compression."
        case ..<0.75: return "Balanced size and detail."
        case ..<0.95: return "Good detail, moderate compression."
        default: return "High quality, minimal compression."
        }
    }

    private var folderLabel: String {
        guard let folder = request.folder else { return "OneBar's output folder" }
        return folder.lastPathComponent
    }

    private var revealBinding: Binding<ShelfOutputReveal> {
        Binding(
            get: { request.reveal },
            set: { reveal in
                request.reveal = reveal
                // Nothing to find means nowhere to put it.
                if !reveal.usesChosenFolder { request.folder = nil }
            }
        )
    }

    private func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose"
        picker.message = "Where should the converted files be saved?"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        request.folder = url
        AppState.shared.shelfOutputFolder = url.path
    }

    private func run() {
        var outgoing = request
        if sizeChoice == .longestEdge {
            // A field that will not parse means the number was not usable, and
            // converting at full size instead would look like nothing happened.
            guard let pixels = Int(customEdge.trimmingCharacters(in: .whitespaces)), pixels > 0 else {
                HUD.show("Enter a size in pixels", symbol: "exclamationmark.circle")
                return
            }
            outgoing.resize = .longestEdge(pixels)
        } else if case .percent(let value) = sizeChoice {
            outgoing.resize = .percent(value)
        } else {
            outgoing.resize = .original
        }
        AppState.shared.shelfOutputReveal = outgoing.reveal
        ShelfDialog.shared.dismiss()
        ShelfActionRunner.convertImages(outgoing, in: controller)
    }

    enum SizeChoice: Hashable {
        case original
        case percent(Int)
        case longestEdge
    }
}
