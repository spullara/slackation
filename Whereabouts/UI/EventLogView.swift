import SwiftUI

struct EventLogView: View {
    let log: EventLog
    @State private var filter = "All"
    private let filters = ["All", "Status", "Driving", "Geofence", "Sends"]
    private var events: [LogEvent] {
        log.events.filter {
            switch filter {
            case "Status": $0.kind == .status
            case "Driving": [.driving, .motion, .liveLocation].contains($0.kind)
            case "Geofence": $0.kind == .geofence
            case "Sends": $0.kind == .send
            default: true
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(filters, id: \.self) { item in
                        Button(item) { filter = item }
                            .buttonStyle(.bordered)
                            .tint(filter == item ? .accentColor : .secondary)
                            .accessibilityAddTraits(filter == item ? .isSelected : [])
                    }
                }.padding(.horizontal)
            }
            if let error = log.storageError { ErrorText(message: error) }
            List(events) { event in
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.text)
                        Text(event.date, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: event.kind.icon) }
            }
            .overlay { if events.isEmpty { ContentUnavailableView("No events", systemImage: "list.bullet") } }
        }
        .navigationTitle("Event log")
        .toolbar {
            ShareLink(item: log.exportText()) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Clear", role: .destructive) { log.clear() }
        }
        .onAppear { log.prune() }
    }
}
