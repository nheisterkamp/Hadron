// Finds Wine runtimes on disk: folders built by runtime/build-wine.sh, in the runtimes
// folder or added by hand.

import Foundation

enum RuntimeSupport: Sendable, Equatable {
    case supported(RunnerBuild)
    case unsupportedBuild(String)
}

struct RuntimeInstall: Sendable, Identifiable {
    let root: URL
    let support: RuntimeSupport

    // Selected by the user rather than found in the runtimes folder.
    var isManual = false

    var id: String { root.path(percentEncoded: false) }

    var name: String {
        switch support {
        case .supported(let build): "Hadron \(build.releaseVersion)"
        case .unsupportedBuild(let id): "Hadron \(id)"
        }
    }

    var isUsable: Bool {
        if case .supported = support { return true }
        return false
    }
}

enum RuntimeSource {

    // build-wine.sh writes the build id into this file at the runtime root.
    static let markerName = "notproton-runtime"

    static var searchRoot: URL {
        SupportPaths.support.appending(path: "runtimes", directoryHint: .isDirectory)
    }

    private static let manualKey = "manualRuntimePaths"

    static func manualRoots(_ defaults: UserDefaults = .standard) -> [URL] {
        (defaults.stringArray(forKey: manualKey) ?? [])
            .filter { !$0.isEmpty }.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func setManualRoots(_ roots: [URL], _ defaults: UserDefaults = .standard) {
        defaults.set(roots.map { $0.path(percentEncoded: false) }, forKey: manualKey)
    }

    static func addManualRoot(_ root: URL, _ defaults: UserDefaults = .standard) {
        let current = manualRoots(defaults)
        guard !current.contains(where: { same($0, root) }) else { return }
        setManualRoots(current + [root], defaults)
    }

    static func removeManualRoot(_ root: URL, _ defaults: UserDefaults = .standard) {
        setManualRoots(manualRoots(defaults).filter { !same($0, root) }, defaults)
    }

    static func isSearched(_ root: URL) -> Bool {
        same(root.standardizedFileURL.deletingLastPathComponent(), searchRoot)
    }

    // A folder URL may or may not end in a slash, depending on how it was made.
    static func same(_ a: URL, _ b: URL) -> Bool {
        func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return path(a) == path(b)
    }

    static func runtimeID(atRoot root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appending(path: markerName), encoding: .utf8) else { return nil }
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    static func looksLikeRuntime(_ root: URL) -> Bool {
        runtimeID(atRoot: root) != nil
            && FileManager.default.fileExists(atPath: root.appending(path: "lib/wine").path(percentEncoded: false))
    }

    static func discover() -> [RuntimeInstall] {
        var found: [RuntimeInstall] = []
        var seen: Set<String> = []

        func consider(_ root: URL, isManual: Bool) {
            let key = root.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key), looksLikeRuntime(root) else { return }
            seen.insert(key)
            found.append(inspect(root: root, isManual: isManual))
        }

        for manual in manualRoots() where !isSearched(manual) { consider(manual, isManual: true) }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: searchRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries { consider(entry, isManual: false) }

        return found.sorted(by: preferred)
    }

    static func preferred(_ a: RuntimeInstall, _ b: RuntimeInstall) -> Bool {
        if a.isUsable != b.isUsable { return a.isUsable }
        if a.isManual != b.isManual { return a.isManual }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    static func inspect(root: URL, isManual: Bool = false) -> RuntimeInstall {
        let id = runtimeID(atRoot: root) ?? root.lastPathComponent
        guard let build = SupportedRunners.build(id: id) else {
            return RuntimeInstall(root: root, support: .unsupportedBuild(id), isManual: isManual)
        }
        return RuntimeInstall(root: root, support: .supported(build), isManual: isManual)
    }

    static func unixLoader(inRoot root: URL) -> URL {
        root.appending(path: "lib/wine/x86_64-unix/wine")
    }
}
