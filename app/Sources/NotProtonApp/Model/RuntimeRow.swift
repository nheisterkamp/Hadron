// One row per Wine runtime build on the Status pane

import Foundation

struct RuntimeRow: Identifiable, Equatable {

    enum Copy: Equatable {
        case none
        case ready
        case incomplete
        case damaged
        case unsupported
    }

    let buildID: String
    let install: RuntimeInstall?
    let copy: Copy
    let unsupportedVersion: String?

    var id: String { install?.id ?? buildID }
    var build: RunnerBuild? { SupportedRunners.build(id: buildID) }

    var title: String {
        if let install { return install.name }
        return "Hadron \(SupportedRunners.displayVersion(forID: buildID))"
    }

    var canSetUp: Bool { install != nil && unsupportedVersion == nil }
    var isManual: Bool { install?.isManual ?? false }

    static func == (a: RuntimeRow, b: RuntimeRow) -> Bool {
        a.buildID == b.buildID && a.install?.id == b.install?.id && a.copy == b.copy
            && a.unsupportedVersion == b.unsupportedVersion
    }

    static func rows(
        installs: [RuntimeInstall],
        installed: [RunnerBuild],
        damaged: [String],
        orphaned: [String],
        incomplete: [String]
    ) -> [RuntimeRow] {
        var rows: [RuntimeRow] = []
        var seen: Set<String> = []

        func copy(of build: String) -> Copy {
            if incomplete.contains(build) { return .incomplete }
            if installed.contains(where: { $0.id == build }) { return .ready }
            if damaged.contains(build) { return .damaged }
            return .none
        }

        for install in installs {
            switch install.support {
            case .supported(let build):
                guard seen.insert(build.id).inserted else { continue }
                rows.append(RuntimeRow(
                    buildID: build.id, install: install, copy: copy(of: build.id), unsupportedVersion: nil
                ))
            case .unsupportedBuild(let version):
                rows.append(RuntimeRow(buildID: "", install: install, copy: .none, unsupportedVersion: version))
            }
        }

        let copies = installed.map(\.id) + damaged
        for build in copies where seen.insert(build).inserted {
            rows.append(RuntimeRow(buildID: build, install: nil, copy: copy(of: build), unsupportedVersion: nil))
        }
        for build in orphaned where seen.insert(build).inserted {
            rows.append(RuntimeRow(buildID: build, install: nil, copy: .unsupported, unsupportedVersion: nil))
        }
        return rows
    }

    // The row a picked runtime already shows up under. Supported runtimes match by build,
    // since the folder at a listed path can be swapped for another build.
    static func listing(_ install: RuntimeInstall, in rows: [RuntimeRow]) -> RuntimeRow? {
        if case .supported(let build) = install.support {
            return rows.first { $0.buildID == build.id && $0.install != nil }
        }
        return rows.first { $0.install.map { RuntimeSource.same($0.root, install.root) } ?? false }
    }
}
