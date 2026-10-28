import SwiftUI

struct ContentView: View {
    var body: some View {
        ContentUnavailableView("Slackation", systemImage: "location.circle",
                               description: Text("Slack status from your saved places."))
    }
}
