import AppIntents
import SwiftUI

@main
struct NextPATCOTrainApp: App {
    init() {
        PATCOAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
