import SwiftUI

struct WebhookEditor: View {
    let runtime: LocationRuntime
    @State var configuration: WebhookConfiguration
    @State private var secret = ""
    @State private var replaceSecret = false
    @State private var busy = false
    @State private var result: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Webhook") {
                TextField("Name", text: $configuration.name).accessibilityIdentifier("webhookName")
                TextField("HTTPS URL", text: $configuration.url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("webhookURL")
                Toggle("Send status", isOn: $configuration.enabled).accessibilityIdentifier("webhookEnabled")
            }
            Section("Signing secret") {
                Toggle("Replace saved secret", isOn: $replaceSecret)
                if replaceSecret {
                    SecureField("Optional secret", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("An empty value removes the saved secret.").font(.footnote)
                }
                Text("Secrets stay in the Keychain. Coordinates are never sent.").font(.footnote)
            }
            Section {
                Button("Send test") {
                    Task {
                        busy = true; error = nil; result = nil
                        defer { busy = false }
                        do {
                            // Test the draft without saving it or changing automatic-send deduplication.
                            let secrets = DraftWebhookSecrets(base: runtime.webhooks.secrets,
                                                              replacement: replaceSecret ? secret : nil)
                            var draft = configuration
                            if replaceSecret { draft.hasSecret = !secret.isEmpty }
                            let destination = WebhookDestination(configuration: draft, secrets: secrets)
                            let code = try await destination.sendTest(runtime.currentStatus)
                            result = "Test returned HTTP \(code)."
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy)
                if busy { ProgressView("Send test") }
                if let result { Text(result).foregroundStyle(.green) }
                if let error { ErrorText(message: error) }
            }
        }
        .navigationTitle("Webhook")
        .interactiveDismissDisabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        configuration.name = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        configuration.url = configuration.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        try runtime.saveWebhook(configuration, secret: replaceSecret ? secret : nil)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.disabled(busy)
            }
        }
    }
}

private struct DraftWebhookSecrets: WebhookSecretStore {
    let base: any WebhookSecretStore
    let replacement: String?
    func read(id: UUID) throws -> String? {
        if let replacement { return replacement.isEmpty ? nil : replacement }
        return try base.read(id: id)
    }
    func save(_ secret: String, id: UUID) throws { try base.save(secret, id: id) }
    func delete(id: UUID) throws { try base.delete(id: id) }
}
