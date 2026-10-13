import Foundation
import Testing

@testable import HadronApp

@Suite("Runner state detection")
struct RunnerStateTests {

    struct Fixture: ~Copyable {
        let runners: URL

        init() throws {
            runners = FileManager.default.temporaryDirectory
                .appending(path: "np-runners-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        }

        func makeClone(build: String, withWine: Bool = true) throws {
            if withWine {
                try makeInstalledRuntime(in: runners, id: build)
            } else {
                try FileManager.default.createDirectory(
                    at: SupportPaths.runnerRoot(forBuild: build, runners: runners),
                    withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: runners) }
    }

    @Test("No copy means nothing is set up")
    func reportsNone() throws {
        let fixture = try Fixture()
        #expect(RunnerStore.state(runners: fixture.runners) == .none)
    }

    @Test("A complete copy is reported ready")
    func reportsReadyClones() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: shippedRuntimeID)

        #expect(RunnerStore.state(runners: fixture.runners) == .ready(builds: [shippedRuntimeID]))
    }

    // The launch path only reads the runner, so a copy missing lsteamclient has to be caught
    // here rather than by a game failing its ownership check.
    @Test("A copy missing a built-in is reported as incomplete")
    func reportsIncompleteClone() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: shippedRuntimeID)
        try FileManager.default.removeItem(
            at: SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: fixture.runners)
                .appending(path: "lib/wine/x86_64-unix/lsteamclient.so"))

        #expect(RunnerStore.state(runners: fixture.runners) == .incomplete(
            builds: [shippedRuntimeID],
            problems: ["\(shippedRuntimeID): x86_64-unix/lsteamclient.so is missing"]
        ))
    }

    @Test("Every problem a check finds is reported, prefixed with its build")
    func reportsEveryProblem() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: shippedRuntimeID)

        #expect(RunnerStore.state(runners: fixture.runners, verify: { _, _ in ["one", "two"] })
            == .incomplete(builds: [shippedRuntimeID],
                           problems: ["\(shippedRuntimeID): one", "\(shippedRuntimeID): two"]))
        #expect(RunnerState.incomplete(builds: [shippedRuntimeID], problems: []).builds == [shippedRuntimeID])
    }

    @Test("A copy outside the allow list is orphaned, not ready")
    func reportsUnsupportedClone() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: "wine-0.1")

        #expect(RunnerStore.state(runners: fixture.runners) == .none)
        #expect(RunnerStore.orphanedClones(in: fixture.runners) == ["wine-0.1"])
        #expect(RunnerStore.installedBuilds(in: fixture.runners).isEmpty)
    }

    @Test("A supported copy with no lib/wine is damaged, not ready")
    func detectsIncompleteTree() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: shippedRuntimeID, withWine: false)

        #expect(RunnerStore.state(runners: fixture.runners) == .none)
        #expect(RunnerStore.damagedClones(in: fixture.runners) == [shippedRuntimeID])
    }

    @Test("Copies are listed by build, without staging or removal leftovers or loose files")
    func listsClones() throws {
        let fixture = try Fixture()
        try fixture.makeClone(build: shippedRuntimeID)
        try fixture.makeClone(build: "wine-0.1")
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.runners.appending(path: ".\(shippedRuntimeID).new"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.runners.appending(path: ".wine-0.2.removing"),
                               withIntermediateDirectories: true)
        try Data().write(to: fixture.runners.appending(path: "notes"))
        try fm.createSymbolicLink(
            at: fixture.runners.appending(path: "linked"),
            withDestinationURL: SupportPaths.runnerRoot(forBuild: "wine-0.1", runners: fixture.runners))

        #expect(RunnerStore.clonedBuilds(in: fixture.runners) == ["wine-0.1", shippedRuntimeID])
        #expect(RunnerStore.installedBuilds(in: fixture.runners) == [shippedRuntime])
    }
}
