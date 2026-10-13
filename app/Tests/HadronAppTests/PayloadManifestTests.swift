import Foundation
import Testing

@testable import HadronApp

@Suite("Payload manifest")
struct PayloadManifestTests {

    @Test("The shipped manifest is the payload a launch consumes")
    func shippedManifestIsComplete() throws {
        let manifest = try PayloadManifest.bundled()

        #expect(manifest.entries.count == 16)
        #expect(manifest.paths(origin: .built).count == 6)
        #expect(manifest.paths(origin: .valve).count == 10)

        // Every payload file is fetchable from Valve or produced here, which is what dropping
        // the steam_api pair bought. A third origin would mean a file with no way to get it.
        #expect(PayloadOrigin.allCases.filter(\.isFetchable) == [.valve])
        #expect(PayloadOrigin.allCases == [.built, .valve])

        // The bridge carries lsteamclient for the arches a runtime builds, and nothing that
        // goes into the runtime itself.
        #expect(Set(manifest.paths(origin: .built)) == [
            "lsteamclient.dll", "lsteamclient.so", "steam.exe",
            "i386-windows/lsteamclient.dll", "x86_64-windows/lsteamclient.dll", "x86_64-unix/lsteamclient.so",
        ])
        #expect(!manifest.entries.contains { $0.path.hasPrefix("wine/") })
    }

    @Test("Every entry is a relative path inside the bridge")
    func pathsAreRelative() throws {
        for entry in try PayloadManifest.bundled().entries {
            #expect(!entry.path.hasPrefix("/"), "\(entry.path) is absolute")
            #expect(!entry.path.contains(".."), "\(entry.path) escapes the bridge")
            #expect(!entry.path.contains(" "), "\(entry.path) has a space, which verify.sh splits on")
        }
    }

    @Test("Comments and blank lines are ignored")
    func ignoresCommentsAndBlanks() throws {
        let manifest = try PayloadManifest.parse(
            """
            # a comment
              # an indented comment

            built    steam.exe
            valve    steamclient.dll
            """
        )

        #expect(manifest.entries == [
            PayloadEntry(origin: .built, path: "steam.exe"),
            PayloadEntry(origin: .valve, path: "steamclient.dll"),
        ])
    }

    // A skipped line drops a file out of the payload and turns a typo into a launch
    // that fails somewhere unrelated, so every one of these has to throw.
    @Test("A malformed manifest is refused rather than partly read")
    func refusesMalformed() {
        #expect(throws: StepFailure.self) { try PayloadManifest.parse("nonsense steam.exe") }
        #expect(throws: StepFailure.self) { try PayloadManifest.parse("built") }
        #expect(throws: StepFailure.self) { try PayloadManifest.parse("built steam.exe extra") }
        #expect(throws: StepFailure.self) { try PayloadManifest.parse("# only comments") }
        #expect(throws: StepFailure.self) { try PayloadManifest.parse("") }
        #expect(throws: StepFailure.self) {
            try PayloadManifest.parse("built steam.exe\nvalve steam.exe")
        }
    }
}

@Suite("Payload inspection")
struct PayloadInspectionTests {

    @Test("A bridge missing files reports them by name and origin")
    func reportsMissingByOrigin() throws {
        let bridge = FileManager.default.temporaryDirectory
            .appending(path: "np-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bridge) }

        let manifest = try PayloadManifest.bundled()
        for path in manifest.paths(origin: .valve) {
            let file = bridge.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: file)
        }

        let state = PayloadInspector.inspect(bridge: bridge)
        #expect(state.manifestProblem == nil)
        #expect(state.expected == 16)
        #expect(state.present == 10)
        #expect(state.missing(origin: .valve).isEmpty)
        #expect(state.missing(origin: .built).count == 6)
        #expect(!state.isComplete)
    }
}
