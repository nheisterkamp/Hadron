// Logic behind Status view

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum AppVersion {
    static let fallback = "0.1.0-dev"

    static var bundled: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? fallback
    }
}

struct StatusSnapshot: Sendable {
    var steam: SteamDeployment
    var steamRunning: Bool
    var updateBlocked: Bool
    var runtimes: [RuntimeInstall]
    var runner: RunnerState
    var payload: PayloadState
    var installedRunners: [RunnerBuild] = []
    var orphanedRunners: [String] = []
    var damagedRunners: [String] = []
    var installContent: DeploymentContent.Status = .unchecked

    static func capture(bundledVersion: String) -> StatusSnapshot {
        let runner = RunnerStore.state()
        let installed = RunnerStore.installedBuilds()

        return StatusSnapshot(
            steam: SteamBundle.deployment(bundledVersion: bundledVersion),
            steamRunning: SteamBundle.isRunning,
            updateBlocked: UpdateBlock.isPresent(),
            runtimes: RuntimeSource.discover(),
            runner: runner,
            payload: PayloadInspector.inspect(),
            installedRunners: installed,
            orphanedRunners: RunnerStore.orphanedClones(),
            damagedRunners: RunnerStore.damagedClones(),
            installContent: DeploymentContent.current(version: bundledVersion)
        )
    }
}

@MainActor
@Observable
final class SystemStatus {

    var snapshot: StatusSnapshot?
    var isRefreshing = false
    var activity: String?
    var outcome: String?
    private(set) var highlightedRow: String?
    @ObservationIgnored private var highlightReset: Task<Void, Never>?
    private(set) var failure: String?
    private(set) var failureRemedy: Remedy?

    private var runInFlight = false
    // Tests replace the refresh so a run does not modify the real Steam/support folders
    // if run on an actual user's machine.
    @ObservationIgnored var refreshAfterRun: @MainActor (SystemStatus) async -> Void = { await $0.refresh() }
    var isBusy: Bool { activity != nil || runInFlight }
    var isIdle: Bool { !isBusy && !isRefreshing }
    var canInstall: Bool { isIdle && snapshot?.installContent.blocksInstallation != true }

    enum Confirmation: Identifiable, Hashable {
        case replaceSteam
        case blockUpdates
        case removeBuild
        case removeEverything

        var id: Self { self }
    }

    var pendingConfirmation: Confirmation?
    var generation = 0

    func beginRun(_ label: String) -> Int {
        activity = label
        AppLog.note("run begin: \(label)")
        return generation
    }

    func report(_ run: Int, _ label: String) {
        guard run == generation else { return }
        activity = label
        AppLog.note("run step: \(label)")
    }

    func endRun() {
        generation += 1
        activity = nil
        AppLog.note("run end\(failure == nil ? "" : " (failed)")")
    }

    private func record(_ error: Error) {
        setFailure(error)
        if let refusal = error as? WriteRefused {
            AppLog.note("run failed: cannot write \(refusal.path)")
        } else {
            AppLog.note("run failed: \(error.localizedDescription)")
        }
    }

    func setFailure(_ message: String) {
        failure = message
        failureRemedy = nil
    }

    func setFailure(_ error: Error) {
        let report = FailureReport([error])
        failure = report?.message
        failureRemedy = report?.remedy
    }

    func clearFailure() {
        failure = nil
        failureRemedy = nil
    }

    var usableRuntime: RuntimeInstall? {
        snapshot?.runtimes.first(where: \.isUsable)
    }

    var usableRuntimes: [RuntimeInstall] {
        snapshot?.runtimes.filter(\.isUsable) ?? []
    }

    var runtimeRows: [RuntimeRow] {
        guard let snapshot else { return [] }
        var incomplete: [String] = []
        if case .incomplete(let builds, _) = snapshot.runner { incomplete = builds }
        return RuntimeRow.rows(
            installs: snapshot.runtimes,
            installed: snapshot.installedRunners,
            damaged: snapshot.damagedRunners,
            orphaned: snapshot.orphanedRunners,
            incomplete: incomplete
        )
    }

