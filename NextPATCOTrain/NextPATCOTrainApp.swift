import AppIntents
import SwiftUI

@main
struct NextPATCOTrainApp: App {
    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-arrivalScreenPreview") { return }
        #endif
        PATCOAppShortcuts.updateAppShortcutParameters()
        DestinationRegionMonitor.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-arrivalScreenPreview") {
                ArrivalScreenPreview.screen
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}
