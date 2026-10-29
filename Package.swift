// swift-tools-version: 5.9
import PackageDescription

// The iOS app stays in Xcode. Tests compile its shared logic once, without copying sources.
let package = Package(
    name: "PATCORegression",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PATCOLogic",
            path: "NextPATCOTrain",
            exclude: [
                "AlertViews.swift",
                "Assets.xcassets",
                "ContentView.swift",
                "DepartureDetailView.swift",
                "DepartureListView.swift",
                "FarePresentation.swift",
                "HomeAlertsView.swift",
                "HomeDeparturesHeader.swift",
                "HomeDeparturesSection.swift",
                "HomeRouteController.swift",
                "HomeRouteHeader.swift",
                "HomeScheduleController.swift",
                "HomeScheduleDatePicker.swift",
                "HomeScreenContent.swift",
                "HomeScreenModel.swift",
                "HomeSpecialScheduleBanner.swift",
                "HomeStationPanel.swift",
                "Info.plist",
                "InformationViews.swift",
                "NextPATCOTrain.entitlements",
                "NextPATCOTrainApp.swift",
                "PATCOAppIntents.swift",
                "PATCOGTFSAdapters.swift",
                "PATCOTripActivityAttributes.swift",
                "Resources",
                "SavedRoutesView.swift",
                "StationInformationView.swift",
                "TripFareSummary.swift",
                "TripJourneySummary.swift",
                "TripRouteMap.swift",
                "TripStopTimeline.swift",
                "TripTrackingController.swift"
            ],
            sources: [
                "PATCOModels.swift",
                "Core",
                "JourneyCoordinator.swift",
                "SharedRoutePersistence.swift",
                "HomeReachabilityPresentation.swift",
                "Reachability.swift",
                "PATCOColors.swift",
                "TripDetailPresentation.swift",
                "JourneyLocationController.swift",
                "PATCOGTFSUpdateService.swift",
                "RoutePreferences.swift",
                "TravelEstimateController.swift",
                "WidgetReloadCoordinator.swift",
                "AppRefreshCoordinator.swift",
                "LocationProvider.swift",
                "SavedRouteStore.swift",
                "PATCOAlertProvider.swift",
                "PATCOSpecialScheduleProvider.swift"
            ]
        ),
        .testTarget(
            name: "AppRegressionTests",
            dependencies: ["PATCOLogic"],
            path: "Tests",
            exclude: ["UI", "Fixtures", "README.md", "run-checks.sh", "run-ui-checks.sh",
                      "Support/ProcessCheckMain.swift"]
        )
    ]
)
