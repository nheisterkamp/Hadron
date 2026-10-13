import Foundation
import Testing

@testable import NotProtonApp

// A self-built runtime goes through the CrossOver pipeline with the CrossOver-only steps
// skipped. These pin which steps are skipped, and that a CrossOver tree cannot pass as one.
@Suite("Wine runtime")
struct WineRuntimeTests {

    private static let runtimeID = "wine-11.15"

    // The layout runtime/build-wine.sh stages, reduced to what the app looks at.
    private static func runtime(id: String = runtimeID, in dir: URL) throws -> URL {
        let fm = FileManager.default
        let root = dir.appending(path: "wine-runtime")
        let unix = root.appending(path: "lib/wine/x86_64-unix")
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        for arch in ["i386-windows", "x86_64-windows"] {
            let windows = root.appending(path: "lib/wine/\(arch)")
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try Data("pe".utf8).write(to: windows.appending(path: "lsteamclient.dll"))
        }
        try Data("so".utf8).write(to: unix.appending(path: "lsteamclient.so"))
        let loader = unix.appending(path: "wine")
        try Data("#!/bin/sh\n".utf8).write(to: loader)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path(percentEncoded: false))
        try Data("\(id)\n".utf8).write(to: root.appending(path: WineRuntime.markerName))
        return root
    }

    @Test("The shipped runtime build carries no pins and serves a Rosetta tool")
    func shippedBuild() throws {
        let build = try #require(SupportedRunners.build(id: Self.runtimeID))
        #expect(build.source == .runtime)
        #expect(build.cleanNtdll.isEmpty && build.patchedNtdll.isEmpty)
        #expect(build.tools.map(\.flavor) == [.rosetta])
        #expect(SupportedRunners.build(loaderSHA256: "") == nil)
    }

    @Test("A runtime folder is found as a supported source whose root is the folder")
    func inspectsRuntime() throws {
        let dir = try scratchDirectory("runtime-inspect")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.runtime(in: dir)

        #expect(CrossOverSource.looksLikeCrossOver(root))
        let install = CrossOverSource.inspect(bundle: root)
        #expect(install.isRuntime)
        #expect(install.isUsable)
        #expect(install.crossOverRoot == root)
        #expect(install.name == "Hadron Wine 11.15")
    }

    @Test("A usable runtime is preferred over a usable CrossOver, even one picked by hand")
    func runtimeComesFirst() throws {
        let dir = try scratchDirectory("runtime-order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = CrossOverSource.inspect(bundle: try Self.runtime(in: dir))
        let build = try #require(SupportedRunners.all.first { $0.source == .crossOver })
        let crossOver = CrossOverInstall(
            bundle: dir.appending(path: "CrossOver.app"), releaseVersion: build.releaseVersion,
            support: .supported(build), isManual: true
        )

        #expect([crossOver, runtime].sorted(by: CrossOverSource.preferred).map(\.isRuntime) == [true, false])
    }

    @Test("A runtime with an unknown id is listed as unsupported")
    func unknownRuntime() throws {
        let dir = try scratchDirectory("runtime-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.runtime(id: "wine-0.1", in: dir)

        let install = CrossOverSource.inspect(bundle: root)
        #expect(install.support == .unsupportedBuild("wine-0.1"))
        #expect(!install.isUsable)
    }

    @Test("A runtime needs no license, but a CrossOver tree with a marker still does")
    func license() throws {
        let dir = try scratchDirectory("runtime-license")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.runtime(in: dir)
        #expect(CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)

        try FileManager.default.createDirectory(
            at: root.appending(path: "share/crossover/data"), withIntermediateDirectories: true)
        #expect(!WineRuntime.isRuntime(root))
        #expect(!CrossOverLicense.check(crossOverRoot: root, searchDirs: []).licensed)
    }

    @Test("A runtime clone verifies by its marker and loader, not by hashes")
    func verifiesClone() throws {
        let dir = try scratchDirectory("runtime-verify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.runtime(in: dir)
        let build = try #require(SupportedRunners.build(id: Self.runtimeID))

        try RunnerInstaller.verifyClone(build: build, root: root)

        try FileManager.default.removeItem(at: CrossOverSource.unixLoader(inRoot: root))
        #expect(throws: StepFailure.self) { try RunnerInstaller.verifyClone(build: build, root: root) }

        let other = try Self.runtime(id: "wine-0.1", in: dir.appending(path: "other"))
        #expect(throws: StepFailure.self) { try RunnerInstaller.verifyClone(build: build, root: other) }
    }

    @Test("Patching a runtime leaves its own lsteamclient and loader alone")
    func patchingSkipsRuntime() throws {
        let dir = try scratchDirectory("runtime-patch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.runtime(in: dir)
        let bridge = dir.appending(path: "bridge")
        let build = try #require(SupportedRunners.build(id: Self.runtimeID))
        let loader = CrossOverSource.unixLoader(inRoot: root)
        let before = try Data(contentsOf: loader)

        // An empty bridge would fail a CrossOver install, which copies lsteamclient from it.
        let outcome = try RunnerPatcher.install(build: build, root: root, bridge: bridge)
        #expect(outcome.wroteNothing)
        #expect(try Data(contentsOf: loader) == before)
        #expect(RunnerPatcher.verify(build: build, root: root, bridge: bridge).isEmpty)

        try FileManager.default.removeItem(at: root.appending(path: "lib/wine/x86_64-unix/lsteamclient.so"))
        #expect(RunnerPatcher.verify(build: build, root: root, bridge: bridge)
            == ["x86_64-unix/lsteamclient.so is missing"])
    }
}
