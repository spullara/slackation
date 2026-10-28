import SwiftUI

@main
struct SlackationApp: App {
    @UIApplicationDelegateAdaptor(LocationAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
