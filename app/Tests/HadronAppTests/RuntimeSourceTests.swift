import Foundation
import Testing

@testable import HadronApp

@Suite("The shipped runtime build")
struct SupportedRuntimeTests {

    @Test("The default runtime build comes first and serves one Rosetta tool")
    func shippedBuild() throws {
        let build = try #require(SupportedRunners.build(id: shippedRuntimeID))
        #expect(SupportedRunners.all.first?.id == shippedRuntimeID)
        #expect(build.tools.map(\.flavor) == [.rosetta])
        #expect(build.tools.map(\.name) == ["hadron-proton-\(shippedRuntimeID)"])
        #expect(SupportedRunners.displayVersion(forID: shippedRuntimeID) == build.releaseVersion)
        #expect(SupportedRunners.displayVersion(forID: "wine-0.1") == "wine-0.1")
        #expect(SupportedRunners.build(id: "wine-0.1") == nil)
    }

    // build-wine.sh builds what runtime/runtimes defines, and the app can only serve
    // what it lists, so a definition missing from either side is a runtime nobody gets.
    @Test("The app lists exactly the runtimes runtime/runtimes defines, by id and name")
    func agreesWithDefinitions() throws {
        let definitions = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "runtime/runtimes")
        let files = try FileManager.default.contentsOfDirectory(at: definitions, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "env" }
        var defined: [String: String] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            func value(_ key: String) -> String? {
                text.split(separator: "\n").first { $0.hasPrefix("\(key)=") }
                    .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            let id = try #require(value("RUNTIME_ID"))
            #expect(file.deletingPathExtension().lastPathComponent == id)
            defined[id] = value("RUNTIME_NAME")
        }
        #expect(defined.count == SupportedRunners.all.count)
        for build in SupportedRunners.all {
            #expect(defined[build.id] == build.releaseVersion, "\(build.id)")
            #expect(build.tools.allSatisfy { $0.name == "hadron-proton-\(build.id)" && $0.name.contains("proton") })
        }
    }

    @Test("Tools are served only for the builds that are installed")
    func toolsForInstalledBuilds() {
        #expect(SupportedRunners.tools(for: []).isEmpty)
        let tools = SupportedRunners.tools(for: [shippedRuntime])
        #expect(tools.map(\.name) == ["hadron-proton-\(shippedRuntimeID)"])
        #expect(tools.allSatisfy { $0.build == shippedRuntimeID })
    }
}

@Suite("Reading a Wine runtime folder")
struct RuntimeInspectionTests {

    @Test("The marker names the build, ignoring surrounding whitespace")
    func readsMarker() throws {
        let dir = try scratchDirectory("runtime-marker")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(RuntimeSource.runtimeID(atRoot: dir) == nil)

        let marker = dir.appending(path: RuntimeSource.markerName)
        try Data("  \(shippedRuntimeID)\n\n".utf8).write(to: marker)
        #expect(RuntimeSource.runtimeID(atRoot: dir) == shippedRuntimeID)

        // An empty marker names nothing, so the folder is not taken for a runtime.
        try Data(" \n".utf8).write(to: marker)
        #expect(RuntimeSource.runtimeID(atRoot: dir) == nil)
    }

    @Test("A folder is a runtime only with both a marker and lib/wine")
    func looksLikeRuntime() throws {
        let dir = try scratchDirectory("runtime-looks")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"))
        #expect(RuntimeSource.looksLikeRuntime(root))

        let bare = dir.appending(path: "bare")
        try fm.createDirectory(at: bare.appending(path: "lib/wine"), withIntermediateDirectories: true)
        #expect(!RuntimeSource.looksLikeRuntime(bare))

        let markerOnly = dir.appending(path: "marker-only")
        try fm.createDirectory(at: markerOnly, withIntermediateDirectories: true)
        try Data(shippedRuntimeID.utf8).write(to: markerOnly.appending(path: RuntimeSource.markerName))
        #expect(!RuntimeSource.looksLikeRuntime(markerOnly))
    }

    @Test("A runtime folder is found as a supported source whose root is the folder")
    func inspectsRuntime() throws {
        let dir = try scratchDirectory("runtime-inspect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"))

