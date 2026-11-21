import SwiftUI

/// A searchable grid of every emoji, with the recent ones first. Used for
/// the composer and for reacting.
struct EmojiPicker: View {
    @Environment(AppModel.self) private var model
    var pick: (String) -> Void

    @State private var query = ""
    @State private var jumpTo: String?
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 9)

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search emoji", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { choose(first.char) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        if query.isEmpty {
                            let recent = model.settings.recentEmoji
                            if !recent.isEmpty { section("Recent", recent) }
                            ForEach(EmojiCatalog.categories, id: \.name) { c in
                                section(c.name, Self.grouped[c.name] ?? [])
                            }
                        } else {
                            ForEach(results) { cell($0.char, name: $0.names.first) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: 250)
                .overlay {
                    if !query.isEmpty, results.isEmpty {
                        Text("No emoji").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: jumpTo) { _, s in
                    guard let s else { return }
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(s, anchor: .top) }
                    jumpTo = nil
                }
            }
            if query.isEmpty {
                HStack(spacing: 0) {
                    ForEach(EmojiCatalog.categories, id: \.name) { c in
                        Button { jumpTo = c.name } label: {
                            Image(systemName: c.symbol).frame(maxWidth: .infinity, minHeight: 22).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(c.name)
                        .accessibilityLabel(c.name)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private var results: [Emoji] { EmojiCatalog.search(query, limit: 120) }

    private static let grouped: [String: [String]] = Dictionary(grouping: EmojiCatalog.all, by: \.category).mapValues { $0.map(\.char) }

    @ViewBuilder private func section(_ title: String, _ chars: [String]) -> some View {
        Section {
            // Keyed by section too: an emoji can be in Recent and its own
            // section, and the grid drops a repeated ID.
            ForEach(chars.map { title + "/" + $0 }, id: \.self) { key in
                cell(String(key.dropFirst(title.count + 1)), name: nil)
            }
        } header: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .background(.background.opacity(0.9))
                .id(title)
        }
    }

    private func cell(_ char: String, name: String?) -> some View {
        Button { choose(char) } label: {
            Text(char).font(.system(size: 22)).frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(EmojiCellStyle())
        .help(name.map { ":\($0):" } ?? EmojiCatalog.name(of: char).map { ":\($0):" } ?? "")
    }

    private func choose(_ char: String) {
        model.settings.useEmoji(char)
        pick(char)
    }
}

/// A cell that lights up under the pointer.
struct EmojiCellStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0), in: .rect(cornerRadius: 6))
            .onHover { hovering = $0 }
    }
}

/// The reactions offered first, as Instagram offers them.
enum QuickReactions {
    static let all = ["❤️", "😂", "😮", "😢", "😡", "👍"]
}

/// The quick reactions in a row, and the whole picker behind "+".
struct ReactionPicker: View {
    var current: String?
    var pick: (String) -> Void
    @State private var more = false

    var body: some View {
        if more {
            EmojiPicker(pick: pick)
        } else {
            HStack(spacing: 2) {
                ForEach(QuickReactions.all, id: \.self) { e in
                    Button { pick(e) } label: {
                        Text(e).font(.system(size: 24)).frame(width: 36, height: 36).contentShape(.rect)
                    }
                    .buttonStyle(EmojiCellStyle())
                    .background(current.map(e.sameEmoji) == true ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                    .help(current.map(e.sameEmoji) == true ? "Remove" : EmojiCatalog.name(of: e).map { ":\($0):" } ?? "")
                }
                Button { more = true } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36).contentShape(.rect)
                }
                .buttonStyle(EmojiCellStyle())
                .foregroundStyle(.secondary)
                .help("More emoji")
                .accessibilityLabel("More emoji")
            }
            .padding(6)
        }
    }
}

/// Emoji matching the `:shortcode` being typed, above the composer. Tab or
/// Return takes the highlighted one, the arrows move, Escape hides them.
struct ShortcodeSuggestions: View {
    var emoji: [Emoji]
    var highlighted: Int
    var pick: (Emoji) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(emoji.enumerated()), id: \.element.id) { i, e in
                Button { pick(e) } label: {
                    HStack(spacing: 8) {
                        Text(e.char).font(.system(size: 18))
                        Text(":\(e.names.first ?? ""):").font(.callout)
                        Spacer()
                        if i == highlighted {
                            Text("⇥").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(i == highlighted ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emoji suggestions")
    }
}
