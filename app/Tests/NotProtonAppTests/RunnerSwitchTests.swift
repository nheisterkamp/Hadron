import Foundation
import Testing

@testable import NotProtonApp

@Suite("Preparing an installed build")
struct RunnerPrepareTests {

    private static let runScript = Data("#!/bin/sh\n".utf8)

    private final class Calls: @unchecked Sendable {
        var verified: [String] = []
        var phases: [RunnerSetup.Phase] = []
    }

    private func makeRunners(cloning builds: [String]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-prepare-\(UUID().uuidString)/runners")
        try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        for build in builds { try makeInstalledRuntime(in: runners, id: build) }
        return runners
    }

    private func prepare(
        _ build: RunnerBuild,
        runners: URL,
        calls: Calls = Calls(),
        failVerify: Bool = false
    ) throws -> RunnerSetup.Outcome {
        try RunnerSetup.prepare(
            build,
            runners: runners,
            toolList: runners.deletingLastPathComponent().appending(path: "tools"),
            compatTools: runners.deletingLastPathComponent().appending(path: "compatibilitytools.d"),
            runScript: {
                let script = runners.deletingLastPathComponent().appending(path: "payload-run")
                try Self.runScript.write(to: script)
                return script
            },
            verify: { build, _ in
                calls.verified.append(build.id)
                if failVerify { throw StepFailure(step: "test", detail: "verify failed") }
            },
            report: { calls.phases.append($0) }
        )
    }

    private func toolList(_ runners: URL) -> String? {
        try? String(contentsOf: runners.deletingLastPathComponent().appending(path: "tools"), encoding: .utf8)
    }

    @Test("The set-up build is listed as its tools, and a second run changes nothing")
    func listsBuild() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, "wine-0.1"])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        let calls = Calls()
        let outcome = try prepare(shippedRuntime, runners: runners, calls: calls)

        #expect(outcome.toolsChanged)
        #expect(!outcome.copied)
        #expect(!outcome.stagedNothing)
        #expect(calls.verified == [shippedRuntimeID])
        #expect(calls.phases.map(\.label) == [RunnerSetup.Phase.installing.label, RunnerSetup.Phase.finished.label])
        #expect(toolList(runners) == CompatToolList.contents(SupportedRunners.tools(for: [shippedRuntime])))
        #expect(toolList(runners)?.hasPrefix("notproton-wine\t\(shippedRuntimeID)\trosetta\t") == true)

        let again = try prepare(shippedRuntime, runners: runners)
        #expect(!again.toolsChanged)
        #expect(again.stagedNothing)
    }

    @Test("Every listed tool gets a run script")
    func writesMissingRunScripts() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        _ = try prepare(shippedRuntime, runners: runners)

        let tools = CompatToolList.installed(runners: runners, file: runners.deletingLastPathComponent().appending(path: "tools"))
        #expect(!tools.isEmpty)
        for tool in tools {
            let run = runners.deletingLastPathComponent().appending(path: "compatibilitytools.d/\(tool.name)/run")
            #expect(try Data(contentsOf: run) == Self.runScript)
            #expect(FileManager.default.isExecutableFile(atPath: run.path))
        }
    }

    @Test("A tool's existing run script is left alone")
    func keepsExistingRunScript() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let tool = SupportedRunners.tools(for: [shippedRuntime])[0].name
        let run = runners.deletingLastPathComponent().appending(path: "compatibilitytools.d/\(tool)/run")
        let old = Data("#!/bin/sh\nexec an older script\n".utf8)
        try atomicReplace(run, with: old, step: "test")

        _ = try prepare(shippedRuntime, runners: runners)

        #expect(try Data(contentsOf: run) == old)
    }

    @Test("A copy that fails verification leaves the tool list as it was")
    func failedVerifyKeepsList() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(throws: StepFailure.self) {
            try prepare(shippedRuntime, runners: runners, failVerify: true)
        }
        #expect(toolList(runners) == nil)
        #expect(!FileManager.default.fileExists(
            atPath: runners.deletingLastPathComponent().appending(path: "compatibilitytools.d").path(percentEncoded: false)))
    }

    @Test("The real verification refuses a copy without its loader")
    func defaultVerifyRefusesMissingLoader() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: RuntimeSource.unixLoader(
            inRoot: SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)))

        #expect(throws: StepFailure.self) {
            try RunnerSetup.prepare(
                shippedRuntime, runners: runners, toolList: runners.deletingLastPathComponent().appending(path: "tools"),
                compatTools: runners.deletingLastPathComponent().appending(path: "compatibilitytools.d"),
                runScript: { runners.deletingLastPathComponent().appending(path: "payload-run") }
            )
        }
        #expect(toolList(runners) == nil)
    }

    @Test("With nothing set up and no list yet, no list is written")
    func writesNoEmptyList() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let file = runners.deletingLastPathComponent().appending(path: "support/tools")

        let changed = try CompatToolList.sync(runners: runners, file: file)

        #expect(!changed)
        #expect(!FileManager.default.fileExists(
            atPath: file.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("A list left from a removed build is emptied, not deleted")
    func emptiesStaleList() throws {
        let runners = try makeRunners(cloning: [])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let file = runners.deletingLastPathComponent().appending(path: "tools")
        try CompatToolList.contents(SupportedRunners.tools(for: [shippedRuntime]))
            .write(to: file, atomically: true, encoding: .utf8)

        #expect(try CompatToolList.sync(runners: runners, file: file))
        #expect(try String(contentsOf: file, encoding: .utf8).isEmpty)
        #expect(try !CompatToolList.sync(runners: runners, file: file))
    }

    @Test("A build with no copy is refused without touching anything")
    func refusesMissingClone() throws {
        let runners = try makeRunners(cloning: ["wine-0.1"])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        let calls = Calls()
        let failure = try #require(throws: StepFailure.self) {
            try prepare(shippedRuntime, runners: runners, calls: calls)
        }

        #expect(failure.detail.contains("has not been set up"))
        #expect(calls.verified.isEmpty)
        #expect(toolList(runners) == nil)
    }

    @Test("Installed builds are supported copies that still have their lib/wine")
    func installedBuildsListing() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, "wine-0.1"])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(RunnerStore.installedBuilds(in: runners) == [shippedRuntime])

        try FileManager.default.removeItem(
            at: SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
                .appending(path: "lib/wine")
        )

        #expect(RunnerStore.installedBuilds(in: runners).isEmpty)
    }
}

