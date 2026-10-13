import Foundation
import Testing

@testable import NotProtonApp

// Scratch directories rather than the live runner, so these say the same thing on a
// machine that has never had a clone made on it.

@Suite("Cloned payload resolution")
struct ClonedPayloadTests {

    @Test("An intact copy is recognised by the lib/wine inside runners/<id>")
    func findsPayload() throws {
        let runners = try scratchDirectory("setup")
        defer { try? FileManager.default.removeItem(at: runners) }

        let payload = SupportPaths.runnerRoot(forBuild: "1.2.3.4", runners: runners)
        try FileManager.default.createDirectory(
            at: payload.appending(path: "lib/wine"), withIntermediateDirectories: true
        )

        #expect(RunnerInstaller.hasClone(forBuild: "1.2.3.4", runners: runners))
    }

    @Test("A copy that kept the runtime folder nested inside does not count as cloned")
    func refusesNestedClone() throws {
        let runners = try scratchDirectory("setup")
        defer { try? FileManager.default.removeItem(at: runners) }

        let clone = SupportPaths.runnerRoot(forBuild: "1.2.3.4", runners: runners)
        try FileManager.default.createDirectory(
            at: clone.appending(path: "wine-runtime/lib/wine"),
            withIntermediateDirectories: true
        )

        #expect(!RunnerInstaller.hasClone(forBuild: "1.2.3.4", runners: runners))
    }

    @Test("A clone with no payload in it does not count as cloned")
    func refusesCloneWithoutPayload() throws {
        let runners = try scratchDirectory("setup")
        defer { try? FileManager.default.removeItem(at: runners) }

        let clone = SupportPaths.runnerRoot(forBuild: "1.2.3.4", runners: runners)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)

        #expect(!RunnerInstaller.hasClone(forBuild: "1.2.3.4", runners: runners))
    }
}
