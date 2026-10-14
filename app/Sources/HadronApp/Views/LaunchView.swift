// The launch window: one game's start, as it happens or as it went.

import AppKit
import SwiftUI

struct LaunchView: View {

    let appID: String
    @Environment(LaunchMonitor.self) private var monitor
    @State private var log: LogKind = .launch
    @State private var lines: [String] = []

    enum LogKind: Hashable { case launch, wine }

    var body: some View {
        if let record = monitor.record(appID) {
            content(record)
                .task(id: "\(appID) \(log)") { await follow(record) }
        } else {
            ContentUnavailableView(String(localized: "No Launch"), systemImage: "gamecontroller")
        }
    }

    private func content(_ record: LaunchRecord) -> some View {
        let watch = monitor.watch(appID)
        return VStack(alignment: .leading, spacing: 12) {
            header(record, watch: watch)
            if monitor.looksStuck(record) { stuck }
            steps(record, watch: watch)
            if record.isLive, !watch.processes.isEmpty { processes(watch) }
            logs
            actions(record, watch: watch)
        }
        .padding(16)
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.title2.bold())
                Text(record.display ?? record.build).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(outcome(record, watch: watch))
                    .foregroundStyle(tone(record, watch: watch))
                Text(duration(from: record.started, to: record.isLive ? monitor.now : record.updated))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var stuck: some View {
        Label {
            Text(String(localized: "Nothing has happened for \(Int(LaunchMonitor.stuckAfter)) seconds and the game has no window yet. It may be stuck: stop it, or save diagnostics to see where it waits."))
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func steps(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> some View {
        let current = LaunchStage(step: record.step) ?? .runtime
        let stages = LaunchStage.allCases.filter { $0 != .conversion || record.converted }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(stages, id: \.self) { stage in
                let cleanExit = !record.isLive && record.state == .exited && (record.status ?? 0) == 0
                let done = stage < current || cleanExit || (stage == .game && watch.windowSeen != nil)
                let active = stage == current && record.isLive && !done
                let failed = stage == current && !record.isLive && !done
                HStack(spacing: 8) {
                    Group {
                        if active {
                            ProgressView().controlSize(.small)
                        } else if done {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if failed {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16)
                    Text(stage == .game && watch.windowSeen != nil ? String(localized: "Game window open") : stage.label)
                        .foregroundStyle(done || active ? .primary : .secondary)
                    if active {
                        Text(duration(from: record.stepStarted, to: monitor.now))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func processes(_ watch: LaunchMonitor.Watch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "Windows processes")).font(.headline)
                Spacer()
                Text(String(localized: "CPU \(Int(watch.cpu.rounded()))%"))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Text(watch.processes.map(\.name).joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(String(localized: "Log"), selection: $log) {
                Text(String(localized: "Launch Log")).tag(LogKind.launch)
                Text(String(localized: "Wine Log")).tag(LogKind.wine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 160, maxHeight: .infinity)
                .onChange(of: lines) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private func actions(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> some View {
        HStack {
            Button(String(localized: "Open Log")) {
                NSWorkspace.shared.open(log == .launch ? record.log : record.wineLog)
            }
            Button(String(localized: "Save Diagnostics…")) { monitor.saveDiagnostics(record) }
            Spacer()
            if record.isLive {
                Button(String(localized: "Stop Game"), role: .destructive) { monitor.stop(record) }
                    .disabled(watch.stopping)
            }
        }
    }

    private func follow(_ record: LaunchRecord) async {
        let url = log == .launch ? record.log : record.wineLog
        while !Task.isCancelled {
            let fresh = await Task.detached(priority: .utility) { LogTail.lines(of: url) }.value
            if fresh != lines { lines = fresh }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func outcome(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> String {
        switch record.state {
        case _ where record.isLive && watch.windowSeen != nil: String(localized: "Running")
        case _ where record.isLive && watch.stopping: String(localized: "Stopping")
        case _ where record.isLive: String(localized: "Starting")
        case .failed: String(localized: "Did not start (exit \(record.status ?? 0))")
        case .exited where record.status ?? 0 != 0: String(localized: "Exited with status \(record.status ?? 0)")
        case .exited: String(localized: "Exited")
        default: String(localized: "Cut off")
        }
    }

    private func tone(_ record: LaunchRecord, watch: LaunchMonitor.Watch) -> Color {
        if record.isLive { return watch.windowSeen != nil ? .green : .secondary }
        return record.state == .exited && (record.status ?? 0) == 0 ? .secondary : .red
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(Int(end.timeIntervalSince(start)), 0)
        return seconds >= 60 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds) s"
    }
}

// The floating windows, one per launch, kept above other apps without taking focus.
@MainActor
final class LaunchPanels: NSObject, NSWindowDelegate {

    private var panels: [String: NSPanel] = [:]
    private weak var monitor: LaunchMonitor?

    var open: [String] { Array(panels.keys) }

    func show(_ appID: String, monitor: LaunchMonitor) {
        self.monitor = monitor
        if let panel = panels[appID] {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = monitor.record(appID)?.title ?? String(localized: "Launch")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: LaunchView(appID: appID).environment(monitor))
        panel.delegate = self
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - panel.frame.width - 24,
                                         y: screen.maxY - panel.frame.height - 24))
        }
        panels[appID] = panel
        panel.orderFrontRegardless()
    }

    func close(_ appID: String, after seconds: Double) {
        guard panels[appID] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.panels[appID]?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
            let appID = panels.first(where: { $0.value === panel })?.key
        else { return }
        panels[appID] = nil
        monitor?.panelClosed(appID)
    }
}
