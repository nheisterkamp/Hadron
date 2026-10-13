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

    var flavor: CompatTool.Flavor { tools.first?.flavor ?? .rosetta }
}

struct CompatTool: Sendable, Hashable, Identifiable {
    enum Flavor: String, Sendable, CaseIterable {
        case rosetta
        case fex

        var name: String { self == .fex ? "FEX" : "Rosetta" }
        var unixDir: String { self == .fex ? "aarch64-unix" : "x86_64-unix" }
        // Where the 64-bit PE builtins are: ARM64X ones for FEX, which runs x86_64 code
        // as ARM64EC.
        var peDir: String { self == .fex ? "aarch64-windows" : "x86_64-windows" }
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

    // One per definition in runtime/runtimes. The first tool served is what windows-only
    // games get when Steam has no mapping.
    static let all: [RunnerBuild] = [
        rosetta(id: "wine-11.15", name: "Wine 11.15"),
        rosetta(id: "wine-staging-11.15", name: "Wine Staging 11.15"),
        rosetta(id: "wine-11.19", name: "Wine 11.19"),
        rosetta(id: "crossover-26.3", name: "CrossOver Wine 26.3"),
        fex(id: "wine-11.19-arm64", name: "Wine 11.19 (Apple Silicon)"),
    ]

    // Steam maps Cloud save paths into a prefix only for a tool whose name contains
    // "proton", so every tool is hadron-proton-<id>.
    private static func rosetta(id: String, name: String) -> RunnerBuild {
        RunnerBuild(id: id, releaseVersion: name, tools: [
            CompatTool(name: "hadron-proton-\(id)", flavor: .rosetta, display: "Hadron \(name)"),
        ])
    }

    // A native arm64 Wine that runs x86 code with FEX.
    private static func fex(id: String, name: String) -> RunnerBuild {
        RunnerBuild(id: id, releaseVersion: name, tools: [
            CompatTool(name: "hadron-proton-\(id)", flavor: .fex, display: "Hadron \(name)"),
        ])
    }

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
