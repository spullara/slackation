import SwiftUI

struct DestinationsView: View {
    let runtime: LocationRuntime
    @State private var hasSlackToken = false
    @State private var editing: WebhookConfiguration?
    @State private var error: String?
    var body: some View {
        List {
            Section {
                NavigationLink { SlackSetupView(runtime: runtime) } label: {
                    Label("Slack", systemImage: "paperplane")
                }
                Toggle("Send status", isOn: Binding(
                    get: { runtime.destinations.enabledIDs.contains("slack") },
                    set: { runtime.destinations.setEnabled($0, for: "slack"); runtime.refreshMonitoring() }
                ))
                Text(hasSlackToken ? "Token saved" : "Setup required")
                    .font(.caption).foregroundStyle(.secondary)
            } footer: { Text("Choose where to send your location status.") }
            Section("Webhooks") {
                ForEach(runtime.webhooks.configurations) { webhook in
                    VStack(alignment: .leading) {
                        Button { editing = webhook } label: {
                            Label(webhook.name, systemImage: "network")
                        }
                        Toggle("Send to \(webhook.name)", isOn: Binding(
                            get: { webhook.enabled },
                            set: { enabled in
                                var updated = webhook
                                updated.enabled = enabled
                                do { try runtime.saveWebhook(updated, secret: nil) }
                                catch { self.error = error.localizedDescription }
                            }
                        ))
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            do { try runtime.deleteWebhook(webhook) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
                Button("Add webhook", systemImage: "plus") { editing = WebhookConfiguration() }
            }
            if let error { ErrorText(message: error) }
        }.navigationTitle("Destinations")
            .onAppear { hasSlackToken = runtime.destinations.destinations.first { $0.id == "slack" }?.isConfigured == true }
            .sheet(item: $editing) { configuration in
                NavigationStack { WebhookEditor(runtime: runtime, configuration: configuration) }
            }
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
