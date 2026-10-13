import Foundation

@testable import HadronApp

func scratchDirectory(_ label: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "np-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func isolatedValveDownloads(in work: URL) throws -> URL {
    let downloads = work.appending(path: "downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    if let bundle = try ValvePackageManifest.bundled().bundle {
        let cached = SupportPaths.packageDownloads.appending(path: bundle.file)
        let destination = downloads.appending(path: bundle.file)
        if FileManager.default.fileExists(atPath: cached.path),
           !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: cached, to: destination)
        }
    }
    return downloads
}

// The one runtime build Hadron serves.
let shippedRuntimeID = "wine-11.15"

var shippedRuntime: RunnerBuild { SupportedRunners.build(id: shippedRuntimeID)! }

// The layout runtime/build-wine.sh stages, reduced to what the app looks at: the marker
// naming the build, the Wine libraries with lsteamclient built in, and an executable loader.
@discardableResult
func makeRuntime(
    at root: URL,
    id: String = shippedRuntimeID,
    lsteamclient: Bool = true,
    loader: Bool = true,
    server: Bool = false,
    wineInf: Bool = false
) throws -> URL {
    let fm = FileManager.default
    let wine = root.appending(path: "lib/wine")
    for arch in ["i386-windows", "x86_64-windows", "x86_64-unix"] {
        try fm.createDirectory(at: wine.appending(path: arch), withIntermediateDirectories: true)
    }
    if lsteamclient {
        for builtin in RunnerInstaller.builtins {
            try Data("\(builtin.arch) lsteamclient".utf8)
                .write(to: wine.appending(path: "\(builtin.arch)/\(builtin.name)"))
        }
    }
    func executable(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }
    if loader { try executable(RuntimeSource.unixLoader(inRoot: root)) }
    if server { try executable(root.appending(path: "bin/wineserver")) }
    if wineInf {
        let inf = root.appending(path: "share/wine/wine.inf")
        try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[Version]\n".utf8).write(to: inf)
    }
    try Data("\(id)\n".utf8).write(to: root.appending(path: RuntimeSource.markerName))
    return root
}

// An installed runtime at runners/<id>, as setup leaves it.
@discardableResult
func makeInstalledRuntime(
    in runners: URL,
    id: String = shippedRuntimeID,
    lsteamclient: Bool = true,
    server: Bool = false,
    wineInf: Bool = false
) throws -> URL {
    try makeRuntime(
        at: SupportPaths.runnerRoot(forBuild: id, runners: runners), id: id,
        lsteamclient: lsteamclient, server: server, wineInf: wineInf
    )
}
