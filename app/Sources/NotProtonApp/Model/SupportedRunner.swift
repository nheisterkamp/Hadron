// The Wine runtimes Hadron serves as compatibility tools. A runtime is a folder built by
// runtime/build-wine.sh and is identified by the build id in its marker file.

import Foundation

struct RunnerBuild: Sendable, Equatable, Identifiable {
    // Written into the runtime's marker file, and names its directory under runners/.
    // Changing it orphans an installed runtime.
    let id: String

    // Display only.
    let releaseVersion: String

    var tools: [CompatTool] = []

    var displayVersion: String { releaseVersion }
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }
    }

    let name: String
    let flavor: Flavor
    let display: String

    var id: String { name }

    var prefixArch: PrefixArch { flavor == .fex ? .arm64 : .x86_64 }
}

struct InstalledTool: Sendable, Hashable, Identifiable {
    let tool: CompatTool
    let build: String

    var id: String { tool.name }
    var name: String { tool.name }
    var display: String { tool.display }
}

enum SupportedRunners {

    // The first tool served is what windows-only games get when Steam has no mapping.
    static let all: [RunnerBuild] = [
        RunnerBuild(
            id: "wine-11.15",
            releaseVersion: "Wine 11.15",
            tools: [
                CompatTool(name: "notproton-wine", flavor: .rosetta, display: "Hadron Wine 11.15"),
            ]
        ),
    ]

    static func tools(for builds: [RunnerBuild]) -> [InstalledTool] {
        let installed = Set(builds.map(\.id))
        return all.filter { installed.contains($0.id) }.flatMap { build in
            build.tools.map { InstalledTool(tool: $0, build: build.id) }
        }
    }

    static func build(id: String) -> RunnerBuild? {
        all.first { $0.id == id }
    }

    static func displayVersion(forID id: String) -> String {
        build(id: id)?.displayVersion ?? id
    }

    static var versionList: String {
        all.map(\.releaseVersion).joined(separator: ", ")
    }
}
