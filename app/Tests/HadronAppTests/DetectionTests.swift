import Foundation
import Testing

@testable import HadronApp

@Suite("Runner allow list")
struct SupportedRunnerTests {

    @Test("Identities are unique so lookup is unambiguous")
    func identitiesAreUnique() {
        #expect(!SupportedRunners.all.isEmpty)
        let ids = SupportedRunners.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let tools = SupportedRunners.all.flatMap(\.tools).map(\.name)
        #expect(Set(tools).count == tools.count)
    }

    // The installed row has only the copy's directory name, which is the id.
    @Test("An installed build is named the same way the picked one is")
    func installedBuildsReadBackTheSame() {
        for build in SupportedRunners.all {
            #expect(SupportedRunners.displayVersion(forID: build.id) == build.displayVersion)
            #expect(build.displayVersion == build.releaseVersion)
        }

        // A tree off the allow list still has to say something, and its directory name is
        // all there is to say.
        #expect(SupportedRunners.displayVersion(forID: "wine-0.1") == "wine-0.1")
    }

    @Test("Lookup matches on an exact id only")
    func lookupIsExact() {
        let build = SupportedRunners.all[0]
        #expect(SupportedRunners.build(id: build.id) == build)
        #expect(SupportedRunners.build(id: build.id + " ") == nil)
        #expect(SupportedRunners.build(id: String(build.id.dropLast())) == nil)
    }

    @Test("The supported list names every release")
    func versionList() {
        #expect(SupportedRunners.versionList
            == SupportedRunners.all.map(\.releaseVersion).joined(separator: ", "))
        #expect(SupportedRunners.versionList.contains(shippedRuntime.releaseVersion))
    }
}

@Suite("Steam tools")
struct CompatToolOrderTests {

    @Test("Tools come out in allow-list order, whatever order the builds are in")
    func order() throws {
        let tools = SupportedRunners.tools(for: SupportedRunners.all.reversed())
        #expect(tools.map(\.name) == SupportedRunners.all.flatMap(\.tools).map(\.name))
        #expect(tools.first?.name == "hadron-proton-\(shippedRuntimeID)")
        #expect(tools.first?.build == shippedRuntimeID)
    }

    @Test("A build off the allow list serves no tools")
    func unknownBuild() {
        let unknown = RunnerBuild(id: "wine-0.1", releaseVersion: "Wine 0.1", tools: [
            CompatTool(name: "hadron-old", flavor: .rosetta, display: "Old"),
        ])
        #expect(SupportedRunners.tools(for: [unknown]).isEmpty)
    }

    @Test("A tool's flavor decides its prefix arch and Wine unix folder")
    func flavors() {
        let rosetta = CompatTool(name: "hadron-a", flavor: .rosetta, display: "A")
        let fex = CompatTool(name: "hadron-b", flavor: .fex, display: "B")
        #expect(rosetta.prefixArch == .x86_64)
        #expect(fex.prefixArch == .arm64)
        #expect(CompatTool.Flavor.rosetta.unixDir == "x86_64-unix")
        #expect(CompatTool.Flavor.fex.unixDir == "aarch64-unix")
        #expect(CompatTool.Flavor.rosetta.name == "Rosetta")
        #expect(CompatTool.Flavor.fex.name == "FEX")
    }

    @Test("Every tool name is one the dylib accepts")
    func namesParse() {
        for tool in SupportedRunners.all.flatMap(\.tools) {
            #expect(tool.name.hasPrefix("hadron"))
            #expect(tool.name.contains("proton"))
            #expect(tool.name.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) })
            #expect(!tool.display.contains { "\"\\".contains($0) || $0.isNewline })
        }
    }

    @Test("The list file has one tab-separated line per tool")
    func contents() throws {
        let tools = SupportedRunners.tools(for: [shippedRuntime])
        #expect(CompatToolList.contents(tools)
            == "hadron-proton-\(shippedRuntimeID)\t\(shippedRuntimeID)\trosetta\tHadron Wine 11.15\n")
    }
}

@Suite("Signature database selection")
struct SignatureSelectionTests {

    @Test("The highest numbered database wins, not the first listed")
    func picksHighestBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["1788400362.json", "999999999.json", "1788400363.json", "notes.txt"] {
            try Data().write(to: directory.appending(path: name))
        }

        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == "1788400363.json")
    }

    @Test("An empty or absent directory reports nothing staged")
    func handlesEmptyDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "np-signature-empty-\(UUID().uuidString)")
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(PayloadInspector.newestSignatureDatabase(in: directory) == nil)
    }
}

@Suite("Support paths")
struct SupportPathTests {

    // These strings are a contract with the dylib and RUN_SCRIPT rather than a
    // preference, so they are pinned here to make a rename visible.
    @Test("Paths match what the dylib and the run script use")
    func pathsAreStable() {
        let support = SupportPaths.support.path(percentEncoded: false)
        #expect(support.hasSuffix("/Library/Application Support/hadron"))

        #expect(SupportPaths.signatures.path(percentEncoded: false)
            .hasSuffix("/hadron/signatures/macos.arm64"))
        #expect(SupportPaths.overlayShim.path(percentEncoded: false)
            .hasSuffix("/hadron/overlay-shim.dylib"))
        #expect(SupportPaths.toolList.path(percentEncoded: false)
            .hasSuffix("/hadron/tools"))
        #expect(SupportPaths.Steam.deployedDylib.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/MacOS/hadron.dylib")
        #expect(SupportPaths.Steam.infoPlist.path(percentEncoded: false)
            == "/Applications/Steam.app/Contents/Info.plist")
        #expect(SupportPaths.runnerRoot(forBuild: shippedRuntimeID).path(percentEncoded: false)
            .hasSuffix("/hadron/runners/\(shippedRuntimeID)"))
    }

    @Test("The run script finds an installed runtime where setup copies it")
    func runScriptAgreesOnRunnerRoot() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
        #expect(script.contains("np_root=\"$np_support/runners/$np_build\""))
        #expect(script.contains("\"$np_support\"/runners/*/share/wine/wine.inf"))
        let support = URL(filePath: "/S")
        #expect(SupportPaths.runnerRoot(forBuild: "$np_build", runners: support.appending(path: "runners"))
            .path(percentEncoded: false) == "/S/runners/$np_build")
    }
}
