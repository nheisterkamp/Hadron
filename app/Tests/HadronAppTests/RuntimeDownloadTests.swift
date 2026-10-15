import Foundation
import Testing

@testable import HadronApp

@Suite("Runtime downloads")
struct RuntimeDownloadTests {

    private let sha = String(repeating: "ab", count: 32)

    @Test("The manifest lists supported runtimes under an https base")
    func parses() {
        let manifest = RuntimeDownloadManifest.parse("""
            # comment
            base     https://github.com/nheisterkamp/Hadron/releases/download/runtimes-1

            runtime  wine-11.19  hadron-wine-11.19.tar.xz  \(sha)  279000000
            runtime  wine-9.0    hadron-wine-9.0.tar.xz    \(sha)  1
            runtime  wine-11.15  ../evil.tar.xz            \(sha)  1
            runtime  wine-11.15  hadron-wine-11.15.tar.xz  short   1
            runtime  wine-11.19  hadron-again.tar.xz       \(sha)  1
            """)
        #expect(manifest.base?.host() == "github.com")
        #expect(manifest.runtimes.map(\.id) == ["wine-11.19"])
        #expect(manifest.runtimes.first?.bytes == 279_000_000)
    }

    @Test("Without an https base nothing is offered")
    func needsBase() {
        #expect(RuntimeDownloadManifest.parse("runtime  wine-11.19  a.tar.xz  \(sha)  1").runtimes.isEmpty)
        #expect(RuntimeDownloadManifest.parse("base http://example.com\nruntime  wine-11.19  a.tar.xz  \(sha)  1").runtimes.isEmpty)
    }

