import Testing

@testable import Dmbar

@Suite struct EmojiTests {
    @Test func `the catalog has gemoji's shortcodes`() {
        #expect(EmojiCatalog.all.count > 1500)
        #expect(EmojiCatalog.emoji(named: "joy") == "😂")
        #expect(EmojiCatalog.emoji(named: "+1") == "👍")
        #expect(EmojiCatalog.emoji(named: "nope_not_one") == nil)
    }

    @Test func `search puts an exact shortcode first`() {
        #expect(EmojiCatalog.search("fire").first?.char == "🔥")
        #expect(EmojiCatalog.search(":heart").first?.char == "❤️")
        #expect(EmojiCatalog.search("hea").first?.char == "❤️", "heart is the shortest match")
        #expect(EmojiCatalog.search("").isEmpty)
    }

    @Test func `a partial code is found before the cursor`() {
        let text = "gn :sle"
        let p = Shortcode.partial(in: text, before: text.endIndex)
        #expect(p?.query == "sle")
        #expect(p.map { String(text[$0.range]) } == ":sle")
    }

    @Test(arguments: ["see you at 10:30", "a :b", "no code here", "word:joy"])
    func `not a partial code`(text: String) {
        #expect(Shortcode.partial(in: text, before: text.endIndex) == nil)
    }

    @Test func `a code closed before the cursor becomes its emoji`() {
        let text = "gn :fire: x"
        let cursor = text.index(text.startIndex, offsetBy: 9)
        let c = Shortcode.closed(in: text, before: cursor)
        #expect(c?.emoji == "🔥")
        #expect(c.map { String(text[$0.range]) } == ":fire:")
        #expect(Shortcode.closed(in: "a :nope:", before: "a :nope:".endIndex) == nil)
        #expect(Shortcode.closed(in: "10:30:", before: "10:30:".endIndex) == nil)
    }

    @Test func `a reaction matches whether or not it has a variation selector`() {
        #expect("❤️".sameEmoji(as: "❤"))
        #expect(!"❤️".sameEmoji(as: "😂"))
    }

    @Test func `only short runs of emoji are shown large`() {
        #expect("🔥".jumboEmojiCount == 1)
        #expect("❤️ 🇬🇧 👍🏽".jumboEmojiCount == 3)
        #expect("🔥🔥🔥🔥".jumboEmojiCount == nil)
        #expect("ok 🔥".jumboEmojiCount == nil)
        #expect("1".jumboEmojiCount == nil)
        #expect("❤".jumboEmojiCount == 1, "a heart as Instagram returns it, without U+FE0F")
        #expect("™".jumboEmojiCount == nil && "©".jumboEmojiCount == nil)
        #expect("".jumboEmojiCount == nil)
    }
}
