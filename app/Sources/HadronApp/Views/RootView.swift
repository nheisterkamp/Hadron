import SwiftUI

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case status
    case prefixes
    case backups
    case launches

    var id: String { rawValue }

    var label: String {
        switch self {
        case .status: String(localized: "Status")
        case .prefixes: String(localized: "Prefixes")
        case .backups: String(localized: "Prefix Backups")
        case .launches: String(localized: "Launches")
        }
    }

    var symbol: String {
        switch self {
        case .status: "checklist"
        case .prefixes: "externaldrive"
        case .backups: "externaldrive.badge.timemachine"
        case .launches: "gamecontroller"
        }
    }
}

struct RootView: View {

    @Binding var pane: Pane

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch pane {
            case .status: StatusView()
            case .prefixes: PrefixesView()
            case .backups: BackupsView()
            case .launches: LaunchesView()
            }
        }
        // On every pane: starts Steam, or brings it forward when it runs.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Open Steam")) { SteamBundle.open() }
                    .help(String(localized: "Start Steam, or bring it to the front."))
                    .disabled(!SteamBundle.isPresent)
            }
        }
    }
}
