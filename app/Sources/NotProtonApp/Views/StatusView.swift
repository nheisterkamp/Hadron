// 'Status' view, see SystemStatus for actual logic

import SwiftUI

enum StatusTone: Sendable {
    case ok, info, warning, bad, neutral

    var symbol: String {
        switch self {
        case .ok: "circle.fill"
        case .info: "circle"
        case .warning: "circle.fill"
        case .bad: "circle.fill"
        case .neutral: "circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .info: .secondary
        case .warning: .orange
        case .bad: .red
        case .neutral: .secondary
        }
    }
}

struct StatusAction {
    let label: String
    var isProminent = false
    var role: ButtonRole?
    var help: String?
    var isEnabled = true
    var startsGroup = false
    let perform: () -> Void
}

enum StatusMetrics {
    static let symbolWidth: CGFloat = 10
    static let symbolSpacing: CGFloat = 8
    static var textInset: CGFloat { symbolWidth + symbolSpacing }
}

struct StatusRow: View {

    let title: String
    var value: String?

    var tone: StatusTone?
    var detail: String?
    var trailing: String?
    var secondaryAction: StatusAction?
    var action: StatusAction?
    var menu: [StatusAction] = []
    var toggle: Binding<Bool>?

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: StatusMetrics.symbolSpacing) {
                if let tone {
                    Image(systemName: tone.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(tone.color)
                        .frame(width: StatusMetrics.symbolWidth)
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: StatusMetrics.symbolWidth, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let value {
                        Text(value)
                            .foregroundStyle(.secondary)
                    }
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if secondaryAction != nil || action != nil || !menu.isEmpty || toggle != nil || trailing != nil {
                Spacer(minLength: 12)
            }
            if let trailing {
                Text(trailing)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.trailing, action == nil && menu.isEmpty ? 0 : 8)
            }
            if let toggle {
                Toggle(title, isOn: toggle)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let secondaryAction {
                button(secondaryAction)
                    .disabled(!secondaryAction.isEnabled)
                    .help(secondaryAction.help ?? "")
                    .accessibilityLabel("\(secondaryAction.label), \(title)")
                    .padding(.trailing, 8)
            }
            if let action {
                button(action)
                    .disabled(!action.isEnabled)
                    .help(action.help ?? "")
                    .accessibilityLabel("\(action.label), \(title)")
            }
            if !menu.isEmpty {
                Menu {
                    menuItems(menu, hidingUnavailable: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions, \(title)")
                .padding(.leading, action == nil ? 0 : 8)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            menuItems([action, secondaryAction].compactMap { $0 } + menu, hidingUnavailable: true)
        }
    }

    @ViewBuilder
    private func menuItems(_ items: [StatusAction], hidingUnavailable: Bool) -> some View {
        let shown = hidingUnavailable ? items.filter(\.isEnabled) : items
        ForEach(Array(shown.enumerated()), id: \.offset) { index, item in
            if item.startsGroup && index > 0 { Divider() }
            Button(item.label, role: item.role, action: item.perform)
                .disabled(!item.isEnabled)
        }
    }

    @ViewBuilder
    private func button(_ action: StatusAction) -> some View {
        if action.isProminent {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.borderedProminent)
        } else {
            Button(action.label, role: action.role, action: action.perform)
                .buttonStyle(.bordered)
        }
    }
}

struct StatusView: View {
    @Environment(SystemStatus.self) private var status

    private static let updateBlockPrompt =
        String(localized: "Steam client updates may break Hadron. If you don't want to wait for Hadron to be updated to be compatible with future Steam versions at the cost of not getting updates to the Steam client, you can stop the Steam client from updating itself.")

    var body: some View {
        Group {
            if let snapshot = status.snapshot {
                statusForm(snapshot)
            } else {
                ProgressView("Checking")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Status")
        .toolbar {
            if #available(macOS 26.1, *) {
                ToolbarItem(placement: .primaryAction) { refreshButton }
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .primaryAction) { refreshButton }
            }
        }
        .confirmationDialog(
            String(localized: "Block Steam client updates?"),
            isPresented: asking(.blockUpdates),
            titleVisibility: .visible
        ) {
            Button("Block Updates", role: .destructive) {
                Task { await status.setUpdateBlock(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.updateBlockPrompt)
        }
        .confirmationDialog(
            String(localized: "Replace Steam with Valve's bundle?"),
            isPresented: asking(.replaceSteam),
            titleVisibility: .visible
        ) {
            Button("Replace Steam", role: .destructive) {
                Task { await status.repairSteam() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                String(localized: "This will restore Steam itself to its original state but does not remove the support components used by Hadron.")
            )
        }
        .confirmationDialog(
            status.pendingRemoval.map {
                String(localized: "Remove the \(SupportedRunners.displayVersion(forID: $0)) copy?")
            } ?? "",
            isPresented: asking(.removeBuild),
            titleVisibility: .visible
        ) {
            Button("Remove Copy", role: .destructive) {
                Task { await status.removePendingBuild() }
            }
            Button("Cancel", role: .cancel) { status.cancelBuildRemoval() }
        } message: {
            Text("The runtime folder it was copied from is not removed.")
        }
        .confirmationDialog(
            String(localized: "Remove everything Hadron has created?"),
            isPresented: asking(.removeEverything),
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) {
                Task { await status.removeEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Uninstall.confirmation())
        }
        .task { if status.snapshot == nil { await status.refresh() } }
    }

    private func asking(_ confirmation: SystemStatus.Confirmation) -> Binding<Bool> {
        Binding(
            get: { status.pendingConfirmation == confirmation },
            set: { shown in
                if !shown, status.pendingConfirmation == confirmation {
                    status.pendingConfirmation = nil
                }
            }
        )
    }

    private func statusForm(_ snapshot: StatusSnapshot) -> some View {
        ScrollViewReader { proxy in
            form(snapshot)
                .onChange(of: status.highlightedRow) { _, row in
                    guard let row else { return }
                    withAnimation { proxy.scrollTo(row, anchor: .center) }
                }
        }
    }

    private func form(_ snapshot: StatusSnapshot) -> some View {
        Form {
            if let failure = status.failure {
                StatusRow(
                    title: String(localized: "Failed"),
                    value: failure,
                    tone: .bad,
                    action: status.failureRemedy?.settingsPane.map { pane in
                        StatusAction(label: Remedy.settingsButton) {
                            Remedy.openSettings(pane)
                        }
                    }
                )
            } else if let outcome = status.outcome {
                StatusRow(title: String(localized: "Done"), value: outcome, tone: .ok)
            }

            if let failure = status.templateCleanupFailure {
                StatusRow(title: String(localized: "Template cleanup incomplete"), value: failure, tone: .warning)
            }

            if let activity = status.activity {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Steam") {
                StatusRow(
                    title: String(localized: "Location"),
                    value: SupportPaths.Steam.app.path(percentEncoded: false),
                    action: StatusAction(
                        label: String(localized: "Choose\u{2026}"),
                        help: String(localized: "Use a copy of Steam from another folder or drive."),
                        isEnabled: status.isIdle
                    ) { Task { await status.chooseSteam() } }
                )
                steamRow(snapshot.steam, payload: snapshot.payload)
                if snapshot.steamRunning {
                    StatusRow(
                        title: String(localized: "Steam is running"),
                        value: String(localized: "Close Steam before continuing."),
                        tone: .info
                    )
                }
                updateBlockRow(snapshot.updateBlocked)
                StatusRow(
                    title: String(localized: "Controller permission"),
                    value: String(localized: "Clear Steam's controller permission so macOS asks for it again."),
                    action: StatusAction(
                        label: String(localized: "Reset"),
                        isEnabled: status.isIdle
                    ) { Task { await status.resetControllerPermission() } }
                )
            }

            Section {
                runtimeSection(snapshot)
            } header: {
                Text("Wine Runtime")
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Wine Runtime\u{2026}") { Task { await status.addRuntime() } }
                        .disabled(!status.isIdle)
                        .help("Add a Hadron Wine runtime from another folder.")
                }
            }

            componentsSection(snapshot.payload)

            dangerSection
        }
        .formStyle(.grouped)
    }

    private var dangerSection: some View {
        Section {
            StatusRow(
                title: String(localized: "Repair Steam"),
                value: String(localized: "Restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Repair"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .replaceSteam }
            )
            StatusRow(
                title: String(localized: "Remove Everything"),
                value: String(localized: "Remove Hadron and restore Steam to its original state."),
                action: StatusAction(
                    label: String(localized: "Remove"),
                    role: .destructive,
                    isEnabled: status.isIdle
                ) { status.pendingConfirmation = .removeEverything }
            )
        }
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await status.refresh() }
        }
        .disabled(!status.isIdle)
    }

    private func installAction(prominent: Bool, label: String = String(localized: "Install")) -> StatusAction {
        StatusAction(
            label: label,
            isProminent: prominent,
            help: String(localized: "Install Hadron into Steam."),
            isEnabled: status.canInstall
        ) {
            Task { await status.requestInstall() }
        }
    }

    @ViewBuilder
    private func steamRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .notInstalled:
            if let content = status.snapshot?.installContent, content.blocksInstallation {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        case .installed, .outdated:
            if let content = status.snapshot?.installContent, content != .unchecked {
                installedContentRow(content, deployment: deployment, payload: payload)
            } else {
                deploymentRow(deployment, payload: payload)
            }
        default:
            deploymentRow(deployment, payload: payload)
        }
    }

    @ViewBuilder
    private func installedContentRow(_ content: DeploymentContent.Status, deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch content {
        case .unchecked, .current:
            let version: String? = switch deployment {
            case .installed(let version): version
            case .outdated(let deployed, _): deployed
            default: nil
            }
            deploymentRow(.installed(version: version), payload: payload)
        case .newerInstalled:
            StatusRow(title: "Hadron", value: String(localized: "A newer build is installed."), tone: .neutral,
                      detail: String(localized: "Use the newer Hadron app to update or repair the installed files."))
        case .unavailable(let reason):
            StatusRow(title: "Hadron", value: String(localized: "Could not check installed files."), tone: .warning, detail: reason)
        case .update(let files):
            StatusRow(title: "Hadron", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes newer files than those installed for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        case .repair(let files):
            StatusRow(title: "Hadron", value: String(localized: "Installed files differ from this build."), tone: .warning,
                      detail: String(localized: "Restore the files included with this app."),
                      action: installAction(prominent: true, label: String(localized: "Repair")))
                .help(files.joined(separator: "\n"))
        case .unrecorded(let files):
            StatusRow(title: "Hadron", value: String(localized: "Update available."), tone: .warning,
                      detail: String(localized: "This app includes updated files for Steam."),
                      action: installAction(prominent: true, label: String(localized: "Update")))
                .help(files.joined(separator: "\n"))
        }
    }

    @ViewBuilder
    private func deploymentRow(_ deployment: SteamDeployment, payload: PayloadState) -> some View {
        switch deployment {
        case .steamMissing:
            StatusRow(title: "Hadron", value: String(localized: "Steam not found."), tone: .bad)
        case .notInstalled:
            StatusRow(
                title: "Hadron",
                value: String(localized: "Not installed."),
                tone: .neutral,
                action: installAction(prominent: true)
            )
        case .installed(let version):
            if payload.isComplete {
                StatusRow(
                    title: "Hadron",
                    value: String(localized: "Installed") + (version.map { " (\($0))" } ?? ""),
                    tone: .ok
                )
            } else {
                StatusRow(
                    title: "Hadron",
                    value: String(localized: "Installed, but not for this account."),
                    tone: .warning,
                    detail: String(localized: "Steam is set up for Hadron, but this account is missing its components. Install to add them."),
                    action: installAction(prominent: true)
                )
            }
        case .outdated(_, let bundled):
            StatusRow(
                title: "Hadron",
                value: String(localized: "Update available (\(bundled))."),
                tone: .warning,
                action: installAction(prominent: true)
            )
        case .foreign:
            StatusRow(
                title: "Hadron",
                value: String(localized: "Another dylib is present."),
                tone: .warning,
                detail: String(localized: "Repair your Steam install before installing Hadron.")
            )
        }
    }

    private func updateBlockRow(_ blocked: Bool) -> some View {
        StatusRow(
            title: String(localized: "Block Steam client updates"),
            value: blocked
                ? String(localized: "The Steam client will not update itself.")
                : String(localized: "A Steam client update may break Hadron."),
            toggle: blockUpdates
        )
        .disabled(!status.isIdle)
        .help("Steam client updates may break Hadron.")
    }

    private var blockUpdates: Binding<Bool> {
        Binding(
            get: { status.snapshot?.updateBlocked ?? false },
            set: { wanted in
                if wanted {
                    status.pendingConfirmation = .blockUpdates
                } else {
                    Task { await status.setUpdateBlock(false) }
                }
            }
        )
    }

    @ViewBuilder
    private func runtimeSection(_ snapshot: StatusSnapshot) -> some View {
        let rows = status.runtimeRows
        if rows.isEmpty {
            StatusRow(
                title: String(localized: "Wine Runtime"),
                value: String(localized: "Not found. Supported: \(SupportedRunners.versionList)."),
                tone: .bad
            )
        }
        let tools = SupportedRunners.tools(for: snapshot.installedRunners)
        ForEach(rows) { row in
            StatusRow(
                title: row.title,
                value: runtimeValue(row),
                tone: runtimeTone(row),
                detail: runtimeDetail(row, tools: tools),
                trailing: row.copy == .ready ? buildSize(row.buildID) : nil,
                action: runtimeAction(row, prominent: snapshot.runner == .none),
                menu: runtimeMenu(row)
            )
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(-6)
                    .opacity(status.highlightedRow == row.id ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.3), value: status.highlightedRow == row.id)
            .id(row.id)
        }
    }

    private func runtimeValue(_ row: RuntimeRow) -> String {
        if let version = row.unsupportedVersion {
            return String(localized: "Version \(version) not supported (supported: \(SupportedRunners.versionList))")
        }
        let build = String(localized: "Build \(SupportedRunners.displayVersion(forID: row.buildID))")
        switch row.copy {
        case .ready: return build
        case .none: return build + String(localized: ", not set up")
        case .incomplete: return build + String(localized: ", incomplete")
        case .damaged: return build + String(localized: ", copy damaged")
        case .unsupported: return build + String(localized: ", not supported")
        }
    }

    private func runtimeTone(_ row: RuntimeRow) -> StatusTone {
        if row.unsupportedVersion != nil { return .neutral }
        switch row.copy {
        case .none: return .neutral
        case .ready: return .ok
        case .incomplete, .damaged, .unsupported: return .warning
        }
    }

    private func runtimeDetail(_ row: RuntimeRow, tools: [InstalledTool]) -> String? {
        var lines: [String] = []
        if row.copy == .ready || row.copy == .incomplete {
            lines.append(contentsOf: tools.filter { $0.build == row.buildID }.map(\.display))
        }
        if let install = row.install {
            var path = install.root.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            lines.append(path)
        } else if row.copy != .unsupported {
            lines.append(String(localized: "Runtime folder not found."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func runtimeAction(_ row: RuntimeRow, prominent: Bool) -> StatusAction? {
        let install = row.install
        switch row.copy {
        case .none where row.canSetUp:
            return StatusAction(
                label: String(localized: "Set Up"),
                isProminent: prominent,
                help: String(localized: "Copy \(row.title) and set up its compatibility tool."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install) } }
        case .incomplete where row.canSetUp, .damaged where row.canSetUp:
            return StatusAction(
                label: String(localized: "Repair"),
                isProminent: true,
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall
            ) { Task { await status.requestCompatibilityTool(from: install, replacingExisting: true) } }
        case .unsupported:
            return removeCopyAction(row.buildID, label: String(localized: "Remove\u{2026}"))
        default:
            return nil
        }
    }

    private func runtimeMenu(_ row: RuntimeRow) -> [StatusAction] {
        var items: [StatusAction] = []
        let install = row.install
        if row.copy == .ready {
            items.append(StatusAction(
                label: String(localized: "Reinstall"),
                help: String(localized: "Copy \(row.title) again."),
                isEnabled: status.canInstall && row.canSetUp
            ) { Task { await status.requestCompatibilityTool(from: install, replacingExisting: true) } })
        }
        let shown = install?.root
            ?? (row.copy == .none ? nil : SupportPaths.runnerRoot(forBuild: row.buildID))
        if let shown {
            items.append(StatusAction(label: String(localized: "Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([shown])
            })
        }
        if [.ready, .incomplete, .damaged].contains(row.copy) {
            var remove = removeCopyAction(row.buildID, label: String(localized: "Remove Copy\u{2026}"))
            remove.startsGroup = true
            items.append(remove)
        }
        if let install, row.isManual {
            items.append(StatusAction(
                label: String(localized: "Remove from List"),
                isEnabled: status.isIdle,
                startsGroup: !items.contains(where: \.startsGroup)
            ) { Task { await status.removeFromList(install) } })
        }
        return items
    }

    private func buildSize(_ build: String) -> String? {
        guard let runner = status.runnerSizes[build] else { return nil }
        let flavors = SupportedRunners.build(id: build)?.tools.map(\.flavor) ?? []
        return Self.sizeText(runner: runner, templates: status.templateSizes[build] ?? [:], flavors: flavors)
    }

    nonisolated static func sizeText(runner: Int64, templates: [CompatTool.Flavor: Int64], flavors: [CompatTool.Flavor]) -> String {
        let lines: [String]
        if flavors.count > 1 {
            lines = flavors.compactMap { flavor in
                guard let bytes = templates[flavor], bytes > 0 else { return nil }
                return String(localized: "\(flavor.name) templates \(bytes.formatted(.byteCount(style: .file)))")
            }
        } else {
            let bytes = templates.values.reduce(0, +)
            lines = bytes > 0 ? [String(localized: "Templates \(bytes.formatted(.byteCount(style: .file)))")] : []
        }
        return ([String(localized: "Runner \(runner.formatted(.byteCount(style: .file)))")] + lines).joined(separator: "\n")
    }

    private func removeCopyAction(_ build: String, label: String) -> StatusAction {
        StatusAction(
            label: label,
            role: .destructive,
            help: String(localized: "Delete Hadron's copy of this build."),
            isEnabled: status.canInstall
        ) {
            status.requestBuildRemoval(build)
        }
    }

    private func fetchAction() -> StatusAction {
        StatusAction(
            label: String(localized: "Fetch Valve Binaries"),
            isProminent: true,
            help: String(localized: "Download missing Valve binaries."),
            isEnabled: status.canInstall
        ) { Task { await status.fetchValveBinaries() } }
    }

    @ViewBuilder
    private func componentsSection(_ payload: PayloadState) -> some View {
        if let problem = payload.manifestProblem {
            Section("Hadron Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Component list unreadable."), tone: .bad, detail: problem)
            }
        } else if payload.isComplete {
            Section("Hadron Components") {
                StatusRow(
                    title: String(localized: "Components"), value: String(localized: "Ready."), tone: .ok,
                    trailing: status.bridgeCopyBytes > 0
                        ? String(localized: "Copies on other drives \(status.bridgeCopyBytes.formatted(.byteCount(style: .file)))") : nil
                )
            }
        } else if payload.isEmpty {
            Section("Hadron Components") {
                StatusRow(title: String(localized: "Components"), value: String(localized: "Not yet deployed."), tone: .neutral)
            }
        } else {
            Section("Hadron Components") {
                if !payload.missing.isEmpty {
                    let names = payload.missing.map(\.path).joined(separator: ", ")
                    StatusRow(
                        title: String(localized: "Missing."),
                        value: names,
                        tone: .bad,
                        action: payload.missing.contains(where: { $0.origin.isFetchable })
                            ? fetchAction() : nil
                    )
                }
                if !payload.overlayShimPresent {
                    StatusRow(title: String(localized: "Overlay shim"), value: String(localized: "Missing."), tone: .bad)
                }
                if payload.signatureDatabase == nil {
                    StatusRow(title: String(localized: "Signature database"), value: String(localized: "Missing."), tone: .bad)
                }
            }
        }
    }
}
