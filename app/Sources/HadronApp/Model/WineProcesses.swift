// The Wine processes of one game, found without a wineserver: Hadron's Wine loaders run
// from runners/ or from a game's launcher bundle, and a game's processes work inside its
// prefix or its install folder.

import AppKit
import CoreGraphics
import Darwin
import Foundation

struct WineProcess: Sendable, Equatable, Identifiable {
    let pid: Int32
    // The Windows command line Wine shows for the process.
    let commandLine: String
    // CPU time so far, in seconds.
    let cpuTime: Double

    var id: Int32 { pid }

    var name: String {
        // Wine leaves a path with spaces unquoted, so the program ends at its .exe.
        let program: String
        if commandLine.hasPrefix("\"") {
            program = String(commandLine.dropFirst().prefix { $0 != "\"" })
        } else if let exe = commandLine.range(of: ".exe", options: .caseInsensitive) {
            program = String(commandLine[..<exe.upperBound])
        } else {
            program = String(commandLine.prefix { $0 != " " })
        }
        return String(program.split(separator: "\\").last ?? Substring(program))
    }
}

enum WineProcesses {

    static func scan(prefix: URL, install: URL?, support: URL = SupportPaths.support) -> [WineProcess] {
        let roots = [support.appending(path: "runners"), support.appending(path: "launchers")]
            .map { realPath($0) + "/" }
        let homes = [prefix, install].compactMap { $0 }
            .map(realPath)
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let me = getuid()

        return allPIDs().compactMap { pid -> WineProcess? in
            guard let path = executablePath(pid), roots.contains(where: path.hasPrefix),
                !path.hasSuffix("/wineserver")
            else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                info.pbi_uid == me,
                let cwd = workingDirectory(pid).map({ $0.hasSuffix("/") ? $0 : $0 + "/" }),
                homes.contains(where: cwd.hasPrefix)
            else { return nil }
            return WineProcess(pid: pid, commandLine: commandLine(pid) ?? "", cpuTime: cpuTime(pid))
        }
        .sorted { $0.pid < $1.pid }
    }

    // A window big enough to be the game's, or its launcher's, on screen. An error box,
    // such as an assertion dialog, is smaller and does not count.
    static func hasWindow(pids: Set<Int32>) -> Bool {
        guard !pids.isEmpty,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return list.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
            else { return false }
            return width >= 480 && height >= 360
        }
    }

    // What the kernel reports for a process. URL's own resolving drops /private, which
    // the kernel keeps.
    private static func realPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let found = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        return Array(pids.prefix(Int(max(found, 0)))).filter { $0 > 0 }
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0
        else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // argv[0], which Wine overwrites with the Windows command line.
    private static func commandLine(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        // The executable path, then padding, then argv[0].
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        return String(decoding: buffer[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    private static func cpuTime(_ pid: Int32) -> Double {
        var info = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
        else { return 0 }
        // Mach time units on Apple silicon.
        return Double(info.pti_total_user + info.pti_total_system) * timebase / 1_000_000_000
    }
}

// The end of a log, for the launch window.
enum LogTail {

    static func lines(of url: URL, max: Int = 200, bytes: Int = 96 * 1024) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if end > UInt64(bytes), !lines.isEmpty { lines.removeFirst() }
        // MoltenVK lists every Vulkan extension at startup.
        lines.removeAll { $0.hasPrefix("\tVK_") || $0.hasPrefix("    VK_") }
        return Array(lines.suffix(max))
    }
}