        let install = RuntimeSource.inspect(root: root)
        #expect(install.support == .supported(shippedRuntime))
        #expect(install.isUsable)
        #expect(!install.isManual)
        #expect(install.root == root)
        #expect(install.name == "Hadron \(shippedRuntime.releaseVersion)")
        #expect(RuntimeSource.inspect(root: root, isManual: true).isManual)
    }

    @Test("A runtime with an unknown id is listed as unsupported")
    func unknownRuntime() throws {
        let dir = try scratchDirectory("runtime-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"), id: "wine-0.1")

        let install = RuntimeSource.inspect(root: root)
        #expect(install.support == .unsupportedBuild("wine-0.1"))
        #expect(!install.isUsable)
        #expect(install.name == "Hadron wine-0.1")
    }

    @Test("A folder with no marker is named after itself and unsupported")
    func noMarker() throws {
        let dir = try scratchDirectory("runtime-nomarker")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appending(path: "some-wine")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(RuntimeSource.inspect(root: root).support == .unsupportedBuild("some-wine"))
    }

    @Test("The loader is the x86_64-unix wine inside the runtime")
    func unixLoader() {
        let root = URL(filePath: "/tmp/wine-runtime", directoryHint: .isDirectory)
        #expect(RuntimeSource.unixLoader(inRoot: root).path(percentEncoded: false)
            == "/tmp/wine-runtime/lib/wine/x86_64-unix/wine")
    }
}

@Suite("Choosing between Wine runtimes")
struct RuntimePreferenceTests {

    private func install(
        _ name: String, _ support: RuntimeSupport,
        root: String = "/runtimes", isManual: Bool = false
    ) -> RuntimeInstall {
        RuntimeInstall(root: URL(filePath: "\(root)/\(name)", directoryHint: .isDirectory),
                       support: support, isManual: isManual)
    }

    private func picked(_ installs: [RuntimeInstall]) -> RuntimeInstall? {
        installs.sorted(by: RuntimeSource.preferred).first(where: \.isUsable)
    }

    @Test("An unsupported runtime is not chosen over a usable one")
    func skipsUnsupported() {
        let old = install("a-old", .unsupportedBuild("wine-0.1"))
        let current = install("b-current", .supported(shippedRuntime))

        #expect(picked([old, current])?.root == current.root)
        #expect(picked([current, old])?.root == current.root)
        #expect([old, current].sorted(by: RuntimeSource.preferred).map(\.isUsable) == [true, false])
    }

    @Test("With no usable runtime, nothing is chosen")
    func nonePickedWhenAllUnusable() {
        let old = install("old", .unsupportedBuild("wine-0.1"))
        let other = install("other", .unsupportedBuild("wine-0.2"))
        #expect(picked([old, other]) == nil)
    }

    @Test("A runtime the user added is taken over one the search found")
    func prefersManual() {
        let found = install("wine", .supported(shippedRuntime))
        let named = install("wine", .supported(shippedRuntime), root: "/Volumes/Spare", isManual: true)

        #expect(picked([found, named])?.isManual == true)
        #expect(picked([named, found])?.isManual == true)
    }

    @Test("The same build in two folders resolves to the same one every sort")
    func breaksNameTieByPath() {
        let first = install("wine", .supported(shippedRuntime), root: "/a")
        let second = install("wine", .supported(shippedRuntime), root: "/b")

        // Every key but the path matches here, and sorted(by:) is unstable, so without the
        // path tie-break the copy source could differ between two runs on one machine.
        #expect(picked([first, second])?.root == first.root)
        #expect(picked([second, first])?.root == first.root)
    }
}

// discover() reads the standard defaults and the real runtimes folder, so these add a
// scratch runtime by hand and put the defaults back afterwards.
@Suite("Finding Wine runtimes", .serialized)
struct RuntimeDiscoveryTests {

    private static let key = "manualRuntimePaths"

