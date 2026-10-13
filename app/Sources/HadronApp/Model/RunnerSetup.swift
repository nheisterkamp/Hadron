// Copies a Wine runtime into runners/ and registers its compatibility tools with Steam.

import Foundation

enum RunnerSetup {

    enum Phase: Sendable {
        case copying
        case installing
        case finished

        var label: String {
            switch self {
            case .copying: String(localized: "Copying the Wine runtime")
            case .installing: String(localized: "Installing compatibility tool")
            case .finished: String(localized: "Done")
            }
        }
    }

    struct Outcome: Sendable {
        let build: RunnerBuild
        var copied = false
        var toolsChanged = false

        var stagedNothing: Bool { !copied && !toolsChanged }
    }

    static func run(
        from install: RuntimeInstall,
        replacingExisting: Bool = false,
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        guard case .supported(let build) = install.support else {
            throw StepFailure(
                step: RunnerInstaller.step,
                detail: String(localized: "\(install.name) is not a supported build. Supported: \(SupportedRunners.versionList).")
            )
        }
        report(.copying)
        let copied = try RunnerInstaller.clone(from: install, replacingExisting: replacingExisting)
        var outcome = try prepare(build, report: report)
        outcome.copied = copied
        return outcome
    }

    static let prepareStep = String(localized: "Set up compatibility tool")

    static func prepare(
        _ build: RunnerBuild,
        runners: URL = SupportPaths.runners,
        toolList: URL = SupportPaths.toolList,
        compatTools: URL = SupportPaths.Steam.compatTools,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        verify: (RunnerBuild, URL) throws -> Void = RunnerInstaller.verifyClone,
        report: @Sendable (Phase) -> Void = { _ in }
    ) throws -> Outcome {
        guard RunnerInstaller.hasClone(forBuild: build.id, runners: runners) else {
            throw StepFailure(
                step: prepareStep, detail: String(localized: "Build \(build.displayVersion) has not been set up.")
            )
        }
        try verify(build, SupportPaths.runnerRoot(forBuild: build.id, runners: runners))

        report(.installing)
        var outcome = Outcome(build: build)
        outcome.toolsChanged = try CompatToolList.sync(runners: runners, file: toolList)
        for tool in CompatToolList.installed(runners: runners, file: toolList) {
            let run = compatTools.appending(path: "\(tool.name)/run")
            if FileManager.default.fileExists(atPath: run.path(percentEncoded: false)) { continue }
            try SteamInstaller.installIfChanged(DeploymentContent.File(
                source: try runScript(), destination: run, name: "\(tool.name)/run", executable: true))
        }

        report(.finished)
        return outcome
    }
}
