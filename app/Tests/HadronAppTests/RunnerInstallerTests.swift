import Foundation
import Testing

@testable import HadronApp

@Suite("Copying a runner")
struct RunnerInstallerTests {

    private func makeRunners() throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-point-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        return runners
    }

    // A runtime folder beside runners/, found the way discovery finds it.
    private func makeSupportedInstall(in directory: URL, id: String = shippedRuntimeID) throws -> RuntimeInstall {
        let root = try makeRuntime(at: directory.appending(path: "source/wine-runtime"), id: id)
        return RuntimeSource.inspect(root: root)
    }

    // The copy is found afterwards at runners/<id>, so the folder itself has to land there,
    // not inside it. cp keys that off the destination existing, and first time it does not.
    @Test("The copy lands as the build directory itself")
    func copyLandsAsBuildDirectory() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let source = try makeRuntime(at: runners.appending(path: "source/wine-runtime"))

        let target = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        try RunnerInstaller.copyPayload(from: source, to: target)

        #expect(FileManager.default.fileExists(
            atPath: target.appending(path: "lib/wine").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: target.appending(path: "wine-runtime").path(percentEncoded: false)
        ))

        // The check the setup path runs next has to agree, because that is where a wrongly
        // shaped copy was being reported.
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
    }

    @Test("A build directory left without lib/wine is copied again rather than trusted")
    func partialCloneIsReplaced() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let install = try makeSupportedInstall(in: runners.appending(path: "src"))

        let stale = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: stale.appending(path: "leftover"))
        #expect(!RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))

        #expect(try RunnerInstaller.clone(from: install, runners: runners))

        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
        // The leftover contents must be gone, not left beside the copy.
        #expect(!FileManager.default.fileExists(
            atPath: stale.appending(path: "leftover").path(percentEncoded: false)
        ))
    }

    @Test("Copying a runtime leaves other builds' directories in place")
    func cloneKeepsOtherBuilds() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        try makeInstalledRuntime(in: runners, id: "wine-0.1")
        let install = try makeSupportedInstall(in: runners.appending(path: "src"))

        try RunnerInstaller.clone(from: install, runners: runners)

        #expect(RunnerInstaller.hasClone(forBuild: "wine-0.1", runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
    }

    // Keeping lib/wine is not the same as keeping the loader inside it, and the loader is what
    // a game needs. Setup skips the copy for such a clone, so nothing else catches the loss.
    @Test("A copy that kept lib/wine but lost its loader is refused")
    func refusesCloneThatLostItsLoader() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let install = try makeSupportedInstall(in: runners)
        try RunnerInstaller.clone(from: install, runners: runners)

        let root = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        try FileManager.default.removeItem(at: RuntimeSource.unixLoader(inRoot: root))

        // Still counts as copied, so the copy is skipped and the loader check is reached.
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))

        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, runners: runners)
        }
        #expect(
            failure.detail.contains("no Wine loader"),
            "a copy with no loader in it was reported as something else"
        )
    }

    // Replacing an intact copy used to remove it before the copy, so a failed copy took a
    // working tree with it, with nothing in the UI.
    @Test("A failed recopy leaves the working copy intact")
    func keepsWorkingCloneWhenRecopyFails() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let install = try makeSupportedInstall(in: runners)
        try RunnerInstaller.clone(from: install, runners: runners)

        let payload = SupportPaths
            .runnerRoot(forBuild: shippedRuntimeID, runners: runners)
            .appending(path: "lib/wine")
        let files = FileManager.default

        // Asserted before the failure, or the checks afterwards pass on a copy that was
        // never there to begin with.
        #expect(files.fileExists(atPath: payload.path(percentEncoded: false)))

        // Removing the source fails the copy the same way running out of room part way
        // through does, which is the case that costs the user a working runner.
        try files.removeItem(at: runners.appending(path: "source"))

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners)
        }

        #expect(
            files.fileExists(atPath: payload.path(percentEncoded: false)),
            "a recopy that failed destroyed the working copy"
        )
    }

    @Test("The state reader agrees with what was just written")
    func stateAgreesWithInstaller() throws {
        let runners = try makeRunners()
        defer { try? FileManager.default.removeItem(at: runners) }

        let install = try makeSupportedInstall(in: runners.appending(path: "src"))
        try RunnerInstaller.clone(from: install, runners: runners)

        #expect(RunnerStore.state(runners: runners) == .ready(builds: [shippedRuntimeID]))
    }
}
