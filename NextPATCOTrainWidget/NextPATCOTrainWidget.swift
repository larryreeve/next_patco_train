import ActivityKit
import CoreLocation
import MapKit
import SwiftUI
import WidgetKit
import AppIntents

@main
struct NextPATCOTrainWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextPATCOTrainHomeWidget()
        NextPATCOLockScreenWidget()
        PATCOTripLiveActivityWidget()
    }
}
