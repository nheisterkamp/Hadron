// Checks installed runtimes for status display

import Foundation

enum RunnerState: Sendable, Equatable {
    case none
    case ready(builds: [String])
    case incomplete(builds: [String], problems: [String])

    var builds: [String] {
        switch self {
        case .none: []
        case .ready(let builds): builds
        case .incomplete(let builds, _): builds
        }
    }
}

enum RunnerStore {

    static func state(
        runners: URL = SupportPaths.runners,
        verify: @Sendable (RunnerBuild, URL) -> [String] = {
            RunnerInstaller.problems(build: $0, root: $1)
        }
    ) -> RunnerState {
        let installed = installedBuilds(in: runners)
        guard !installed.isEmpty else { return .none }

        var incomplete: [String] = []
        var problems: [String] = []
        for build in installed {
            let found = verify(build, SupportPaths.runnerRoot(forBuild: build.id, runners: runners))
            guard !found.isEmpty else { continue }
            incomplete.append(build.id)
            problems += found.map { "\(build.id): \($0)" }
        }
        if incomplete.isEmpty { return .ready(builds: installed.map(\.id)) }
        return .incomplete(builds: incomplete, problems: problems)
    }

    // Every installed runtime folder, by build id. Staging and removal leftovers are hidden.
    static func clonedBuilds(in runners: URL = SupportPaths.runners) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: runners, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return entries.filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        .map(\.lastPathComponent)
        .filter { !$0.hasPrefix(".") }
        .sorted()
    }

    static func orphanedClones(in runners: URL = SupportPaths.runners) -> [String] {
        clonedBuilds(in: runners).filter { SupportedRunners.build(id: $0) == nil }
    }

    static func damagedClones(in runners: URL = SupportPaths.runners) -> [String] {
        clonedBuilds(in: runners).filter {
            SupportedRunners.build(id: $0) != nil
                && !RunnerInstaller.hasClone(forBuild: $0, runners: runners)
        }
    }

    static func cloneSize(forBuild build: String, runners: URL = SupportPaths.runners) -> Int64 {
        let root = SupportPaths.runnerRoot(forBuild: build, runners: runners)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            )
            let bytes = values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0
            total += Int64(bytes)
        }
        return total
    }

    static func installedBuilds(in runners: URL = SupportPaths.runners) -> [RunnerBuild] {
        clonedBuilds(in: runners)
            .compactMap(SupportedRunners.build(id:))
            .filter { RunnerInstaller.hasClone(forBuild: $0.id, runners: runners) }
    }
}

enum CompatToolList {

    static func contents(_ tools: [InstalledTool]) -> String {
        tools.map { "\($0.name)\t\($0.build)\t\($0.tool.flavor.rawValue)\t\($0.display)\n" }.joined()
    }

    static func installed(
        runners: URL = SupportPaths.runners, file: URL = SupportPaths.toolList
    ) -> [InstalledTool] {
        SupportedRunners.tools(for: RunnerStore.installedBuilds(in: runners))
    }

    // Returns true when the list file changed.
    @discardableResult
    static func sync(
        runners: URL = SupportPaths.runners,
        file: URL = SupportPaths.toolList
    ) throws -> Bool {
        let text = contents(installed(runners: runners, file: file))
        let listed = try? String(contentsOf: file, encoding: .utf8)
        guard !(listed == text || (listed == nil && text.isEmpty)) else { return false }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try atomicReplace(file, with: Data(text.utf8), step: String(localized: "Update compatibility tools"))
        return true
    }
}
