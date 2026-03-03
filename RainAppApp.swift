//
//  RainAppApp.swift
//  RainApp
//
//  Created by Alexander Savchenko on 2/7/26.
//

import SwiftUI
import SwiftData
import CoreLocation

@main
struct RainAppApp: App {
    @State private var selectedHour = Calendar.current.component(.hour, from: Date())

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(selectedHour: $selectedHour)
        }
        .modelContainer(sharedModelContainer)
    }
}

final class PushNotificationService {
    static let shared = PushNotificationService()
    private init() {}

    func registerDeviceIfPossible(location: CLLocation) {
        // Old ContentView expects this API; keep as no-op in this snapshot mix.
    }
}
