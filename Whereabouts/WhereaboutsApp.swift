import SwiftUI

@main
struct WhereaboutsApp: App {
    @UIApplicationDelegateAdaptor(LocationAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