    var repairSource: RuntimeInstall? {
        let builds = snapshot?.runner.builds ?? []
        for wanted in builds {
            let found = usableRuntimes.first { install in
                if case .supported(let build) = install.support { return build.id == wanted }
                return false
            }
            if let found { return found }
        }
        return nil
    }

    var setupSource: RuntimeInstall? { repairSource ?? usableRuntime }

    func requestInstall() async {
        guard canInstall else { return }
        await installIntoSteam()
    }

    func requestCompatibilityTool(
        from chosen: RuntimeInstall? = nil, replacingExisting: Bool = false
    ) async {
        guard canInstall else { return }
        await setUpRunner(from: chosen ?? setupSource, replacingExisting: replacingExisting)
    }

    private(set) var pendingRemoval: String?

    func requestBuildRemoval(_ build: String) {
        guard canInstall else { return }
        pendingRemoval = build
        pendingConfirmation = .removeBuild
    }

    func cancelBuildRemoval() {
        pendingRemoval = nil
    }

    func removePendingBuild() async {
        guard let build = pendingRemoval else { return }
        pendingRemoval = nil
        await perform(from: RunnerInstaller.removeStep) { _ in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireUnblockedContent()
            let changed = try await Task.detached(priority: .userInitiated) {
                try RunnerInstaller.removeClone(forBuild: build)
            }.value
            let removed = String(localized: "Removed build \(SupportedRunners.displayVersion(forID: build)).")
            return changed && SteamBundle.isRunning ? "\(removed) \(Self.toolsRestartHint)" : removed
        }
    }

    // Runtimes in the bundled manifest that this Mac has neither as a folder nor a copy.
    var downloadableRuntimes: [RuntimeDownload] {
        guard snapshot != nil, downloads.base != nil else { return [] }
        // The rows cover runtime folders and installed copies alike.
        let present = Set(runtimeRows.map(\.buildID))
        return downloads.runtimes.filter { !present.contains($0.id) }
    }

    @ObservationIgnored let downloads = RuntimeDownloadManifest.bundled()

