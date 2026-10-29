import Foundation

// Child processes use the same executable name and arguments as the parent check.
@main
struct ProcessCheckMain {
    static func main() throws {
        switch URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent {
        case "LocationRaceCheck": try LocationRaceCheck.run()
        case "RouteProcessRecoveryCheck": try RouteProcessRecoveryCheck.run()
        case "SharedRouteCheck": try SharedRouteCheck.run()
        case "WidgetActionProgressCheck": try WidgetActionProgressCheck.run()
        default: fatalError("Unknown process check")
        }
    }
}
