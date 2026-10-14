import Foundation
import Testing

@testable import HadronApp

@Suite("Launch records")
struct LaunchRecordTests {

    private static func compatSource() throws -> String {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()  // HadronAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // app
            .deletingLastPathComponent()  // repo root
        return try String(
            contentsOf: repoRoot.appending(path: "dylib/feats/compat_run.sh"), encoding: .utf8)
    }

    private let sample = """
        app=2225070
        name=Trackmania
        build=wine-11.19-fex
        display=Hadron Wine 11.19 (Apple Silicon)
        compatdata=/Users/tester/Library/Application Support/Steam/steamapps/compatdata/2225070
        install=/Users/tester/Library/Application Support/Steam/steamapps/common/Trackmania
        log=/Users/tester/Library/Application Support/Steam/steamapps/compatdata/2225070/hadron-run.log
        pid=4242
        started=1791970000
        updated=1791970030
        step=prefix conversion
        step_started=1791970010
        state=starting
        status=
        converted=1

        """

    @Test("A record reads back what the run script writes")
    func parses() throws {
        let record = try #require(LaunchRecord(text: sample))
        #expect(record.appID == "2225070")
        #expect(record.title == "Trackmania")
        #expect(record.build == "wine-11.19-fex")
        #expect(record.display == "Hadron Wine 11.19 (Apple Silicon)")
        #expect(record.prefix.path(percentEncoded: false).hasSuffix("compatdata/2225070/pfx"))
        #expect(record.install?.lastPathComponent == "Trackmania")
        #expect(record.pid == 4242)
        #expect(record.started == Date(timeIntervalSince1970: 1_791_970_000))
        #expect(record.stepStarted == Date(timeIntervalSince1970: 1_791_970_010))
        #expect(record.state == .starting)
        #expect(record.status == nil)
        #expect(record.converted)
        #expect(LaunchStage(step: record.step) == .conversion)
    }

    @Test("A record without the fields that place it is refused")
    func refusesBroken() {
        #expect(LaunchRecord(text: "") == nil)
        #expect(LaunchRecord(text: sample.replacingOccurrences(of: "app=2225070", with: "app=../x")) == nil)
        #expect(LaunchRecord(text: sample.replacingOccurrences(of: "state=starting", with: "state=odd")) == nil)
    }

    @Test("A record whose script is gone is not live")
    func deadScript() throws {
        let gone = sample.replacingOccurrences(of: "pid=4242", with: "pid=\(Int32.max)")
        #expect(try #require(LaunchRecord(text: gone)).isLive == false)
        let mine = sample.replacingOccurrences(of: "pid=4242", with: "pid=\(getpid())")
        #expect(try #require(LaunchRecord(text: mine)).isLive)
        let exited = mine.replacingOccurrences(of: "state=starting", with: "state=exited")
        #expect(try #require(LaunchRecord(text: exited)).isLive == false)
    }

    @Test("Every step the run script names belongs to a stage")
    func stepsHaveStages() throws {
        let source = try Self.compatSource()
        let steps = source.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set_stage \""), trimmed.hasSuffix("\"") else { return nil }
            return String(trimmed.dropFirst("set_stage \"".count).dropLast())
        }
        #expect(steps.count > 8)
        for step in steps + ["startup"] {
            #expect(LaunchStage(step: step) != nil, "no stage for \(step)")
        }
        #expect(source.contains(#"launch_record="$np_support/launches/$app_id""#))
        #expect(source.contains(#"[ ! -e "$np_support/launch-window-off" ]"#))
    }

    @Test("The window setting is a marker file the run script checks")
    func setting() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "launch-setting-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(LaunchWindowSetting.isOn(support: support))
        LaunchWindowSetting.set(false, support: support)
        #expect(LaunchWindowSetting.marker(in: support).lastPathComponent == "launch-window-off")
        #expect(!LaunchWindowSetting.isOn(support: support))
        LaunchWindowSetting.set(true, support: support)
        #expect(LaunchWindowSetting.isOn(support: support))
    }

    @Test("Records are read newest first, and stray files are skipped")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "launches-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try sample.write(to: dir.appending(path: "2225070"), atomically: true, encoding: .utf8)
        let newer = sample.replacingOccurrences(of: "app=2225070", with: "app=480")
            .replacingOccurrences(of: "started=1791970000", with: "started=1791980000")
        try newer.write(to: dir.appending(path: "480"), atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appending(path: "480.new"), atomically: true, encoding: .utf8)
        #expect(LaunchStore.records(in: dir).map(\.appID) == ["480", "2225070"])
    }

    @Test("A Windows process is named after its program")
    func processName() {
        #expect(WineProcess(pid: 1, commandLine: #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\upc.exe -upc_uplay_id 7015"#, cpuTime: 0).name == "upc.exe")
        #expect(WineProcess(pid: 1, commandLine: #""C:\Games\My Game\game.exe" -x"#, cpuTime: 0).name == "game.exe")
        #expect(WineProcess(pid: 1, commandLine: "", cpuTime: 0).name == "")
    }
}
