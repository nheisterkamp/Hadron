import Foundation

@main
enum Launch {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        LaunchMonitor.launchedForWindow = CommandLine.arguments.dropFirst().contains("--launch-window")
        HadronApp.main()
    }
}
