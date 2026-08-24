import AppKit
import SwiftUI

/// The action list as SwiftUI menu content, for the overflow button and the
/// empty-space menu. The menu raised on an item itself is built in AppKit
/// instead — see `ShelfActionMenu` for why.
struct ShelfActionMenuItems: View {
    let controller: ShelfController
    let scope: ShelfActionScope

    var body: some View {
        let subject = ShelfActionRunner.subject(for: scope, in: controller)
        ForEach(Array(ShelfAction.groups.enumerated()), id: \.offset) { _, group in
            let available = group.filter { $0.isAvailable(for: subject) }
            if !available.isEmpty {
                Section {
                    ForEach(available) { action in
                        row(action, subject: subject)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ action: ShelfAction, subject: ShelfActionSubject) -> some View {
        if action == .openWith {
            Menu {
                let applications = ShelfActionRunner.applications(openingAllOf: subject.fileURLs)
                if applications.isEmpty {
                    Button(subject.fileURLs.count > 1
                        ? "No app opens all of these"
                        : "No app opens this") {}
                        .disabled(true)
                } else {
                    ForEach(applications, id: \.self) { application in
                        Button(FileManager.default.displayName(atPath: application.path)) {
                            ShelfActionRunner.openWith(
                                application: application,
                                scope: scope,
                                in: controller
                            )
                        }
                    }
                }
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
        } else {
            Button {
                ShelfActionRunner.perform(action, scope: scope, in: controller)
            } label: {
                Label(action.title, systemImage: action.symbol)
            }
        }
    }
}
