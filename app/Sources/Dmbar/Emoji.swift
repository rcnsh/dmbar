import Foundation

/// One emoji from the catalog.
nonisolated struct Emoji: Hashable, Identifiable, Sendable {
    var char: String
    var category: String
    /// Its shortcodes, without colons: "joy", "+1".
    var names: [String]
    /// Lowercase words to search, from its tags and Unicode name.
    var words: [String]

    var id: String { char }
}

/// Every emoji with a shortcode, from gemoji (EmojiData.swift), and searches
/// over them.
nonisolated enum EmojiCatalog {
    static let all: [Emoji] = data.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count == 4, !f[0].isEmpty else { return nil }
        return Emoji(char: f[0], category: f[1], names: f[2].split(separator: " ").map(String.init),
                     words: f[3].lowercased().split(separator: " ").map(String.init))
    }

    /// The picker's sections, in order, with a symbol for each.
    static let categories: [(name: String, symbol: String)] = [
        ("Smileys & Emotion", "face.smiling"), ("People & Body", "hand.wave"), ("Animals & Nature", "pawprint"),
        ("Food & Drink", "fork.knife"), ("Travel & Places", "car"), ("Activities", "soccerball"),
        ("Objects", "lightbulb"), ("Symbols", "heart"), ("Flags", "flag"),
    ]

    private static let byName: [String: String] = {
        var out: [String: String] = [:]
        for e in all { for n in e.names where out[n] == nil { out[n] = e.char } }
        return out
    }()

    private static let nameOf: [String: String] = {
        var out: [String: String] = [:]
        for e in all { if let n = e.names.first { out[e.char] = n } }
        return out
    }()

    /// An emoji's first shortcode, without colons.
    static func name(of emoji: String) -> String? { nameOf[emoji] }

    /// The emoji a shortcode names, without colons.
    static func emoji(named name: String) -> String? { byName[name.lowercased()] }

    /// Emoji matching a query, best first: a shortcode equal to it, then
    /// starting with it, then with a word of the shortcode starting with it,
    /// then a search word starting with it. Shorter shortcodes come first
    /// within each.
    static func search(_ query: String, limit: Int = 60) -> [Emoji] {
        let q = query.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        guard !q.isEmpty else { return [] }
        // Rank, then the shortest matching shortcode, then catalog order.
        var ranked: [(Int, Int, Int, Emoji)] = []
        for (i, e) in all.enumerated() {
            var best = Int.max, length = Int.max
            for n in e.names {
                let rank = n == q ? 0 : n.hasPrefix(q) ? 1 : n.split(separator: "_").contains(where: { $0.hasPrefix(q) }) ? 2 : .max
                if (rank, n.count) < (best, length) { (best, length) = (rank, n.count) }
            }
            if best == .max, e.words.contains(where: { $0.hasPrefix(q) }) { best = 3 }
            if best != .max { ranked.append((best, best == 3 ? 0 : length, i, e)) }
        }
        ranked.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        return ranked.prefix(limit).map(\.3)
    }
}

/// `:shortcode:` handling for the composer.
nonisolated enum Shortcode {
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_+-")

    /// The code being typed just before `cursor`: a colon at the start or
    /// after a space, then at least two shortcode characters. "10:30" isn't
    /// one, as its colon follows a digit.
    static func partial(in text: String, before cursor: String.Index) -> (range: Range<String.Index>, query: String)? {
        var i = cursor
        while i > text.startIndex {
            let prev = text.index(before: i)
            let c = text[prev]
            if c == ":" {
                let atWordStart = prev == text.startIndex || text[text.index(before: prev)].isWhitespace
                let query = String(text[i..<cursor])
                guard atWordStart, query.count >= 2 else { return nil }
                return (prev..<cursor, query)
            }
            guard allowed.contains(Character(c.lowercased())) else { return nil }
            i = prev
        }
        return nil
    }

    /// A code just closed before `cursor`, like `:fire:` with the caret after
    /// its second colon, and its emoji. Nil if the code names none.
    static func closed(in text: String, before cursor: String.Index) -> (range: Range<String.Index>, emoji: String)? {
        guard cursor > text.startIndex, text[text.index(before: cursor)] == ":",
              let open = partial(in: text, before: text.index(before: cursor)),
              let emoji = EmojiCatalog.emoji(named: open.query) else { return nil }
        return (open.range.lowerBound..<cursor, emoji)
    }
}

extension Character {
    /// Drawn as an emoji: one with emoji presentation, or a sequence built on
    /// one (a flag, a skin tone, a keycap, "❤️").
    nonisolated var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        // A text symbol (©, ™, ▶) needs U+FE0F to be drawn as emoji, except a
        // lone "❤": Instagram strips the U+FE0F from "❤️".
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
            || (unicodeScalars.count == 1 && first == "\u{2764}")
    }
}

extension String {
    /// The text without emoji variation selectors. Instagram drops them, so
    /// a "❤️" sent comes back as "❤": compare emoji in this form.
    nonisolated var withoutVariationSelectors: String {
        String(String.UnicodeScalarView(unicodeScalars.filter { $0.value != 0xFE0F && $0.value != 0xFE0E }))
    }

    /// Whether two emoji are the same once variation selectors are ignored.
    nonisolated func sameEmoji(as other: String) -> Bool {
        withoutVariationSelectors == other.withoutVariationSelectors
    }

    /// How many emoji the text is, if it is only emoji (spaces aside) and at
    /// most three of them; otherwise nil. Such a message is shown large.
    nonisolated var jumboEmojiCount: Int? {
        let chars = filter { !$0.isWhitespace }
        guard !chars.isEmpty, chars.count <= 3, chars.allSatisfy(\.isEmoji) else { return nil }
        return chars.count
    }
}
