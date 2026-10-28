import SwiftUI

struct DestinationsView: View {
    let runtime: LocationRuntime
    @State private var configuredIDs: Set<String> = []
    var body: some View {
        List {
            ForEach(runtime.destinations.destinations, id: \.id) { destination in
                Section {
                    NavigationLink {
                        if destination.id == "slack" {
                            SlackSetupView(runtime: runtime)
                        } else {
                            ContentUnavailableView("Setup unavailable", systemImage: "gear")
                        }
                    } label: {
                        Label(destination.displayName, systemImage: "paperplane")
                    }
                    Toggle("Send status", isOn: Binding(
                        get: { runtime.destinations.enabledIDs.contains(destination.id) },
                        set: { runtime.destinations.setEnabled($0, for: destination.id); runtime.refreshMonitoring() }
                    ))
                    Text(configuredIDs.contains(destination.id) ? "Token saved" : "Setup required")
                        .font(.caption).foregroundStyle(.secondary)
                } footer: { Text("Choose where to send your location status.") }
            }
        }.navigationTitle("Destinations")
            .onAppear { configuredIDs = Set(runtime.destinations.destinations.filter { $0.isConfigured }.map(\.id)) }
    }
}

struct SlackSetupView: View {
    let runtime: LocationRuntime
    @State private var token = ""
    @State private var hasToken = false
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?
    @State private var confirmRemoval = false
    var body: some View {
        Form {
            Section("User OAuth token") {
                SecureField("Paste token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(hasToken ? "A token is saved in the Keychain." : "No token saved.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Test and save") { Task { await testAndSave() } }
                    .disabled(busy || (token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasToken))
                if busy { ProgressView("Test token") }
                if let result { Text(result).foregroundStyle(.green) }
                if let error { ErrorText(message: error) }
                if hasToken {
                    Button("Remove token", role: .destructive) { confirmRemoval = true }.disabled(busy)
                }
            }
            Section("Set up Slack") {
                Text("1. Make a Slack app for your workspace.")
                Text("2. Add the users.profile:write user scope.")
                Text("3. Install the app in your workspace.")
                Text("4. Copy the User OAuth Token here, then tap Test and save.")
                Text("The token stays in this device’s Keychain.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Slack setup")
            .onAppear {
                do { hasToken = try KeychainTokenStore().read() != nil }
                catch { self.error = error.localizedDescription }
            }
            .confirmationDialog("Remove saved token?", isPresented: $confirmRemoval) {
                Button("Remove token", role: .destructive) {
                    do {
                        try KeychainTokenStore().delete()
                        hasToken = false; token = ""; result = nil; error = nil
                        runtime.refreshMonitoring()
                    } catch { self.error = error.localizedDescription }
                }
            }
    }
    @MainActor private func testAndSave() async {
        busy = true; error = nil; result = nil
        defer { busy = false }
        do {
            let input = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = input.isEmpty ? SlackClient() : SlackClient(token: input)
            let identity = try await client.validateToken()
            if !input.isEmpty { try KeychainTokenStore().save(input) }
            hasToken = true; token = ""
            result = "Connected as \(identity.user) in \(identity.team)."
            runtime.refreshMonitoring()
        } catch { self.error = error.localizedDescription }
    }
}