    private func withManualRoots<T>(_ roots: [URL], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Self.key)
        RuntimeSource.setManualRoots(roots)
        defer {
            if let saved { defaults.set(saved, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
        }
        return try body()
    }

    @Test("The search covers the runtimes folder in the support directory")
    func searchRoot() {
        #expect(RuntimeSource.same(
            RuntimeSource.searchRoot, SupportPaths.support.appending(path: "runtimes", directoryHint: .isDirectory)))
        #expect(RuntimeSource.isSearched(RuntimeSource.searchRoot.appending(path: shippedRuntimeID)))
        #expect(!RuntimeSource.isSearched(URL(filePath: "/Volumes/Spare/\(shippedRuntimeID)")))
        #expect(!RuntimeSource.isSearched(
            RuntimeSource.searchRoot.appending(path: "nested/\(shippedRuntimeID)")))
    }

    @Test("A runtime added by hand is found and marked as added, a non-runtime is skipped")
    func findsManualRuntime() throws {
        let dir = try scratchDirectory("runtime-discover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "mine"))
        let junk = dir.appending(path: "junk")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)

        let found = withManualRoots([root, junk, root]) { RuntimeSource.discover() }

        let mine = found.filter { RuntimeSource.same($0.root, root) }
        #expect(mine.count == 1)
        #expect(mine.first?.isManual == true)
        #expect(mine.first?.isUsable == true)
        #expect(!found.contains { RuntimeSource.same($0.root, junk) })
        // A runtime picked by hand outranks anything the search found.
        #expect(found.first(where: \.isUsable).map { RuntimeSource.same($0.root, root) } == true)
    }

    @Test("An unsupported runtime added by hand is still listed, after the usable ones")
    func listsUnsupportedManualRuntime() throws {
        let dir = try scratchDirectory("runtime-discover-old")
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try makeRuntime(at: dir.appending(path: "old"), id: "wine-0.1")
        let current = try makeRuntime(at: dir.appending(path: "current"))

        let found = withManualRoots([old, current]) { RuntimeSource.discover() }

        let oldIndex = try #require(found.firstIndex { RuntimeSource.same($0.root, old) })
        let currentIndex = try #require(found.firstIndex { RuntimeSource.same($0.root, current) })
        #expect(found[oldIndex].support == .unsupportedBuild("wine-0.1"))
        #expect(currentIndex < oldIndex)
    }
}

@Suite("Manually added runtimes")
struct ManualRuntimeTests {

    private func defaults() -> UserDefaults {
        let name = "np-manual-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Adding keeps earlier runtimes, skips repeats, and removing drops only the one named")
    func addAndRemove() {
        let defaults = defaults()
        let spare = URL(filePath: "/Volumes/Spare/wine-runtime", directoryHint: .isDirectory)
        let other = URL(filePath: "/Volumes/Other/wine-runtime", directoryHint: .isDirectory)

        RuntimeSource.addManualRoot(spare, defaults)
        RuntimeSource.addManualRoot(other, defaults)
        RuntimeSource.addManualRoot(URL(filePath: "/Volumes/Spare/wine-runtime/"), defaults)
        #expect(RuntimeSource.manualRoots(defaults) == [spare, other])

        RuntimeSource.removeManualRoot(spare, defaults)
        #expect(RuntimeSource.manualRoots(defaults) == [other])
    }

    @Test("Empty remembered paths are ignored")
    func ignoresEmptyPaths() {
        let defaults = defaults()
        defaults.set(["", "/Volumes/Spare/wine-runtime"], forKey: "manualRuntimePaths")
        #expect(RuntimeSource.manualRoots(defaults).map { $0.path(percentEncoded: false) }
            == ["/Volumes/Spare/wine-runtime/"])
    }
}

@Suite("Copying a Wine runtime")
struct RuntimeCopyTests {

    @Test("A copy verifies by its marker and loader")
    func verifiesCopy() throws {
        let dir = try scratchDirectory("runtime-verify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"))

        try RunnerInstaller.verifyClone(build: shippedRuntime, root: root)

