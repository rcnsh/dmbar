import Foundation
import Testing

@testable import Dmbar

private let me = User(id: "1", username: "me", name: "Me")
private let alice = User(id: "2", username: "alice", name: "Alice")

private func message(_ id: String, thread: String = "20", from: User = alice, at: Int64, text: String = "hi", otid: String = "") -> Message {
    Message(id: id, threadId: thread, senderId: from.id, atMs: at, text: text, contentType: "TEXT", otid: otid,
            replyTo: nil, reactions: [], editedAtMs: 0, unsent: false)
}

private func inbox() -> Inbox {
    var i = Inbox()
    i.apply(.state(Snapshot(state: .connected, error: "", me: me, threads: [
        ChatThread(id: "10", title: "Old", isGroup: false, members: [], lastActivityMs: 100, unread: false, muted: false, lastMessage: nil, readUpToMs: [:]),
        ChatThread(id: "20", title: "Alice", isGroup: false, members: [alice], lastActivityMs: 200, unread: false, muted: false,
                   lastMessage: message("m1", at: 200), readUpToMs: [:]),
    ])))
    return i
}

@Suite struct InboxTests {
    @Test func `a new message moves its thread up and marks it unread`() {
        var i = inbox()
        #expect(i.threads.map(\.id) == ["20", "10"])
        let m = message("m9", thread: "10", at: 300)
        #expect(i.shouldNotify(m))
        i.apply(.messageAdded(m))
        #expect(i.threads.map(\.id) == ["10", "20"])
        #expect(i.threads[0].unread && i.threads[0].lastMessage?.id == "m9")
        #expect(i.unreadCount == 1)
    }

    @Test func `a repeat or an older message changes nothing and doesn't notify`() {
        var i = inbox()
        let m = message("m2", at: 300)
        i.apply(.messageAdded(m))
        i.apply(.threadRead(threadId: "20", untilMs: 300))
        #expect(i.unreadCount == 0)
        #expect(!i.shouldNotify(m))
        #expect(!i.shouldNotify(message("m0", at: 150)))
        i.apply(.messageAdded(m))
        i.apply(.messageAdded(message("m0", at: 150)))
        #expect(i.unreadCount == 0)
        #expect(i.thread("20")?.lastMessage?.id == "m2")
    }

    @Test func `own and muted messages don't notify`() {
        var i = inbox()
        #expect(!i.shouldNotify(message("mine", from: me, at: 300)))
        i.apply(.threadMuted(threadId: "20", muted: true))
        #expect(!i.shouldNotify(message("m2", at: 300)))
        i.apply(.messageAdded(message("m2", at: 300)))
        #expect(i.unreadCount == 0, "muted threads stay out of the count")
    }

    @Test func `seen here hides the unread mark until something newer arrives`() {
        var i = inbox()
        i.apply(.messageAdded(message("m2", at: 300)))
        i.seenMs["20"] = 300
        #expect(i.unreadCount == 0)
        i.apply(.messageAdded(message("m3", at: 400)))
        #expect(i.unreadCount == 1)
    }

    @Test func `an echo replaces its pending copy, by otid or by text`() {
        var i = inbox()
        i.load([message("m1", at: 200)], more: false, thread: "20", before: nil)
        i.pending = [
            Pending(id: UUID(), threadId: "20", text: "first", otid: "o1", createdAt: .now),
            Pending(id: UUID(), threadId: "20", text: "second", otid: nil, createdAt: .now),
        ]
        i.apply(.messageAdded(message("s1", from: me, at: 300, text: "first", otid: "o1")))
        #expect(i.pending.map(\.text) == ["second"])
        i.apply(.messageAdded(message("s2", from: me, at: 310, text: "second", otid: "o2")))
        #expect(i.pending.isEmpty)
        #expect(i.messages["20"]?.map(\.id) == ["m1", "s1", "s2"])
        #expect(i.thread("20")?.unread == false)
    }

    @Test func `history pages join without duplicates and keep live messages`() {
        var i = inbox()
        i.messages["20"] = [message("live", at: 500)]  // arrived while the first page loaded
        i.load([message("m3", at: 300), message("m4", at: 400)], more: true, thread: "20", before: nil)
        #expect(i.messages["20"]?.map(\.id) == ["m3", "m4", "live"])
        i.load([message("m1", at: 100), message("m3", at: 300)], more: false, thread: "20", before: "m3")
        #expect(i.messages["20"]?.map(\.id) == ["m1", "m3", "m4", "live"])
        #expect(i.hasOlder["20"] == false)
    }

    @Test func `reactions, edits and unsends reach loaded messages and the preview`() {
        var i = inbox()
        i.load([message("m1", at: 200)], more: false, thread: "20", before: nil)
        i.apply(.reactionAdded(threadId: "20", messageId: "m1", reaction: Reaction(userId: "2", emoji: "a", id: "r1")))
        i.apply(.reactionAdded(threadId: "20", messageId: "m1", reaction: Reaction(userId: "2", emoji: "b", id: "r2")))
        #expect(i.messages["20"]?[0].reactions.map(\.emoji) == ["b"])
        #expect(i.thread("20")?.lastMessage?.reactions.count == 1)
        i.apply(.reactionRemoved(threadId: "20", messageId: "other", userId: "0", reactionId: "r2"))
        #expect(i.messages["20"]?[0].reactions.isEmpty == true)
        i.apply(.messageEdited(threadId: "20", messageId: "m1", text: "edited", atMs: 250))
        #expect(i.thread("20")?.lastMessage?.text == "edited")
        i.apply(.messageUnsent(threadId: "20", messageId: "m1"))
        #expect(i.messages["20"]?[0].summary == "Message unsent")
    }

