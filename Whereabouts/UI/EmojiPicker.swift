import SwiftUI

struct EmojiPickerButton: View {
    @Binding var shortcode: String
    @Binding var unicode: String?
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            HStack {
                Text(unicode ?? EmojiCatalog.unicode(for: shortcode) ?? shortcode).font(.title2)
                Spacer()
                Text("Choose emoji")
                Image(systemName: "chevron.right").font(.caption)
            }
        }
        .accessibilityIdentifier("emojiPickerButton")
        .sheet(isPresented: $presented) {
            EmojiPicker { code, glyph in
                shortcode = code
                unicode = glyph
            }
        }
    }
}

private struct EmojiPicker: View {
    let select: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("Whereabouts.recentEmoji") private var recentCodes = ""
    @State private var query = ""
    @State private var custom = ""
    @State private var showCustom = false
    private let columns = [GridItem(.adaptive(minimum: 48))]
    private var filtered: [EmojiEntry] {
        EmojiCatalog.entries.filter { $0.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    private var recent: [String] { recentCodes.split(separator: "|").map(String.init) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DisclosureGroup("Custom workspace emoji", isExpanded: $showCustom) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter a Slack shortcode. Custom emoji have no Unicode character.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField(":my-team:", text: $custom)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("customEmoji")
                            Button("Use custom emoji") {
                                if let code = EmojiCatalog.customShortcode(custom) {
                                    pick(code, unicode: EmojiCatalog.unicode(for: code))
                                }
                            }.disabled(EmojiCatalog.customShortcode(custom) == nil)
                        }.padding(.top, 8)
                    }
                    if query.isEmpty && !recent.isEmpty {
                        Text("Recent").font(.headline)
                        LazyVGrid(columns: columns) {
                            ForEach(recent, id: \.self) { code in
                                emojiButton(code, unicode: EmojiCatalog.unicode(for: code))
                            }
                        }
                    }
                    ForEach(EmojiCatalog.categories, id: \.self) { category in
                        let entries = filtered.filter { $0.category == category }
                        if !entries.isEmpty {
                            Text(category).font(.headline)
                            LazyVGrid(columns: columns) {
                                ForEach(entries) { entry in
                                    emojiButton(entry.shortcode, unicode: entry.unicode)
                                }
                            }
                        }
                    }
                    if filtered.isEmpty { Text("No emoji found. Try another search or use a custom shortcode.").foregroundStyle(.secondary) }
                }.padding()
            }
            .navigationTitle("Choose emoji")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func emojiButton(_ code: String, unicode: String?) -> some View {
        Button { pick(code, unicode: unicode) } label: {
            Text(unicode ?? code).font(unicode == nil ? .caption : .title)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(code)
    }

    private func pick(_ code: String, unicode: String?) {
        recentCodes = ([code] + recent.filter { $0 != code }).prefix(24).joined(separator: "|")
        select(code, unicode)
        dismiss()
    }
}