    // Downloads a runtime and sets up its compatibility tool, as Set Up does for a folder.
    func downloadRuntime(_ download: RuntimeDownload) async {
        guard canInstall, let base = downloads.base else { return }
        await perform(from: RuntimeDownloader.Phase.downloading(name: download.build?.releaseVersion ?? download.id, fraction: nil).label) { progress in
            let install = try await RuntimeDownloader.run(download, from: base) { progress($0.label) }
            AppLog.note("runtime downloaded: \(download.id)")
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install) { progress($0.label) }
            }.value
            return runnerOutcome(result)
        }
    }

    // Adds D3DMetal from the user's own copy to the runtime folder and its installed copy.
    func addD3DMetal(_ row: RuntimeRow) async {
        guard let build = row.build, D3DMetalImport.accepts(build) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Select Apple's Game Porting Toolkit, CrossOver, or a folder with D3DMetal in it.")
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        await perform(from: String(localized: "Adding D3DMetal")) { _ in
            try await Task.detached(priority: .userInitiated) {
                guard let source = D3DMetalImport.locate(in: picked) else {
                    throw StepFailure(step: D3DMetalImport.step, detail: String(localized: "No D3DMetal was found in \(picked.lastPathComponent)."))
                }
                var roots = [SupportPaths.runnerRoot(forBuild: build.id)]
                if let folder = row.install?.root { roots.append(folder) }
                for root in roots where FileManager.default.fileExists(atPath: root.appending(path: "lib/wine").path(percentEncoded: false)) {
                    try D3DMetalImport.install(from: source, into: root)
                }
                AppLog.note("d3dmetal added to \(build.id) from \(source.path(percentEncoded: false))")
            }.value
            return String(localized: "D3DMetal added. Pick it for a game in the game's Hadron settings.")
        }
    }

    func addRuntime() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Select a Hadron Wine runtime folder.")

        guard panel.runModal() == .OK, let picked = panel.url else { return }

        clearFailure()
        outcome = nil

        guard RuntimeSource.looksLikeRuntime(picked) else {
            setFailure(String(localized: "\(picked.lastPathComponent) is not a Hadron Wine runtime."))
            AppLog.note("runtime choice refused: \(picked.path(percentEncoded: false))")
            return
        }

        await refresh()
        if let row = RuntimeRow.listing(RuntimeSource.inspect(root: picked), in: runtimeRows) {
            AppLog.note("runtime already listed: \(picked.path(percentEncoded: false))")
            highlight(row)
            return
        }
        RuntimeSource.addManualRoot(picked)
        AppLog.note("runtime added: \(picked.path(percentEncoded: false))")
        await refresh()
    }

    func chooseSteam() async {
        let current = SupportPaths.Steam.app
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Select your copy of Steam.")
        panel.directoryURL = current.deletingLastPathComponent()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let picked = URL(filePath: url.path)

        clearFailure()
        outcome = nil

        func same(_ a: URL, _ b: URL) -> Bool {
            a.standardizedFileURL.path(percentEncoded: false) == b.standardizedFileURL.path(percentEncoded: false)
        }
        guard !same(picked, current) else { return }
        if SupportPaths.Steam.isUnreachable(current) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Steam at \(current.path(percentEncoded: false)) isn't connected.")
            alert.informativeText = String(localized: "If Hadron is installed there, it will stay installed. Continue anyway?")
            alert.addButton(withTitle: String(localized: "Continue Anyway"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let lock: DeploymentContent.InstallationLock
        do {
            lock = try DeploymentContent.acquireInstallationLock()
        } catch {
            setFailure(error)
            return
        }
        if let refusal = Self.steamChoiceRefusal(picked, current: current) {
            lock.release()
            setFailure(refusal)
            AppLog.note("steam choice refused: \(picked.path(percentEncoded: false))")
            return
        }

        if same(picked, SupportPaths.Steam.defaultApp) {
            UserDefaults.standard.removeObject(forKey: SupportPaths.Steam.appPathKey)
        } else {
            UserDefaults.standard.set(picked.path(percentEncoded: false), forKey: SupportPaths.Steam.appPathKey)
        }
        lock.release()
        AppLog.note("steam chosen: \(picked.path(percentEncoded: false))")
        await refresh()
    }

    static func steamChoiceRefusal(
        _ picked: URL, current: URL, insert: String? = SteamBundle.currentInsert()
    ) -> String? {
        guard Bundle(url: picked)?.bundleIdentifier == SteamRepair.valveIdentifier else {
            return String(localized: "\(picked.lastPathComponent) is not Steam.")
        }
        guard !picked.path(percentEncoded: false).contains(":") else {
            return String(localized: "Hadron cannot use Steam from a folder with a colon in its name.")
        }
        let deployed = SupportPaths.Steam.deployedDylib(inBundle: current).path(percentEncoded: false)
        if let insert, insert.split(separator: ":").contains(Substring(deployed)) {
            return String(localized: "Hadron is installed in \(current.path(percentEncoded: false)). Use Repair Steam to remove it before choosing another copy of Steam.")
        }
        return nil
    }

    private func highlight(_ row: RuntimeRow) {
        AccessibilityNotification.Announcement(String(localized: "\(row.title) is already listed.")).post()
        highlightReset?.cancel()
        highlightedRow = row.id
        highlightReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.highlightedRow = nil
        }
    }

    func removeFromList(_ install: RuntimeInstall) async {
        guard isIdle else { return }
        clearFailure()
        outcome = nil
        RuntimeSource.removeManualRoot(install.root)
        AppLog.note("runtime removed from list: \(install.id)")
        await refresh()
    }

    private static let toolsRestartHint = String(localized: "Restart Steam to update its list of compatibility tools.")

    private func runnerOutcome(_ result: RunnerSetup.Outcome) -> String {
        if result.stagedNothing { return String(localized: "Compatibility tool is already set up.") }
        guard result.toolsChanged, SteamBundle.isRunning else { return String(localized: "Compatibility tool ready.") }
        return String(localized: "Compatibility tool ready. \(Self.toolsRestartHint)")
    }

    func perform(
        from first: String,
        _ body: (_ progress: @escaping @Sendable (String) -> Void) async throws -> String?
    ) async {
        guard !runInFlight else {
            AppLog.note("run refused: '\(first)' overlaps a run already in flight")
            return
        }
        runInFlight = true
        defer { runInFlight = false }

        clearFailure()
        outcome = nil
        let run = beginRun(first)
        defer { endRun() }

        do {
            outcome = try await body { label in
                Task { @MainActor in self.report(run, label) }
            }
        } catch {
            record(error)
        }

        await refreshAfterRun(self)
    }

    private func setUpRunner(from install: RuntimeInstall?, replacingExisting: Bool = false) async {
        guard let install else {
            setFailure(String(localized: "No Hadron Wine runtime found."))
            AppLog.note("run refused: no supported runtime")
            outcome = nil
            return
        }

        await perform(from: RunnerSetup.Phase.copying.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await Task.detached(priority: .userInitiated) {
                try RunnerSetup.run(from: install, replacingExisting: replacingExisting) {
                    progress($0.label)
                }
            }.value

            return runnerOutcome(result)
        }
    }

    func fetchValveBinaries() async {
        guard canInstall else { return }
        await perform(from: ValveFetcher.Phase.verifying.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            try await requireInstallableContent()
            let result = try await ValveFetcher.run { progress($0.label) }
            return result.wroteNothing ? nil : String(localized: "Downloaded missing components.")
        }
    }

    private static let restartHint = String(localized: "Steam was stopped, so start it again.")

    private func requireInstallableContent() async throws {
        try await requireUnblockedContent()
        let running = await Task.detached(priority: .utility) {
            RunnerStore.clonedBuilds().contains {
                RunnerInstaller.isRunning(from: SupportPaths.runnerRoot(forBuild: $0))
            }
        }.value
        guard !running else {
            throw StepFailure(step: SteamInstaller.step, detail: String(localized: "A game or Wine tool is running. Quit it before updating Hadron."))
        }
    }

    private func requireUnblockedContent() async throws {
        let version = AppVersion.bundled
        let content = await Task.detached(priority: .utility) {
            DeploymentContent.current(version: version)
        }.value
        snapshot?.installContent = content
        guard !content.blocksInstallation else {
            throw StepFailure(step: SteamInstaller.step,
                              detail: String(localized: "Installation is blocked. Refresh Status and use the Hadron app that installed this build."))
        }
    }

    func installIntoSteam() async {
        await perform(from: InstallPhase.checkingPayload.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.run(holdingInstallationLock: true, report: { progress($0.label) })
            }.value

            var parts = [String(localized: "Hadron successfully installed.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            let runner = await Task.detached(priority: .userInitiated) { RunnerStore.state() }.value
            if let install = usableRuntime, runner == .none {
                progress(String(localized: "Setting up compatibility tool"))
                // A tool that came up is the expected case and goes unsaid. Failure throws.
                _ = try await Task.detached(priority: .userInitiated) {
                    try RunnerSetup.run(from: install) { progress($0.label) }
                }.value
            }

            // Fetch binaries from Valve
            let valve = try ValvePackageManifest.bundled()
            let needsValve = await Task.detached(priority: .utility) {
                valve.files.contains { Digest.sha256IfPresent(SupportPaths.bridge.appending(path: $0.bridgePath)) != $0.sha256 }
            }.value
            if needsValve {
                progress(String(localized: "Downloading missing components"))
                _ = try await ValveFetcher.run { progress($0.label) }
            }

            try await Task.detached(priority: .userInitiated) {
                try SteamInstaller.finish(result)
            }.value

            return parts.joined(separator: " ")
        }
    }

    func setUpdateBlock(_ blocked: Bool) async {
        await perform(from: blocked ? String(localized: "Blocking Steam client updates")
                                    : String(localized: "Allowing Steam client updates")) { _ in
            if blocked {
                try UpdateBlock.write()
                return String(localized: "Steam client updates are blocked.")
            }

            try UpdateBlock.remove()
            return String(localized: "Steam client updates are allowed.")
        }
    }

    func repairSteam() async {
        await perform(from: RepairPhase.checking.label) { progress in
            let lock = try DeploymentContent.acquireInstallationLock()
            defer { lock.release() }
            let result = try await SteamRepair.run(report: { progress($0.label) })

            var parts = [String(localized: "Steam restored to its original state.")]
            if result.stoppedClient { parts.append(Self.restartHint) }
            return parts.joined(separator: " ")
        }
    }

    func resetControllerPermission() async {
        await perform(from: String(localized: "Resetting Steam's controller permission")) { _ in
            let failed = SteamInstaller.failedInputAccessResets()
            guard failed.isEmpty else {
                throw StepFailure(
                    step: String(localized: "Reset controller permission"),
                    detail: String(localized: "macOS did not reset \(failed.joined(separator: ", ")) for Steam.")
                )
            }
            return SteamBundle.isRunning
                ? String(localized: "Controller permission reset. Restart Steam so macOS asks again.")
                : String(localized: "Controller permission reset. macOS asks again when Steam starts.")
        }
    }

    func removeEverything() async {
        await perform(from: UninstallPhase.stoppingClient.label) { progress in
            let result = try await Uninstall.run { progress($0.label) }

            if let partial = result.partialRemoval { return partial }
            return result.steamNeedsRedownload
                ? String(localized: "Hadron has been removed. Steam could not be restored. Reinstall Steam from steampowered.com before using it again.")
                : String(localized: "Hadron has been removed.")
        }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let version = AppVersion.bundled
        let captured = await Task.detached(priority: .userInitiated) {
            StatusSnapshot.capture(bundledVersion: version)
        }.value
        snapshot = captured
        AppLog.note(captured)
        await refreshRunnerStorage(cleanTemplates: !captured.installContent.blocksInstallation)
    }

    private(set) var runnerSizes: [String: Int64] = [:]
    private(set) var templateSizes: [String: [CompatTool.Flavor: Int64]] = [:]
    private(set) var templateCleanupFailure: String?
    private(set) var bridgeCopyBytes: Int64 = 0

    func refreshRunnerStorage(
        runners: URL = SupportPaths.runners, libraries: [SteamLibrary] = PrefixStore.libraries(),
        cleanTemplates: Bool = true
    ) async {
        let known = runnerSizes
        let measured = await Task.detached(priority: .utility) {
            if cleanTemplates, let lock = try? DeploymentContent.acquireInstallationLock() {
                RunnerInstaller.removeLeftoverRemovals(runners: runners)
                lock.release()
            }
            let failures = cleanTemplates
                ? RunnerInstaller.removeStalePrefixTemplates(runners: runners, libraries: libraries, reportBusy: false) : []
            var sizes: [String: Int64] = [:]
            var templates: [String: [CompatTool.Flavor: Int64]] = [:]
            let bridgeCopies = libraries.reduce(Int64(0)) { total, library in
                let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                var info = stat()
                guard lstat(folder.path(percentEncoded: false), &info) == 0,
                    info.st_mode & S_IFMT == S_IFDIR else { return total }
                return total + PrefixStore.directoryBytes(
                    folder.appending(path: SupportPaths.bridgeCacheFolder), metric: .allocated)
            }
            for build in RunnerStore.clonedBuilds(in: runners) {
                sizes[build] = known[build] ?? RunnerStore.cloneSize(forBuild: build, runners: runners)
                templates[build] = libraries.reduce(into: [:]) { totals, library in
                    let folder = library.compatdata.appending(path: SupportPaths.prefixTemplateFolder)
                    var info = stat()
                    guard lstat(folder.path(percentEncoded: false), &info) == 0,
                        info.st_mode & S_IFMT == S_IFDIR else { return }
                    for flavor in CompatTool.Flavor.allCases {
                        let template = SupportPaths.prefixTemplate(forBuild: build, flavor: flavor, in: library)
                        totals[flavor, default: 0] += PrefixStore.directoryBytes(template, metric: .allocated)
                    }
                }
            }
            return (sizes, templates, failures, bridgeCopies)
        }.value
        runnerSizes = measured.0
        templateSizes = measured.1
        templateCleanupFailure = measured.2.isEmpty ? nil : measured.2.map(\.detail).joined(separator: "\n")
        bridgeCopyBytes = measured.3
    }
}