@MainActor
@Suite("Choosing which runtime to set up from")
struct SetupSourceTests {

    private func install(_ name: String, _ support: RuntimeSupport = .supported(shippedRuntime)) -> RuntimeInstall {
        RuntimeInstall(root: URL(filePath: "/runtimes/\(name)", directoryHint: .isDirectory), support: support)
    }

    private func status(runner: RunnerState, installs: [RuntimeInstall]) -> SystemStatus {
        let status = SystemStatus()
        status.snapshot = StatusSnapshot(
            steam: .steamMissing,
            steamRunning: false,
            updateBlocked: false,
            runtimes: installs,
            runner: runner,
            payload: PayloadInspector.inspect(bridge: FileManager.default.temporaryDirectory)
        )
        return status
    }

    @Test("A recopy comes from a runtime of the set-up build")
    func prefersInstalledBuild() {
        let old = install("old", .unsupportedBuild("wine-0.1"))
        let current = install("current")

        let status = status(runner: .ready(builds: [shippedRuntimeID]), installs: [old, current])
        status.snapshot?.installedRunners = [shippedRuntime]

        #expect(status.repairSource?.id == current.id)
        #expect(status.setupSource?.id == current.id)
    }

    @Test("With no tool set up, the first usable runtime is used")
    func fallsBackToPreferred() {
        let old = install("old", .unsupportedBuild("wine-0.1"))
        let first = install("first")
        let second = install("second")

        let status = status(runner: .none, installs: [old, first, second])

        #expect(status.usableRuntime?.id == first.id)
        #expect(status.setupSource?.id == first.id)
        #expect(status.usableRuntimes.map(\.id) == [first.id, second.id])
    }

    @Test("A runtime of another build cannot repair a set-up one")
    func repairSourceIsNilWhenBuildDiffers() {
        let current = install("current")
        let status = status(runner: .ready(builds: ["wine-0.1"]), installs: [current])

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == current.id)
    }

    @Test("An incomplete build can be repaired from its runtime")
    func repairsIncompleteBuild() {
        let current = install("current")
        let status = status(
            runner: .incomplete(builds: [shippedRuntimeID], problems: ["x86_64-unix/lsteamclient.so is missing"]),
            installs: [current]
        )

        #expect(status.repairSource?.id == current.id)
    }

    @Test("With nothing set up there is no repair source")
    func noRepairSourceBeforeFirstSetUp() {
        let current = install("current")
        let status = status(runner: .none, installs: [current])

        #expect(status.repairSource == nil)
        #expect(status.setupSource?.id == current.id)
    }

    @Test("With only unsupported runtimes there is nothing to set up from")
    func noSourceWithoutUsableRuntime() {
        let status = status(runner: .none, installs: [install("old", .unsupportedBuild("wine-0.1"))])

        #expect(status.usableRuntime == nil)
        #expect(status.usableRuntimes.isEmpty)
        #expect(status.setupSource == nil)
    }
}