    @Test("The bundled manifest reads")
    func bundled() {
        let manifest = RuntimeDownloadManifest.bundled()
        #expect(manifest.base != nil || manifest.runtimes.isEmpty)
    }

    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A runtime as release.sh packs it: <id>/ with its marker and lib/wine.
    private func pack(_ id: String, marker: String, in work: URL) throws -> (URL, String, Int64) {
        let root = work.appending(path: "pack/\(id)")
        try FileManager.default.createDirectory(at: root.appending(path: "lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try marker.write(to: root.appending(path: "hadron-runtime"), atomically: true, encoding: .utf8)
        let archive = work.appending(path: "hadron-\(id).tar.xz")
        let packed = try Shell.run("/usr/bin/tar", ["-cJf", archive.path(percentEncoded: false),
                                                    "-C", work.appending(path: "pack").path(percentEncoded: false), id])
        #expect(packed.succeeded)
        let bytes = try FileManager.default.attributesOfItem(atPath: archive.path(percentEncoded: false))[.size] as! Int64
        return (archive, try #require(Digest.sha256IfPresent(archive)), bytes)
    }

    @Test("A download is checked and unpacked into runtimes/<id>")
    func downloads() async throws {
        let work = try scratch("runtime-download")
        defer { try? FileManager.default.removeItem(at: work) }
        let (archive, hash, bytes) = try pack("wine-11.19", marker: "wine-11.19\n", in: work)
        let download = RuntimeDownload(id: "wine-11.19", file: archive.lastPathComponent, sha256: hash, bytes: bytes)
        let runtimes = work.appending(path: "runtimes"), cache = work.appending(path: "cache")

        let install = try await RuntimeDownloader.run(download, from: work, into: runtimes, cache: cache)
        #expect(install.root.lastPathComponent == "wine-11.19")
        #expect(RuntimeSource.runtimeID(atRoot: runtimes.appending(path: "wine-11.19")) == "wine-11.19")
        let left = try FileManager.default.contentsOfDirectory(atPath: runtimes.path(percentEncoded: false))
        #expect(left == ["wine-11.19"], "the unpacking folder was left behind")
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: download.file).path(percentEncoded: false)))

        await #expect(throws: StepFailure.self, "a runtime that is already there is not replaced") {
            try await RuntimeDownloader.run(download, from: work, into: runtimes, cache: cache)
        }
    }

    @Test("A download that does not match its checksum, or holds another runtime, is refused")
    func refuses() async throws {
        let work = try scratch("runtime-refuse")
        defer { try? FileManager.default.removeItem(at: work) }
        let runtimes = work.appending(path: "runtimes"), cache = work.appending(path: "cache")
        let (archive, hash, bytes) = try pack("wine-11.15", marker: "wine-11.19\n", in: work)

        let wrongHash = RuntimeDownload(id: "wine-11.15", file: archive.lastPathComponent, sha256: sha, bytes: bytes)
        await #expect(throws: StepFailure.self) {
            try await RuntimeDownloader.run(wrongHash, from: work, into: runtimes, cache: cache)
        }
        let wrongMarker = RuntimeDownload(id: "wine-11.15", file: archive.lastPathComponent, sha256: hash, bytes: bytes)
        await #expect(throws: StepFailure.self) {
            try await RuntimeDownloader.run(wrongMarker, from: work, into: runtimes, cache: cache)
        }
        #expect(!FileManager.default.fileExists(atPath: runtimes.appending(path: "wine-11.15").path(percentEncoded: false)))
    }

    @Test("D3DMetal is found in a copy and laid out as the build does")
    func d3dmetal() throws {
        let work = try scratch("d3dmetal")
        defer { try? FileManager.default.removeItem(at: work) }
        let files = FileManager.default
        // Like the Game Porting Toolkit's redist/lib, a few levels down.
        let source = work.appending(path: "Game Porting Toolkit/redist/lib")
        for dir in ["external/D3DMetal.framework/Versions/A", "wine/x86_64-windows", "wine/x86_64-unix"] {
            try files.createDirectory(at: source.appending(path: dir), withIntermediateDirectories: true)
        }
        for file in ["external/libd3dshared.dylib", "wine/x86_64-windows/d3d11.dll", "wine/x86_64-windows/dxgi.dll",
                     "wine/x86_64-unix/d3d11.so", "wine/x86_64-unix/dxgi.so"] {
            files.createFile(atPath: source.appending(path: file).path(percentEncoded: false), contents: Data("x".utf8))
        }
        files.createFile(atPath: work.appending(path: "Game Porting Toolkit/License.rtf").path(percentEncoded: false), contents: Data())

        let found = try #require(D3DMetalImport.locate(in: work))
        #expect(found.standardizedFileURL == source.standardizedFileURL)

        let root = work.appending(path: "runtime")
        try files.createDirectory(at: root.appending(path: "lib/wine"), withIntermediateDirectories: true)
        #expect(!D3DMetalImport.isPresent(in: root))
        try D3DMetalImport.install(from: found, into: root)
        try D3DMetalImport.install(from: found, into: root)  // replacing works too

        let unix = D3DMetalImport.target(in: root).appending(path: "x86_64-unix")
        #expect(D3DMetalImport.isPresent(in: root))
        #expect(try files.destinationOfSymbolicLink(atPath: unix.appending(path: "dxgi.so").path(percentEncoded: false)) == "libd3dshared.dylib")
        #expect(files.fileExists(atPath: unix.appending(path: "D3DMetal.framework").path(percentEncoded: false)))
        #expect(files.fileExists(atPath: D3DMetalImport.target(in: root).appending(path: "x86_64-windows/d3d11.dll").path(percentEncoded: false)))
        #expect(files.fileExists(atPath: D3DMetalImport.target(in: root).appending(path: "License.rtf").path(percentEncoded: false)))
        #expect(try files.contentsOfDirectory(atPath: root.appending(path: "lib/graphics").path(percentEncoded: false)) == ["d3dmetal"])

        #expect(D3DMetalImport.accepts(try #require(SupportedRunners.build(id: "crossover-26.3"))))
        #expect(!D3DMetalImport.accepts(try #require(SupportedRunners.build(id: "wine-11.19"))))
    }
}

// Fetches a real archive from the published release, so it runs only on request:
// HADRON_LIVE_DOWNLOAD=1 swift test --filter liveRelease
@Suite("Runtime downloads, live")
struct LiveRuntimeDownloadTests {
    @Test("The bundled manifest's release downloads, checks and unpacks",
          .enabled(if: ProcessInfo.processInfo.environment["HADRON_LIVE_DOWNLOAD"] == "1"))
    func liveRelease() async throws {
        let manifest = RuntimeDownloadManifest.bundled()
        let base = try #require(manifest.base)
        let download = try #require(manifest.runtimes.min { $0.bytes < $1.bytes })
        let work = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let seen = Seen()
        let install = try await RuntimeDownloader.run(download, from: base, into: work.appending(path: "runtimes"),
                                                      cache: work.appending(path: "cache")) { seen.add($0.label) }
        #expect(RuntimeSource.runtimeID(atRoot: install.root) == download.id)
        #expect(seen.labels.contains { $0.contains("%") }, "no progress was reported")
        print("live: \(download.id) from \(base), \(seen.labels.count) progress labels, last \(seen.labels.last ?? "-")")
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ label: String) { lock.lock(); all.append(label); lock.unlock() }
        var labels: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }
}
