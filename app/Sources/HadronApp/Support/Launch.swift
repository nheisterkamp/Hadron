import Foundation

@main
enum Launch {
    static func main() {
        if CommandLine.arguments.dropFirst().contains(RemoveEverythingCommand.flag) {
            RemoveEverythingCommand.run()
        }
        HadronApp.main()
    }
}
