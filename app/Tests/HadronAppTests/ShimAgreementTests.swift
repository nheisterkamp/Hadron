import Foundation
import Testing

@testable import HadronApp

// The app writes the runner and RUN_SCRIPT reads it back, in two languages nothing at build
// time holds together, so a file the shim never checks goes stale. Both lists are parsed out.
@Suite("Shim agreement")
struct ShimAgreementTests {

    private static func runScript() throws -> String {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repo.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
    }

    private static func verifyRunnerBlock() throws -> String {
        let script = try runScript()
        let start = try #require(script.range(of: "verify_runner() {"))
        let rest = script[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"))
        return String(rest[..<end.lowerBound])
    }

    // Each loop the shim runs over an arch list, in the order they appear.
    private static func archLists(in block: String) -> [Set<String>] {
        block.split(separator: "\n").compactMap { line in
            guard let marker = line.range(of: "for arch in ") else { return nil }
            let tail = line[marker.upperBound...]
            guard let semicolon = tail.firstIndex(of: ";") else { return nil }
            return Set(tail[..<semicolon].split(separator: " ").map(String.init))
        }
    }

    @Test("The shim checks the builtins the app checks")
    func builtinsAgree() throws {
        let block = try Self.verifyRunnerBlock()
        let lists = Self.archLists(in: block)

        #expect(lists.count == 1)

        // The windows halves are named literally. The unix one is whichever arch directory the
        // loader turned up in, so both sides resolve that rather than naming a fixed arch.
        let arches = try #require(lists.first)
        let unix = "\"${wine_unix##*/}\""
        #expect(arches.contains(unix))
        let windows = RunnerInstaller.builtins.filter { $0.arch.hasSuffix("-windows") }
        #expect(arches.subtracting([unix]) == Set(windows.map(\.arch)))

        for builtin in RunnerInstaller.builtins {
            #expect(block.contains(builtin.name))
        }
        #expect(block.contains("$np_root/lib/wine/$arch/$name"))
    }

    @Test("The shim's unix arch is the one the app checks and loads from")
    func unixArchAgrees() throws {
        let script = try Self.runScript()
        let unix = try #require(RunnerInstaller.builtins.first { $0.arch.hasSuffix("-unix") })
        #expect(script.contains("wine_unix=\"$np_root/lib/wine/\(unix.arch)\""))
        #expect(RuntimeSource.unixLoader(inRoot: URL(filePath: "/R")).path(percentEncoded: false)
            == "/R/lib/wine/\(unix.arch)/wine")
    }

    // A runner write left in the shim is the layout problem coming back: writing into the
    // runner at launch is what failed silently when it needed a permission Steam lacks.
    @Test("The shim no longer writes into the runner")
    func shimOnlyReadsTheRunner() throws {
        let script = try Self.runScript()
        for line in script.split(separator: "\n") {
            let writes = line.contains("cp -f") || line.contains("codesign ")
            guard writes, line.contains("$np_root") else { continue }
            Issue.record("RUN_SCRIPT writes into the runner: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}
