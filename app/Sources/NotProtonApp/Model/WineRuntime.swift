// A Wine runtime built by runtime/build-wine.sh, used in place of CrossOver. It has
// the steamclient redirect and lsteamclient built in, so it skips the ntdll patching
// and the lsteamclient install that a CrossOver copy gets.

import Foundation

enum WineRuntime {

    // build-wine.sh writes the build id into this file at the runtime root.
    static let markerName = "notproton-runtime"

    // A CrossOver tree with a marker dropped into it is still CrossOver, and still
    // needs its license.
    static func id(atRoot root: URL) -> String? {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appending(path: "share/crossover").path(percentEncoded: false)),
              let text = try? String(contentsOf: root.appending(path: markerName), encoding: .utf8)
        else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func isRuntime(_ root: URL) -> Bool {
        id(atRoot: root) != nil
    }

    static func build(atRoot root: URL) -> RunnerBuild? {
        guard let build = id(atRoot: root).flatMap(SupportedRunners.build(id:)),
              build.source == .runtime else { return nil }
        return build
    }
}
