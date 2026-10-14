// Recent game launches, each with the view the launch window shows.

import SwiftUI

struct LaunchesView: View {

    @Environment(LaunchMonitor.self) private var monitor
    @State private var selection: String?

    var body: some View {
        @Bindable var monitor = monitor
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(monitor.records, selection: $selection) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title).fontWeight(.medium)
                        Text(summary(record)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(record.appID)
                }
                .overlay {
                    if monitor.records.isEmpty {
                        ContentUnavailableView(
                            String(localized: "No Launches"),
                            systemImage: "gamecontroller",
                            description: Text(String(localized: "A game appears here once it has been started with a Hadron compatibility tool."))
                        )
                    }
                }
                Divider()
                Toggle(String(localized: "Show a launch window while games start"), isOn: $monitor.showWindow)
                    .padding(10)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                if let appID = selection ?? monitor.records.first?.appID {
                    LaunchView(appID: appID).id(appID)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(String(localized: "Launches"))
    }

    private func summary(_ record: LaunchRecord) -> String {
        let when = record.started.formatted(date: .abbreviated, time: .shortened)
        let runtime = record.display ?? record.build
        return "\(when) · \(runtime)"
    }
}
