// Wine runtimes Hadron downloads, as runtimes.manifest lists them. runtime/release.sh
// writes the manifest when it packs a release.

import Foundation

struct RuntimeDownload: Sendable, Equatable, Identifiable {
    let id: String
    let file: String
    let sha256: String
    let bytes: Int64

    var build: RunnerBuild? { SupportedRunners.build(id: id) }
}

struct RuntimeDownloadManifest: Sendable, Equatable {
    let base: URL?
    let runtimes: [RuntimeDownload]

    static let empty = RuntimeDownloadManifest(base: nil, runtimes: [])

    // A missing or broken manifest leaves nothing to download, not a failure.
    static func bundled() -> RuntimeDownloadManifest {
        guard let url = Bundle.module.url(forResource: "runtimes", withExtension: "manifest"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return .empty }
        return parse(text)
    }

    static func parse(_ text: String) -> RuntimeDownloadManifest {
        var base: URL?
        var runtimes: [RuntimeDownload] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            switch fields[0] {
            case "base" where fields.count == 2:
                if let url = URL(string: fields[1]), url.scheme == "https", url.host() != nil { base = url }
            case "runtime" where fields.count == 5:
                let (id, file, sha, size) = (fields[1], fields[2], fields[3], fields[4])
                guard SupportedRunners.build(id: id) != nil,
                    file.hasSuffix(".tar.xz"), !file.contains("/"),
                    sha.count == 64, sha.allSatisfy(\.isHexDigit),
                    let bytes = Int64(size), bytes > 0,
                    !runtimes.contains(where: { $0.id == id })
                else { continue }
                runtimes.append(RuntimeDownload(id: id, file: file, sha256: sha.lowercased(), bytes: bytes))
            default:
                continue
            }
        }
        return RuntimeDownloadManifest(base: base, runtimes: base == nil ? [] : runtimes)
    }
}

enum RuntimeDownloader {

    enum Phase: Sendable {
        case downloading(name: String, fraction: Double?)
        case verifying
        case unpacking

        var label: String {
            switch self {
            case .downloading(let name, let fraction?):
                String(localized: "Downloading \(name), \(Int((fraction * 100).rounded()))%")
            case .downloading(let name, nil):
                String(localized: "Downloading \(name)")
            case .verifying: String(localized: "Checking the download")
            case .unpacking: String(localized: "Unpacking the runtime")
            }
        }
    }

    static let step = String(localized: "Download a Wine runtime")

    static var cache: URL {
        SupportPaths.home.appending(path: "Library/Caches/\(SupportPaths.supportDirName)/runtimes")
    }

    // Downloads, checks and unpacks one runtime into runtimes/<id>, and returns it.
    static func run(
        _ download: RuntimeDownload,
        from base: URL,
        into runtimes: URL = RuntimeSource.searchRoot,
        cache: URL = RuntimeDownloader.cache,
        report: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> RuntimeInstall {
        let files = FileManager.default
        let target = runtimes.appending(path: download.id)
        guard !files.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw StepFailure(step: step, detail: String(localized: "\(target.path(percentEncoded: false)) is already there. Remove it to download the runtime again."))
        }
        let name = download.build?.releaseVersion ?? download.id

        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        let archive = cache.appending(path: download.file)
        if Digest.sha256IfPresent(archive) != download.sha256 {
            try? files.removeItem(at: archive)
            report(.downloading(name: name, fraction: 0))
            let fetched = try await fetch(base.appending(path: download.file), expected: download.bytes) {
                report(.downloading(name: name, fraction: $0))
            }
            try files.moveItem(at: fetched, to: archive)
        }

        report(.verifying)
        guard Digest.sha256IfPresent(archive) == download.sha256 else {
            try? files.removeItem(at: archive)
            throw StepFailure(step: step, detail: String(localized: "\(download.file) does not match the checksum Hadron expects, so it was not used."))
        }

        report(.unpacking)
        try files.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let unpacked = runtimes.appending(path: ".download-\(download.id)-\(UUID().uuidString)")
        defer { try? files.removeItem(at: unpacked) }
        try files.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let tar = try Shell.run("/usr/bin/tar", ["-xJf", archive.path(percentEncoded: false),
                                                 "-C", unpacked.path(percentEncoded: false)])
        guard tar.succeeded else {
            throw StepFailure(step: step, detail: String(localized: "\(download.file) could not be unpacked. ")
                + tar.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let root = unpacked.appending(path: download.id)
        guard RuntimeSource.runtimeID(atRoot: root) == download.id, RuntimeSource.looksLikeRuntime(root) else {
            throw StepFailure(step: step, detail: String(localized: "\(download.file) does not hold Wine runtime \(download.id)."))
        }
        try files.moveItem(at: root, to: target)
        try? files.removeItem(at: archive)
        return RuntimeSource.inspect(root: target)
    }

    // A download with progress, as a file the caller moves into place.
    static func fetch(
        _ url: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = ProgressDelegate(expected: expected, progress: progress)
        let (body, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        // A file URL, as the tests use, has no status.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: body)
            throw StepFailure(step: step, detail: String(localized: "\(url.host() ?? url.absoluteString) answered \(http.statusCode) for \(url.lastPathComponent)."))
        }
        // The system removes its temporary file once this returns.
        let kept = FileManager.default.temporaryDirectory.appending(path: "hadron-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: body, to: kept)
        return kept
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64
        let progress: @Sendable (Double) -> Void
        private var lastPercent = -1

        init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            guard total > 0 else { return }
            let fraction = min(Double(totalBytesWritten) / Double(total), 1)
            let percent = Int(fraction * 100)
            guard percent != lastPercent else { return }
            lastPercent = percent
            progress(fraction)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}
