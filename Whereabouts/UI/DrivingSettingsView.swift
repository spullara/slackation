import SwiftUI

struct DrivingSettingsView: View {
    let runtime: LocationRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var status = OtherStatus(text: "Driving", emoji: ":car:")
    @State private var initialized = false

    var body: some View {
        Form {
            Section {
                Toggle("Detect driving", isOn: Binding(get: { runtime.driving.enabled }, set: { runtime.driving.setEnabled($0) }))
            } footer: {
                Text("Use motion activity to detect driving. Saved places take priority over Driving.")
            }
            Section("Driving status") {
                TextField("Status text", text: $status.text)
                EmojiPickerButton(shortcode: $status.emoji, unicode: $status.emojiUnicode)
            }
            Section {
                Text("Driving ends after two minutes of stationary or walking activity. Background updates need Always location access.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Driving")
        .onAppear {
            if !initialized { status = runtime.driving.status; initialized = true }
        }
        .toolbar {
            Button("Save") { runtime.driving.saveStatus(status); dismiss() }
        }
    }
}
