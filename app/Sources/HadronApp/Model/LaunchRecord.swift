// What compat_run.sh writes to hadron/launches/<appid> while a game starts.

import Foundation

struct LaunchRecord: Sendable, Equatable, Identifiable {

    enum State: String, Sendable {
        case starting
        case running
        case exited
        case failed
    }

    let appID: String
    let name: String?
    let build: String
    let display: String?
    let compatdata: URL
    let install: URL?
    let log: URL
    let pid: Int32
    let started: Date
    let updated: Date
    let step: String
    let stepStarted: Date
    let state: State
    let status: Int?
    // The prefix was moved to this runtime's architecture on the way.
    let converted: Bool

    var id: String { appID }

    var title: String { name ?? String(localized: "App \(appID)") }
    var prefix: URL { compatdata.appending(path: "pfx") }
    var wineLog: URL { SupportPaths.launchers.appending(path: appID).appending(path: "hadron-wine.log") }

    // True while the run script that wrote the record is still there. A record that says
    // starting or running after its script died describes a launch that was cut off.
    var isLive: Bool {
        guard state == .starting || state == .running, pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    init?(text: String) {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let appID = fields["app"], !appID.isEmpty, appID.allSatisfy(\.isNumber),
            let compatdata = fields["compatdata"], !compatdata.isEmpty,
            let state = fields["state"].flatMap(State.init(rawValue:)),
            let started = fields["started"].flatMap(TimeInterval.init)
        else { return nil }
        func date(_ key: String) -> Date? { fields[key].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) }
        func field(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }

        self.appID = appID
        self.name = field("name")
        self.build = fields["build"] ?? ""
        self.display = field("display")
        self.compatdata = URL(filePath: compatdata)
        self.install = field("install").map { URL(filePath: $0) }
        self.log = field("log").map { URL(filePath: $0) } ?? URL(filePath: compatdata).appending(path: "hadron-run.log")
        self.pid = fields["pid"].flatMap(Int32.init) ?? 0
        self.started = Date(timeIntervalSince1970: started)
        self.updated = date("updated") ?? self.started
        self.step = fields["step"] ?? ""
        self.stepStarted = date("step_started") ?? self.started
        self.state = state
        self.status = fields["status"].flatMap(Int.init)
        self.converted = fields["converted"] == "1"
    }
}

enum LaunchStore {

    static var directory: URL { SupportPaths.support.appending(path: "launches") }

    // The newest first.
    static func records(in directory: URL = LaunchStore.directory) -> [LaunchRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.filter { $0.allSatisfy(\.isNumber) }
            .compactMap { name in
                (try? String(contentsOf: directory.appending(path: name), encoding: .utf8))
                    .flatMap(LaunchRecord.init(text:))
            }
            .sorted { $0.started > $1.started }
    }
}

// Whether the run script opens the launch window. It looks for the file, which keeps the
// check out of defaults(1) on every launch.
enum LaunchWindowSetting {

    static func marker(in support: URL = SupportPaths.support) -> URL {
        support.appending(path: "launch-window-off")
    }

    static func isOn(support: URL = SupportPaths.support) -> Bool {
        !FileManager.default.fileExists(atPath: marker(in: support).path(percentEncoded: false))
    }

    static func set(_ on: Bool, support: URL = SupportPaths.support) {
        let file = marker(in: support)
        if on {
            try? FileManager.default.removeItem(at: file)
        } else {
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
        }
    }
}

// The run script's steps, grouped into what the launch window shows, in order.
enum LaunchStage: Int, CaseIterable, Sendable, Comparable {
    case runtime
    case prefix
    case conversion
    case seed
    case setup
    case steam
    case game

    init?(step: String) {
        switch step {
        case "startup", "runner check": self = .runtime
        case "prefix lock", "prefix build check", "prefix arch check": self = .prefix
        case "prefix conversion": self = .conversion
        case "prefix seed": self = .seed
        case "profile layout", "game drive", "prefix settings", "fonts": self = .setup
        case "bridge staging": self = .steam
        case "game": self = .game
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .runtime: String(localized: "Checking the Wine runtime")
        case .prefix: String(localized: "Checking the prefix")
        case .conversion: String(localized: "Converting the prefix to this runtime")
        case .seed: String(localized: "Creating the prefix")
        case .setup: String(localized: "Preparing the prefix")
        case .steam: String(localized: "Copying Steam files")
        case .game: String(localized: "Starting the game")
        }
    }

    static func < (a: LaunchStage, b: LaunchStage) -> Bool { a.rawValue < b.rawValue }
}
