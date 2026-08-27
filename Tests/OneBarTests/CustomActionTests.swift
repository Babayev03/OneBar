import Foundation
import Testing
@testable import OneBar

@Suite("Custom shelf actions")
struct CustomActionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-action-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScript(
        in directory: URL,
        named name: String,
        body: String,
        executable: Bool = true
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        }
        return url
    }

    private func action(at url: URL, name: String = "Test") -> CustomShelfAction {
        CustomShelfAction(name: name, symbol: "gearshape", path: url.path)
    }

    // MARK: - How a file is run

    @Test("An Automator workflow is run by Automator, everything else by the shell")
    func runnerChoice() {
        #expect(CustomShelfAction.runner(forPath: "/x/Rename.workflow") == .automator)
        #expect(CustomShelfAction.runner(forPath: "/x/RENAME.WORKFLOW") == .automator)
        #expect(CustomShelfAction.runner(forPath: "/x/shrink.sh") == .shell)
        #expect(CustomShelfAction.runner(forPath: "/x/shrink") == .shell)
        // Chosen from the file, never stored, so a rename changes it.
        var subject = CustomShelfAction(name: "x", symbol: "gearshape", path: "/x/a.sh")
        #expect(subject.runner == .shell)
        subject.path = "/x/a.workflow"
        #expect(subject.runner == .automator)
    }

    @Test("A nameless action falls back to the file's own name")
    func naming() {
        #expect(CustomShelfAction.sanitised(name: "", path: "/x/shrink.sh") == "shrink")
        #expect(CustomShelfAction.sanitised(name: "   ", path: "/x/My Thing.workflow") == "My Thing")
        #expect(CustomShelfAction.sanitised(name: "  Trimmed  ", path: "/x/a.sh") == "Trimmed")
        #expect(CustomShelfAction.sanitised(name: String(repeating: "a", count: 80), path: "/x/a.sh").count == 40)
    }

    @Test("A registered action survives a round trip through its manifest")
    func encoding() throws {
        let original = CustomShelfAction(
            name: "Shrink", symbol: "photo", path: "/x/shrink.sh", bookmark: Data([1, 2, 3])
        )
        let decoded = try JSONDecoder().decode(
            CustomShelfAction.self, from: JSONEncoder().encode(original)
        )
        #expect(decoded == original)
        #expect(decoded.id == original.id)
    }

    @Test("A button id can be derived from the action it belongs to")
    func buttonIdentity() async {
        let id = UUID()
        #expect(await ShelfInstantAction.customID(id) == "custom.\(id.uuidString)")
    }

    @Test("A script only applies where there are real files")
    func availability() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)

        let subject = action(at: file)
        #expect(subject.isAvailable(for: ShelfActionSubject(items: [
            ShelfItem(kind: .file, path: file.path, title: "notes.txt")
        ])))
        // A link has no path to hand a script.
        #expect(!subject.isAvailable(for: ShelfActionSubject(items: [
            ShelfItem(kind: .link, linkString: "https://example.com", title: "Example")
        ])))
        #expect(!subject.isAvailable(for: ShelfActionSubject()))
    }

    @Test("A registered script shows up in the command bar, and only with files")
    func appearsInCommandBar() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        let custom = action(at: file, name: "Shrink for web")

        let withFiles = ShelfActionSubject(items: [
            ShelfItem(kind: .file, path: file.path, title: "notes.txt")
        ], shelfItemCount: 1)
        let commands = ShelfCommandSearch.commands(for: withFiles, custom: [custom])
        #expect(commands.contains { $0.kind == .custom(custom.id) })
        // Custom actions come last, after the built-in list people know.
        #expect(commands.last?.kind == .custom(custom.id))
        #expect(ShelfCommandSearch.rank(commands, query: "shrink").first?.kind
            == .custom(custom.id))

        let empty = ShelfActionSubject(items: [], shelfItemCount: 0)
        #expect(!ShelfCommandSearch.commands(for: empty, custom: [custom])
            .contains { $0.kind == .custom(custom.id) })
    }

    // MARK: - Running one

    @Test("Files the script writes to its output directory come back")
    func producesOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        let script = try makeScript(in: directory, named: "copy.sh", body: """
        #!/bin/sh
        for f in "$@"; do
          cp "$f" "$ONEBAR_OUTPUT_DIR/$(basename "$f")"
        done
        """)

        let produced = try await ShelfTransforms.runCustom(
            action(at: script), script: script, urls: [input], store: store
        )
        #expect(produced.count == 1)
        #expect(produced.first?.lastPathComponent == "input.txt")
        #expect(FileManager.default.fileExists(atPath: produced[0].path))
        // Landed in the ordinary output folder, like every other action's result.
        #expect(produced[0].deletingLastPathComponent().lastPathComponent == "action-output")
    }

    @Test("The files arrive as arguments, and the count is passed alongside")
    func receivesArguments() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let first = directory.appendingPathComponent("one.txt")
        let second = directory.appendingPathComponent("two.txt")
        try Data("1".utf8).write(to: first)
        try Data("2".utf8).write(to: second)

        let script = try makeScript(in: directory, named: "report.sh", body: """
        #!/bin/sh
        {
          echo "count=$#"
          echo "env=$ONEBAR_FILE_COUNT"
          for f in "$@"; do basename "$f"; done
        } > "$ONEBAR_OUTPUT_DIR/report.txt"
        """)

        let produced = try await ShelfTransforms.runCustom(
            action(at: script), script: script, urls: [first, second], store: store
        )
        let report = try String(contentsOf: try #require(produced.first), encoding: .utf8)
        #expect(report.contains("count=2"))
        #expect(report.contains("env=2"))
        #expect(report.contains("one.txt"))
        #expect(report.contains("two.txt"))
    }

    @Test("A script without its executable bit still runs")
    func nonExecutableScript() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        // Forgetting chmod +x is the commonest way this fails, so one is handed
        // to /bin/sh rather than refused.
        let script = try makeScript(in: directory, named: "plain.sh", body: """
        #!/bin/sh
        echo done > "$ONEBAR_OUTPUT_DIR/out.txt"
        """, executable: false)

        let produced = try await ShelfTransforms.runCustom(
            action(at: script), script: script, urls: [input], store: store
        )
        #expect(produced.count == 1)
    }

    @Test("A failing script reports its own last words")
    func failureMessage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        let script = try makeScript(in: directory, named: "fail.sh", body: """
        #!/bin/sh
        echo "something went wrong" >&2
        exit 3
        """)

        await #expect(throws: ShelfTransformError.self) {
            _ = try await ShelfTransforms.runCustom(
                action(at: script, name: "Broken"),
                script: script,
                urls: [input],
                store: store
            )
        }

        do {
            _ = try await ShelfTransforms.runCustom(
                action(at: script, name: "Broken"), script: script, urls: [input], store: store
            )
            Issue.record("should have thrown")
        } catch {
            let description = (error as? ShelfTransformError)?.errorDescription ?? ""
            #expect(description.contains("Broken"))
            #expect(description.contains("something went wrong"))
        }
    }

    @Test("A silent failure still says what the exit code was")
    func silentFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        let script = try makeScript(in: directory, named: "silent.sh", body: """
        #!/bin/sh
        exit 7
        """)

        do {
            _ = try await ShelfTransforms.runCustom(
                action(at: script, name: "salam"), script: script, urls: [input], store: store
            )
            Issue.record("should have thrown")
        } catch {
            // "salam failed" alone does not separate a script that ran and
            // returned an error from one that never started.
            let description = (error as? ShelfTransformError)?.errorDescription ?? ""
            #expect(description == "salam failed (exit 7)")
        }
    }

    @Test("A script that writes nothing succeeds with nothing")
    func silentSuccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        let script = try makeScript(in: directory, named: "quiet.sh", body: """
        #!/bin/sh
        exit 0
        """)

        let produced = try await ShelfTransforms.runCustom(
            action(at: script), script: script, urls: [input], store: store
        )
        #expect(produced.isEmpty)
    }

    @Test("The log the runner keeps is never handed back as an output")
    func logIsNotAnOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShelfStore(baseDirectory: directory)
        let input = directory.appendingPathComponent("input.txt")
        try Data("hello".utf8).write(to: input)

        let script = try makeScript(in: directory, named: "chatty.sh", body: """
        #!/bin/sh
        echo "lots of output"
        echo "and more" >&2
        echo real > "$ONEBAR_OUTPUT_DIR/real.txt"
        """)

        let produced = try await ShelfTransforms.runCustom(
            action(at: script), script: script, urls: [input], store: store
        )
        #expect(produced.map(\.lastPathComponent) == ["real.txt"])
    }
}