@Suite("Removing an installed build")
struct RunnerRemovalTests {

    // Hadron serves one build, so a second build on disk is one it no longer serves.
    private static let other = "wine-0.1"

    // runners/ sits in its own scratch folder, so the tool list can go beside it: every
    // directory inside runners/ counts as a build.
    private func makeRunners(cloning builds: [String]) throws -> URL {
        let runners = FileManager.default.temporaryDirectory
            .appending(path: "np-remove-\(UUID().uuidString)/runners")
        try FileManager.default.createDirectory(at: runners, withIntermediateDirectories: true)
        for build in builds { try makeInstalledRuntime(in: runners, id: build) }
        return runners
    }

    private func remove(
        _ build: String, runners: URL, libraries: [SteamLibrary] = [], running: Bool = false
    ) throws -> Bool {
        try RunnerInstaller.removeClone(
            forBuild: build, runners: runners,
            toolList: runners.deletingLastPathComponent().appending(path: "tools"),
            libraries: libraries,
            running: { _ in running }
        )
    }

    @Test("Removing a build leaves nothing of it in the runners folder")
    func removalLeavesNothing() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let fm = FileManager.default
        let leftover = runners.appending(path: ".\(shippedRuntimeID).removing/lib")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)

        _ = try remove(shippedRuntimeID, runners: runners)

        let left = try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.contains(shippedRuntimeID) }
        #expect(left.isEmpty)
        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.other])
    }

    @Test("Removing a build also clears what an earlier failed removal of any build left")
    func removalClearsOtherLeftovers() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let fm = FileManager.default
        for name in [".\(Self.other).removing/lib", ".an-older-layout-1.0.removing/payload"] {
            try fm.createDirectory(at: runners.appending(path: name), withIntermediateDirectories: true)
        }

        _ = try remove(shippedRuntimeID, runners: runners)

        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("A removal whose tool list cannot be written puts the build back")
    func failedSyncRestoresBuild() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let fm = FileManager.default
        // A directory where the list goes, so the list the shipped build keeps cannot be written.
        try fm.createDirectory(at: runners.deletingLastPathComponent().appending(path: "tools/blocked"), withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try remove(Self.other, runners: runners) }

        #expect(RunnerStore.clonedBuilds(in: runners) == [Self.other, shippedRuntimeID])
        #expect(RunnerInstaller.hasClone(forBuild: Self.other, runners: runners))
        #expect(try fm.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
            .filter { $0.hasSuffix(".removing") }.isEmpty)
    }

    @Test("Removing a build deletes its prefix templates in every library and keeps the others")
    func removesThatBuildsTemplates() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let fm = FileManager.default
        let libraries = ["internal", "external"].map {
            SteamLibrary(root: runners.deletingLastPathComponent().appending(path: "libraries/\($0)"))
        }
        for library in libraries {
            for build in [shippedRuntimeID, Self.other] {
                for template in SupportPaths.prefixTemplates(forBuild: build, in: library) {
                    try fm.createDirectory(
                        at: template.appending(path: "pfx/drive_c"), withIntermediateDirectories: true)
                }
            }
        }

        _ = try remove(shippedRuntimeID, runners: runners, libraries: libraries)

        for library in libraries {
            let left = try fm.contentsOfDirectory(
                atPath: library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    .path(percentEncoded: false)
            ).sorted()
            #expect(left == SupportPaths.prefixTemplates(forBuild: Self.other, in: library)
                .map(\.lastPathComponent).sorted())
        }
    }

    @Test("Removing a build also clears templates left by builds removed while their drive was away")
    func removesTemplatesOfBuildsAlreadyGone() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let fm = FileManager.default
        let library = SteamLibrary(root: runners.deletingLastPathComponent().appending(path: "libraries/external"))
        let gone = SupportPaths.prefixTemplates(forBuild: "wine-10.0", in: library)
        for template in gone {
            try fm.createDirectory(at: template.appending(path: "pfx"), withIntermediateDirectories: true)
        }

        _ = try remove(shippedRuntimeID, runners: runners, libraries: [library])

        for template in gone { #expect(!fm.fileExists(atPath: template.path(percentEncoded: false))) }
    }

    @Test("A template is named by the build and the unix arch, under notproton-template")
    func templateNamesMatchTheScript() throws {
        let library = SteamLibrary(root: URL(filePath: "/L"))
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        let expression = try #require(script.firstMatch(of: #/runner_id="([^"]+)"/#)).1
        let cache = script.split(separator: "\n").first { $0.contains("template_cache=\"") }
        #expect(cache?.contains("$(dirname \"$STEAM_COMPAT_DATA_PATH\")/\(SupportPaths.prefixTemplateFolder)\"") == true)
        let template = script.split(separator: "\n").first { $0.contains("template_dir=\"") }
        #expect(template?.contains("template_dir=\"$template_cache/$runner_id\"") == true)
        let names = ["x86_64-unix", "aarch64-unix"].map { arch in
            expression.replacingOccurrences(of: "$np_build", with: shippedRuntimeID)
                .replacingOccurrences(of: "${wine_unix##*/}", with: arch)
        }
        #expect(SupportPaths.prefixTemplates(forBuild: shippedRuntimeID, in: library).map(\.path)
            == names.map { library.compatdata.appending(path: SupportPaths.prefixTemplateFolder).appending(path: $0).path })
    }

    @Test("A build with a game still running on it is not removed")
    func keepsRunningBuild() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(throws: StepFailure.self) { try remove(shippedRuntimeID, runners: runners, running: true) }
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
    }

    @Test("A process runs from a copy only when its executable sits inside it")
    func readsRunningExecutables() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "np-ps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ps = dir.appending(path: "ps")
        try """
            #!/bin/sh
            echo "/launchd"
            echo "/R/\(shippedRuntimeID)/bin/wineserver"
            """.write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path(percentEncoded: false))
        let path = ps.path(percentEncoded: false)

        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/\(shippedRuntimeID)"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/wine-11.1"), ps: path))
        #expect(!RunnerInstaller.isRunning(from: URL(filePath: "/R/\(Self.other)"), ps: path))
        #expect(RunnerInstaller.isRunning(from: URL(filePath: "/R/x"), ps: "/nonexistent/ps"))
    }

    @Test("Any build can be removed, and its tools go with it")
    func removesBuild() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(try remove(Self.other, runners: runners))

        #expect(!RunnerInstaller.hasClone(forBuild: Self.other, runners: runners))
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
        let list = try String(contentsOf: runners.deletingLastPathComponent().appending(path: "tools"), encoding: .utf8)
        #expect(list == CompatToolList.contents(SupportedRunners.tools(for: [shippedRuntime])))

        #expect(try remove(shippedRuntimeID, runners: runners))
        #expect(try String(contentsOf: runners.deletingLastPathComponent().appending(path: "tools"), encoding: .utf8).isEmpty)
    }

    @Test("A build with no copy reports rather than succeeding quietly")
    func refusesMissingBuild() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(throws: StepFailure.self) {
            try remove(Self.other, runners: runners)
        }
    }

    @Test("A supported build whose copy never finished is listed as damaged")
    func damagedCloneIsListed() throws {
        let runners = try makeRunners(cloning: [Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners),
            withIntermediateDirectories: true
        )

        #expect(RunnerStore.damagedClones(in: runners) == [shippedRuntimeID])
        #expect(RunnerStore.orphanedClones(in: runners) == [Self.other])
        #expect(RunnerStore.installedBuilds(in: runners).isEmpty)
    }

    @Test("Every copy on disk lands in exactly one of the three lists")
    func cloneListsPartition() throws {
        for damaged in [false, true] {
            let runners = try makeRunners(cloning: damaged ? [Self.other] : [shippedRuntimeID, Self.other])
            defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
            if damaged {
                try FileManager.default.createDirectory(
                    at: SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners),
                    withIntermediateDirectories: true
                )
            }

            let installed = RunnerStore.installedBuilds(in: runners).map(\.id)
            let broken    = RunnerStore.damagedClones(in: runners)
            let orphaned  = RunnerStore.orphanedClones(in: runners)
            let all       = installed + broken + orphaned

            #expect(Set(all) == Set(RunnerStore.clonedBuilds(in: runners)))
            #expect(all.count == Set(all).count)
            #expect(all.count == 2)
        }
    }

    @Test("Copies of unsupported builds are listed apart from installed builds")
    func orphanedClonesAreFound() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        #expect(RunnerStore.orphanedClones(in: runners) == [Self.other])
        #expect(RunnerStore.installedBuilds(in: runners).map(\.id) == [shippedRuntimeID])
    }

    @Test("An orphaned copy can be removed")
    func removesOrphanedClone() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID, Self.other])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }

        _ = try remove(Self.other, runners: runners)

        #expect(RunnerStore.orphanedClones(in: runners).isEmpty)
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
    }

    @Test("A copy's size counts the bytes it occupies")
    func measuresCloneSize() throws {
        let runners = try makeRunners(cloning: [shippedRuntimeID])
        defer { try? FileManager.default.removeItem(at: runners.deletingLastPathComponent()) }
        let file = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
            .appending(path: "lib/wine/blob")
        try Data(repeating: 0, count: 64 * 1024).write(to: file)

        #expect(RunnerStore.cloneSize(forBuild: shippedRuntimeID, runners: runners) >= 64 * 1024)
    }
}