    @Test func `typing lasts until it expires or the message arrives`() {
        var i = inbox()
        let now = Date(timeIntervalSince1970: 1000)
        i.apply(.typing(threadId: "20", userId: "2", active: true), now: now)
        #expect(i.typists(in: "20", now: now.addingTimeInterval(5)).map(\.id) == ["2"])
        #expect(i.typists(in: "20", now: now.addingTimeInterval(9)).isEmpty)
        i.apply(.messageAdded(message("m2", at: 300)))
        #expect(i.typists(in: "20", now: now.addingTimeInterval(1)).isEmpty)
    }

    @Test func `the first message of a thread the inbox didn't have still notifies`() {
        var i = inbox()
        let m = message("n1", thread: "30", at: 900)
        // The daemon sends the thread first, already holding the message.
        i.apply(.threadUpdated(ChatThread(id: "30", title: "New", isGroup: false, members: [alice], lastActivityMs: 900,
                                          unread: true, muted: false, lastMessage: m, readUpToMs: [:])))
        #expect(i.shouldNotify(m))
        i.apply(.messageAdded(m))
        #expect(!i.shouldNotify(m), "but only once")
        // A rename of a known thread doesn't make its newest message news again.
        i.apply(.threadUpdated(i.thread("20")!))
        #expect(!i.shouldNotify(message("m1", at: 200)))
    }

    @Test func `a send whose echo was missed is settled by the history`() {
        var i = inbox()
        i.pending = [
            Pending(id: UUID(), threadId: "20", text: "hello", otid: "o1", createdAt: .now),
            Pending(id: UUID(), threadId: "20", text: "still going", otid: "o2", createdAt: .now),
        ]
        i.load([message("m1", at: 200), message("s1", from: me, at: 300, text: "hello", otid: "o1")], more: false, thread: "20", before: nil)
        #expect(i.pending.map(\.text) == ["still going"])
    }

    @Test func `another account clears what was loaded`() {
        var i = inbox()
        i.load([message("m1", at: 200)], more: false, thread: "20", before: nil)
        i.apply(.state(Snapshot(state: .loggedOut, error: "", me: nil, threads: [])))
        #expect(i.messages.isEmpty && i.threads.isEmpty)
    }
}

@Suite struct WireTests {
    @Test func `events decode from the daemon's JSON`() throws {
        var parser = EventParser()
        let comment = parser.feed(": ping")
        let nameOnly = parser.feed("event: message_added")
        #expect(comment == nil && nameOnly == nil)
        let json = #"data: {"message":{"id":"m1","thread_id":"20","sender_id":"2","at_ms":1700000000123,"text":"yo","content_type":"TEXT","otid":"","reply_to":null,"reactions":[{"user_id":"1","emoji":"x","id":"r"}],"edited_at_ms":0,"unsent":false,"media":[{"kind":"image","url":"https://cdn.example/a.jpg","preview_url":"","width":1080,"height":1350}]}}"#
        let fed = parser.feed(json)
        let (name, data) = try #require(fed)
        guard case .messageAdded(let m)? = try ServerEvent.decode(name: name, data: data) else {
            Issue.record("not a message_added")
            return
        }
        #expect(m.atMs == 1_700_000_000_123 && m.threadId == "20" && m.reactions.first?.userId == "1")
        #expect(m.media.first?.full?.absoluteString == "https://cdn.example/a.jpg" && m.media.first?.aspect == 0.8)
    }

    @Test func `the state event decodes, with IDs past 2^53 intact`() throws {
        let json = #"{"state":"connected","error":"","me":{"id":"9007199254740993","username":"me","name":"Me","avatar_url":""},"threads":[{"id":"20","title":"A","is_group":false,"image_url":"","members":[{"id":"2","username":"a","name":"A","avatar_url":"https://x/y.jpg"}],"last_activity_ms":5,"unread":true,"muted":false,"last_message":null,"read_up_to_ms":{"2":4}}]}"#
        guard case .state(let s)? = try ServerEvent.decode(name: "state", data: Data(json.utf8)) else {
            Issue.record("not a state")
            return
        }
        #expect(s.me?.id == "9007199254740993")
        #expect(s.threads[0].members[0].avatarUrl == "https://x/y.jpg")
        #expect(s.threads[0].readUpToMs["2"] == 4)
    }

    @Test func `an unknown event is skipped, not an error`() throws {
        #expect(try ServerEvent.decode(name: "something_new", data: Data("{}".utf8)) == nil)
    }

    @Test(arguments: [("IMAGE", "Photo"), ("REEL_SHARE", "Reel"), ("VOICE_MEDIA", "Voice message"), ("WHO_KNOWS", "Message")])
    func `content types get a label`(type: String, label: String) {
        #expect(ContentLabel.label(for: type) == label)
    }
}

@Suite struct SettingsTests {
    @Test func `the shortcut defaults to control-option-I and a removed one stays removed`() throws {
        let name = "dmbar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Settings(defaults: defaults).shortcut == .standard)
        Settings(defaults: defaults).shortcut = nil
        #expect(Settings(defaults: defaults).shortcut == nil)
        let custom = Shortcut(keyCode: 46, modifiers: 256, key: "m")
        Settings(defaults: defaults).shortcut = custom
        #expect(Settings(defaults: defaults).shortcut == custom)
        #expect(custom.display == "⌘M")
    }
}
