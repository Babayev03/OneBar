import AppKit
import SwiftUI

/// Rules and options for one watched folder.
///
/// A sheet for the same reason the custom-action editor is one: a rule is a row
/// of four controls, and several of them will not fit beside a folder path in a
/// list without every one of them being too narrow to read.
struct FolderWatchEditor: View {
    let onSave: (ShelfFolderWatch) -> Void
    let onCancel: () -> Void

    @State private var draft: ShelfFolderWatch

    init(
        watch: ShelfFolderWatch,
        onSave: @escaping (ShelfFolderWatch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: watch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !draft.isScreenshotWatch {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(URL(filePath: draft.path).lastPathComponent, text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                    Text("Names the shelf this folder fills. Left empty, the folder's own name is used.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include subfolders", isOn: $draft.includesSubfolders)
                    .toggleStyle(.checkbox)
                Toggle("A new shelf for every file", isOn: $draft.newShelfPerFile)
                    .toggleStyle(.checkbox)
                Text(draft.newShelfPerFile
                    ? "Each arrival opens its own shelf. A folder that receives several files at once will reach the shelf limit quickly."
                    : "Everything this folder receives joins the same shelf.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            rulesSection

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: draft.isScreenshotWatch ? "camera.viewfinder" : "folder")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(abbreviated(draft.path))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            if !draft.isScreenshotWatch {
                Button("Show in Finder") {
                    guard let url = draft.resolveURL() else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Take a file when")
                    .font(.system(size: 12))
                Picker("", selection: $draft.rules.match) {
                    ForEach(ShelfWatchRules.Match.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 74)
                Text("of these are true")
                    .font(.system(size: 12))
                Spacer()
                Button {
                    draft.rules.rules.append(ShelfWatchRule())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a condition")
            }

            if draft.rules.rules.isEmpty {
                Text("No conditions — everything that arrives in this folder goes to the shelf.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach($draft.rules.rules) { $rule in
                    ruleRow($rule)
                }
            }
        }
    }

    private func ruleRow(_ rule: Binding<ShelfWatchRule>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { rule.wrappedValue.field },
                set: { field in
                    rule.wrappedValue.field = field
                    // The comparison has to stay answerable for the new field.
                    rule.wrappedValue.normalise()
                }
            )) {
                ForEach(ShelfWatchField.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 100)

            Picker("", selection: rule.comparison) {
                ForEach(rule.wrappedValue.field.operators) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)

            switch rule.wrappedValue.field {
            case .name, .fileExtension:
                TextField("", text: rule.text)
                    .textFieldStyle(.roundedBorder)
                Toggle(isOn: rule.isCaseSensitive) {
                    Text("Aa").font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match upper and lower case exactly")
            case .size:
                TextField("", value: rule.sizeValue, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Picker("", selection: rule.sizeUnit) {
                    ForEach(ShelfWatchSizeUnit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 70)
                Spacer(minLength: 0)
            case .kind:
                Picker("", selection: rule.kind) {
                    ForEach(WatchedFileKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer(minLength: 0)
            }

            Button {
                draft.rules.rules.removeAll { $0.id == rule.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