        let other = try makeRuntime(at: dir.appending(path: "other"), id: "wine-0.1")
        let wrongBuild = try #require(throws: StepFailure.self) {
            try RunnerInstaller.verifyClone(build: shippedRuntime, root: other)
        }
        #expect(wrongBuild.detail.contains("is not Wine runtime \(shippedRuntimeID)"))

        try FileManager.default.removeItem(at: RuntimeSource.unixLoader(inRoot: root))
        let noLoader = try #require(throws: StepFailure.self) {
            try RunnerInstaller.verifyClone(build: shippedRuntime, root: root)
        }
        #expect(noLoader.detail.contains("no Wine loader"))
    }

    @Test("A loader that is not executable is refused")
    func refusesNonExecutableLoader() throws {
        let dir = try scratchDirectory("runtime-verify-exec")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: RuntimeSource.unixLoader(inRoot: root).path(percentEncoded: false))

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.verifyClone(build: shippedRuntime, root: root)
        }
    }

    @Test("A runtime with lsteamclient built in has no problems, a missing half is named")
    func reportsMissingLsteamclient() throws {
        let dir = try scratchDirectory("runtime-problems")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try makeRuntime(at: dir.appending(path: "wine-runtime"))

        #expect(RunnerInstaller.problems(build: shippedRuntime, root: root).isEmpty)

        try FileManager.default.removeItem(at: root.appending(path: "lib/wine/x86_64-unix/lsteamclient.so"))
        #expect(RunnerInstaller.problems(build: shippedRuntime, root: root)
            == ["x86_64-unix/lsteamclient.so is missing"])

        let bare = try makeRuntime(at: dir.appending(path: "bare"), lsteamclient: false)
        #expect(RunnerInstaller.problems(build: shippedRuntime, root: bare) == [
            "i386-windows/lsteamclient.dll is missing",
            "x86_64-windows/lsteamclient.dll is missing",
            "x86_64-unix/lsteamclient.so is missing",
        ])
    }

    @Test("Setup copies the runtime folder itself into runners/<id>")
    func copiesIntoRunners() throws {
        let dir = try scratchDirectory("runtime-clone")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let source = try makeRuntime(at: dir.appending(path: "source/wine-runtime"))

        let copied = try RunnerInstaller.clone(from: RuntimeSource.inspect(root: source), runners: runners)

        #expect(copied)
        let target = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        #expect(target.lastPathComponent == shippedRuntimeID)
        #expect(RuntimeSource.runtimeID(atRoot: target) == shippedRuntimeID)
        #expect(FileManager.default.isExecutableFile(
            atPath: RuntimeSource.unixLoader(inRoot: target).path(percentEncoded: false)))
        #expect(RunnerInstaller.hasClone(forBuild: shippedRuntimeID, runners: runners))
        #expect(RunnerStore.clonedBuilds(in: runners) == [shippedRuntimeID])
        // No staging directory is left beside it.
        let entries = try FileManager.default.contentsOfDirectory(atPath: runners.path(percentEncoded: false))
        #expect(entries == [shippedRuntimeID])
    }

    @Test("An installed runtime is kept as it is, not copied again")
    func skipsWhenPresent() throws {
        let dir = try scratchDirectory("runtime-clone-skip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let source = try makeRuntime(at: dir.appending(path: "source/wine-runtime"))
        let install = RuntimeSource.inspect(root: source)

        #expect(try RunnerInstaller.clone(from: install, runners: runners))
        let target = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        let mark = target.appending(path: "kept")
        try Data("installed".utf8).write(to: mark)

        #expect(try RunnerInstaller.clone(from: install, runners: runners) == false)
        #expect(FileManager.default.fileExists(atPath: mark.path(percentEncoded: false)))
    }

    @Test("Repair copies the runtime again over the installed one")
    func repairReplaces() throws {
        let dir = try scratchDirectory("runtime-clone-repair")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let source = try makeRuntime(at: dir.appending(path: "source/wine-runtime"))
        let install = RuntimeSource.inspect(root: source)

        try RunnerInstaller.clone(from: install, runners: runners)
        let target = SupportPaths.runnerRoot(forBuild: shippedRuntimeID, runners: runners)
        let stray = target.appending(path: "stray")
        try Data("left behind".utf8).write(to: stray)
        try FileManager.default.removeItem(at: target.appending(path: "lib/wine/x86_64-unix/lsteamclient.so"))
        #expect(!RunnerInstaller.problems(build: shippedRuntime, root: target).isEmpty)

        #expect(try RunnerInstaller.clone(from: install, replacingExisting: true, runners: runners))

        #expect(!FileManager.default.fileExists(atPath: stray.path(percentEncoded: false)))
        #expect(RunnerInstaller.problems(build: shippedRuntime, root: target).isEmpty)
    }

    @Test("An unsupported runtime is refused before anything is copied")
    func refusesUnsupported() throws {
        let dir = try scratchDirectory("runtime-clone-old")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let source = try makeRuntime(at: dir.appending(path: "source/old"), id: "wine-0.1")

        let failure = try #require(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: RuntimeSource.inspect(root: source), runners: runners)
        }
        #expect(failure.detail.contains("not a supported build"))
        #expect(!FileManager.default.fileExists(atPath: runners.path(percentEncoded: false)))
    }

    @Test("A copy whose marker names another build is refused after copying")
    func refusesMislabelledCopy() throws {
        let dir = try scratchDirectory("runtime-clone-swap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runners = dir.appending(path: "runners")
        let source = try makeRuntime(at: dir.appending(path: "source/wine-runtime"))
        let install = RuntimeSource.inspect(root: source)

        // The folder was swapped for another build between discovery and the copy.
        try Data("wine-0.1\n".utf8).write(to: source.appending(path: RuntimeSource.markerName))

        #expect(throws: StepFailure.self) {
            try RunnerInstaller.clone(from: install, runners: runners)
        }
    }
}
