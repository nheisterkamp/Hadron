// Follows games as they start, from the records compat_run.sh writes, and shows the
// launch window for a new one.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LaunchMonitor {

    // What the window knows about one launch beyond its record.
    struct Watch: Equatable {
        var processes: [WineProcess] = []
        // Percent of one core, all processes together.
        var cpu: Double = 0
        var windowSeen: Date?
        var quietSince: Date?
        var stopping = false
    }

    // Set when Hadron started only to show the launch window.
    nonisolated(unsafe) static var launchedForWindow = false

    // Seconds without a window and without CPU before the window says the game looks stuck.
    static let stuckAfter: TimeInterval = 30

    private(set) var records: [LaunchRecord] = []
    private(set) var watches: [String: Watch] = [:]
    private(set) var now = Date()
    var showWindow = LaunchWindowSetting.isOn() {
        didSet { LaunchWindowSetting.set(showWindow) }
    }

    private var seen: [String: Date] = [:]
    private var lastCPU: [Int32: Double] = [:]
    private var lastScan = Date()
    private var timer: Timer?
    private var scanning = false
    private let panels = LaunchPanels()
    private let startedAt = Date()

    init() {
        // Records already there belong to launches from before; a launch that is still
        // starting when Hadron comes up is the one it was opened for.
        for record in LaunchStore.records() where !(record.isLive && Self.launchedForWindow) {
            seen[record.appID] = record.started
        }
        records = LaunchStore.records()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.async { [weak self] in self?.tick() }
    }

    func record(_ appID: String) -> LaunchRecord? {
        records.first { $0.appID == appID }
    }

    func watch(_ appID: String) -> Watch {
        watches[appID] ?? Watch()
    }

    func looksStuck(_ record: LaunchRecord) -> Bool {
        guard record.isLive, record.state == .running else { return false }
        let watch = watch(record.appID)
        guard watch.windowSeen == nil, let quiet = watch.quietSince else { return false }
        return now.timeIntervalSince(quiet) >= Self.stuckAfter
    }

    private func tick() {
        now = Date()
        let fresh = LaunchStore.records()
        if fresh != records { records = fresh }

        for record in fresh where seen[record.appID] != record.started {
            seen[record.appID] = record.started
            watches[record.appID] = Watch()
            if record.isLive, showWindow { panels.show(record.appID, monitor: self) }
        }
        for appID in panels.open where record(appID)?.isLive != true {
            if watch(appID).windowSeen != nil { panels.close(appID, after: 2) }
        }
        scan()
    }

    // Processes and windows for the live launches, off the main thread.
    private func scan() {
        let live = records.filter(\.isLive)
        guard !live.isEmpty, !scanning else { return }
        scanning = true
        let targets = live.map { ($0.appID, $0.prefix, $0.install) }
        Task.detached(priority: .utility) {
            var found: [String: ([WineProcess], Bool)] = [:]
            for (appID, prefix, install) in targets {
                let processes = WineProcesses.scan(prefix: prefix, install: install)
                found[appID] = (processes, WineProcesses.hasWindow(pids: Set(processes.map(\.pid))))
            }
            await MainActor.run { [found] in self.apply(found) }
        }
    }

    private func apply(_ found: [String: ([WineProcess], Bool)]) {
        scanning = false
        let elapsed = max(now.timeIntervalSince(lastScan), 0.5)
        lastScan = now
        var cpuNow: [Int32: Double] = [:]
        for (appID, (processes, window)) in found {
            var watch = watches[appID] ?? Watch()
            var used = 0.0
            for process in processes {
                cpuNow[process.pid] = process.cpuTime
                if let before = lastCPU[process.pid] { used += max(process.cpuTime - before, 0) }
            }
            watch.processes = processes
            watch.cpu = used / elapsed * 100
            if window, watch.windowSeen == nil {
                watch.windowSeen = now
                panels.close(appID, after: 3)
            }
            if watch.cpu < 3, !processes.isEmpty {
                if watch.quietSince == nil { watch.quietSince = now }
            } else {
                watch.quietSince = nil
            }
            watches[appID] = watch
        }
        lastCPU = cpuNow
    }

    // MARK: Actions

    func stop(_ record: LaunchRecord) {
        watches[record.appID, default: Watch()].stopping = true
        let server = SupportPaths.runnerRoot(forBuild: record.build).appending(path: "bin/wineserver")
        let prefix = record.prefix.path(percentEncoded: false)
        Task.detached {
            var environment = ProcessInfo.processInfo.environment
            environment["WINEPREFIX"] = prefix
            _ = try? Shell.run(server.path(percentEncoded: false), ["-k"], environment: environment)
        }
    }

    func showPanel(_ appID: String) {
        panels.show(appID, monitor: self)
    }

    func panelClosed(_ appID: String) {
        guard Self.launchedForWindow, panels.open.isEmpty,
            !NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) })
        else { return }
        // Hadron came up for this window alone; it goes again with it.
        NSApp.terminate(nil)
    }

    func saveDiagnostics(_ record: LaunchRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Hadron \(record.title) \(Self.stamp.string(from: now)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let watch = watch(record.appID)
        Task.detached(priority: .userInitiated) {
            let text = Diagnostics.report(record, watch: watch)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

enum Diagnostics {

    static func report(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> String {
        var out = "Hadron launch diagnostics, \(Date())\n\n"
        out += "game: \(record.title) (\(record.appID))\n"
        out += "runtime: \(record.display ?? record.build) (\(record.build))\n"
        out += "state: \(record.state.rawValue), step: \(record.step), status: \(record.status.map(String.init) ?? "-")\n"
        out += "started: \(record.started), window seen: \(watch.windowSeen.map { "\($0)" } ?? "no")\n\n"
        out += "== processes (CPU seconds)\n"
        for process in watch.processes {
            out += String(format: "%6d %9.2f  ", process.pid, process.cpuTime) + process.commandLine + "\n"
        }
        // Where each thread waits, which is what a hang needs.
        for process in watch.processes {
            out += "\n== sample of \(process.pid) \(process.name)\n"
            if let result = try? Shell.run("/usr/bin/sample", ["\(process.pid)", "2"], drainTimeout: .seconds(10)) {
                out += result.stdout
            }
        }
        out += "\n== launch log\n" + LogTail.lines(of: record.log, max: 400).joined(separator: "\n") + "\n"
        out += "\n== wine log\n" + LogTail.lines(of: record.wineLog, max: 400).joined(separator: "\n") + "\n"
        return out
    }
}
