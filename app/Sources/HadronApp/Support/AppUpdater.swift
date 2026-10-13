import Sparkle

@MainActor
final class AppUpdater {

    private let controller: SPUStandardUpdaterController

    // Sparkle needs a feed and a signing key to start. Hadron publishes neither yet, and
    // without them Sparkle would report a failure at every launch.
    static let isConfigured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil

    init() {
        #if DEBUG
        let scheduling = false
        #else
        let scheduling = Self.isConfigured
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: scheduling,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func check() {
        #if !DEBUG
        guard Self.isConfigured else { return }
        controller.checkForUpdates(nil)
        #endif
    }
}
