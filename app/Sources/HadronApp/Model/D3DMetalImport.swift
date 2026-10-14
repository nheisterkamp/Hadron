// Adds D3DMetal to a runtime that takes it, from a copy the user has. Hadron's downloads
// leave it out: Apple's Game Porting Toolkit licence keeps it from being passed on.

import Foundation

enum D3DMetalImport {

    static let step = String(localized: "Add D3DMetal")

    // Only CrossOver's Wine runs D3DMetal; the others switch %gs, which it does not survive.
    static func accepts(_ build: RunnerBuild) -> Bool {
        build.id.hasPrefix("crossover-")
    }

    static func isPresent(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: target(in: root)
            .appending(path: "x86_64-unix/libd3dshared.dylib").path(percentEncoded: false))
    }

    static func target(in root: URL) -> URL {
        root.appending(path: "lib/graphics/d3dmetal")
    }

    // The folder with the layout every copy shares: external/ with the framework and
    // libd3dshared.dylib, wine/ with its DLLs and unix stubs. That is the Game Porting
    // Toolkit's redist/lib, CrossOver's apple_gptk and Sikarugir's d3dmetal.
    static func locate(in chosen: URL, depth: Int = 7) -> URL? {
        if looksLikeSource(chosen) { return chosen }
        guard depth > 0 else { return nil }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: chosen, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                entry.pathExtension != "framework"
            else { continue }
            if let found = locate(in: entry, depth: depth - 1) { return found }
        }
        return nil
    }

    static func looksLikeSource(_ folder: URL) -> Bool {
        let files = FileManager.default
        return ["external/D3DMetal.framework", "external/libd3dshared.dylib",
                "wine/x86_64-windows", "wine/x86_64-unix"].allSatisfy {
            files.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        }
    }

    // Lays out lib/graphics/d3dmetal as build-wine.sh does for a runtime built with it:
    // the unix stubs are names for libd3dshared.dylib, so D3DMetal loads once.
    static func install(from source: URL, into root: URL) throws {
        let files = FileManager.default
        let final = target(in: root)
        let staged = root.appending(path: "lib/graphics/.d3dmetal-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staged) }
        let unix = staged.appending(path: "x86_64-unix"), windows = staged.appending(path: "x86_64-windows")
        try files.createDirectory(at: unix, withIntermediateDirectories: true)
        try files.createDirectory(at: windows, withIntermediateDirectories: true)

        let dlls = try contents(of: source.appending(path: "wine/x86_64-windows")).filter { $0.pathExtension == "dll" }
        let stubs = try contents(of: source.appending(path: "wine/x86_64-unix")).filter { $0.pathExtension == "so" }
        guard !dlls.isEmpty, !stubs.isEmpty else {
            throw StepFailure(step: step, detail: String(localized: "\(source.path(percentEncoded: false)) has no D3DMetal DLLs."))
        }
        for dll in dlls { try files.copyItem(at: dll, to: windows.appending(path: dll.lastPathComponent)) }
        try files.copyItem(at: source.appending(path: "external/libd3dshared.dylib"),
                           to: unix.appending(path: "libd3dshared.dylib"))
        for stub in stubs {
            try files.createSymbolicLink(atPath: unix.appending(path: stub.lastPathComponent).path(percentEncoded: false),
                                         withDestinationPath: "libd3dshared.dylib")
        }
        try files.copyItem(at: source.appending(path: "external/D3DMetal.framework"),
                           to: unix.appending(path: "D3DMetal.framework"))
        // Apple's licence and notices, beside the copy they cover.
        for folder in [source, source.deletingLastPathComponent(), source.deletingLastPathComponent().deletingLastPathComponent()] {
            for rtf in (try? contents(of: folder))?.filter({ $0.pathExtension == "rtf" }) ?? []
                where !files.fileExists(atPath: staged.appending(path: rtf.lastPathComponent).path(percentEncoded: false)) {
                try? files.copyItem(at: rtf, to: staged.appending(path: rtf.lastPathComponent))
            }
        }

        if files.fileExists(atPath: final.path(percentEncoded: false)) { try files.removeItem(at: final) }
        try files.moveItem(at: staged, to: final)
    }

    private static func contents(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    }
}
