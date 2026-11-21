import Foundation

// The daemon's wire types (docs/api.md). IDs are strings and times are Unix
// milliseconds, 0 for none. Decoded with `.convertFromSnakeCase`.

nonisolated struct User: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var username: String
    var name: String
    var avatarUrl: String = ""

    /// The name to show: full name, else the username.
    var displayName: String { name.isEmpty ? username : name }
}

nonisolated struct Reaction: Codable, Hashable, Sendable {
    var userId: String
    var emoji: String
    var id: String
}

nonisolated struct Quote: Codable, Hashable, Sendable {
    var id: String
    var senderId: String
    var text: String
    var contentType: String
}

nonisolated struct Message: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var threadId: String
    var senderId: String
    var atMs: Int64
    var text: String
    var contentType: String
    var otid: String
    var replyTo: Quote?
    var reactions: [Reaction]
    var editedAtMs: Int64
    var unsent: Bool
    /// Photos, videos, GIFs or a sticker, in order; empty for text.
    var media: [Media] = []

    var date: Date { Date(timeIntervalSince1970: Double(atMs) / 1000) }

    /// What to show for the message: its text, or a label for what it is.
    var summary: String {
        if unsent { return "Message unsent" }
        return text.isEmpty ? ContentLabel.label(for: contentType) : text
    }
}

/// One attachment that can be shown. Its URLs expire: they come fresh with
/// each history fetch and need no login.
nonisolated struct Media: Codable, Hashable, Sendable {
    /// "image", "video", "gif" or "sticker". A string, so a kind a newer
    /// daemon adds doesn't stop the message decoding.
    var kind: String
    /// The full image, or the video or animation.
    var url: String
    /// A still for it.
    var previewUrl: String
    var width: Int
    var height: Int

    /// The still to show in the conversation.
    var thumbnail: URL? { URL(string: previewUrl.isEmpty && !plays ? url : previewUrl) }
    /// What opens in the viewer.
    var full: URL? { URL(string: url.isEmpty && !plays ? previewUrl : url) }
    /// Width over height, when the size is known.
    var aspect: CGFloat? { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : nil }
    /// Plays rather than shows. A GIF sent as video is one of these.
    var plays: Bool { kind == "video" }
    /// Shown without a frame, like an emoji.
    var isSticker: Bool { kind == "sticker" }
}

nonisolated struct ChatThread: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var isGroup: Bool
    var imageUrl: String = ""
    var members: [User]
    var lastActivityMs: Int64
    var unread: Bool
    var muted: Bool
    var lastMessage: Message?
    var readUpToMs: [String: Int64]

    /// When the newest message was sent, else the last activity.
    var newestMs: Int64 { lastMessage?.atMs ?? lastActivityMs }

    func member(_ id: String) -> User? { members.first { $0.id == id } }
}

nonisolated enum Connection: String, Codable, Sendable {
    case loggedOut = "logged_out"
    case loginRequired = "login_required"
    case connecting, connected, reconnecting
}

nonisolated struct Snapshot: Codable, Sendable {
    var state: Connection
    var error: String
    var me: User?
    var threads: [ChatThread]
}

/// One event from `GET /v1/events`.
nonisolated enum ServerEvent: Sendable {
    case state(Snapshot)
    case status(Connection, error: String)
    case messageAdded(Message)
    case threadUpdated(ChatThread)
    case threadRead(threadId: String, untilMs: Int64)
    case readReceipt(threadId: String, userId: String, upToMs: Int64)
    case typing(threadId: String, userId: String, active: Bool)
    case reactionAdded(threadId: String, messageId: String, reaction: Reaction)
    case reactionRemoved(threadId: String, messageId: String, userId: String, reactionId: String)
    case messageEdited(threadId: String, messageId: String, text: String, atMs: Int64)
    case messageUnsent(threadId: String, messageId: String)
    case threadMuted(threadId: String, muted: Bool)

    /// Decodes an event by name. Returns nil for a name this app doesn't know,
    /// so a newer daemon can add events without breaking it.
    static func decode(name: String, data: Data) throws -> ServerEvent? {
        let d = JSONDecoder.api
        switch name {
        case "state":
            return .state(try d.decode(Snapshot.self, from: data))
        case "status":
            let b = try d.decode(Body.self, from: data)
            return .status(b.state ?? .connecting, error: b.error ?? "")
        case "message_added":
            return try d.decode(Body.self, from: data).message.map(ServerEvent.messageAdded)
        case "thread_updated":
            return try d.decode(Body.self, from: data).thread.map(ServerEvent.threadUpdated)
        default:
            break
        }
        let b = try d.decode(Body.self, from: data)
        guard let thread = b.threadId else { return nil }
        switch name {
        case "thread_read": return .threadRead(threadId: thread, untilMs: b.untilMs ?? 0)
        case "read_receipt": return .readReceipt(threadId: thread, userId: b.userId ?? "", upToMs: b.upToMs ?? 0)
        case "typing": return .typing(threadId: thread, userId: b.userId ?? "", active: b.active ?? false)
        case "reaction_added":
            guard let r = b.reaction, let m = b.messageId else { return nil }
            return .reactionAdded(threadId: thread, messageId: m, reaction: r)
        case "reaction_removed":
            return .reactionRemoved(threadId: thread, messageId: b.messageId ?? "", userId: b.userId ?? "0", reactionId: b.reactionId ?? "")
        case "message_edited":
            return .messageEdited(threadId: thread, messageId: b.messageId ?? "", text: b.text ?? "", atMs: b.atMs ?? 0)
        case "message_unsent": return .messageUnsent(threadId: thread, messageId: b.messageId ?? "")
        case "thread_muted": return .threadMuted(threadId: thread, muted: b.muted ?? false)
        default: return nil
        }
    }

    /// Every field an event body can carry.
    private struct Body: Decodable {
        var state: Connection?
        var error: String?
        var message: Message?
        var thread: ChatThread?
        var threadId: String?
        var messageId: String?
        var userId: String?
        var untilMs: Int64?
        var upToMs: Int64?
        var atMs: Int64?
        var active: Bool?
        var muted: Bool?
        var text: String?
        var reaction: Reaction?
        var reactionId: String?
    }
}

extension JSONDecoder {
    nonisolated static var api: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// Labels for messages with no text. The daemon passes Instagram's content
/// type through as it is, and the full list isn't known, so this matches on
/// the words in it.
nonisolated enum ContentLabel {
    static func label(for contentType: String) -> String {
        let t = contentType.uppercased()
        let table: [(String, String)] = [
            ("REEL", "Reel"), ("CLIP", "Reel"), ("STORY", "Story"), ("VOICE", "Voice message"),
            ("AUDIO", "Voice message"), ("VIDEO", "Video"), ("IMAGE", "Photo"), ("PHOTO", "Photo"),
            ("GIF", "GIF"), ("STICKER", "Sticker"), ("LINK", "Link"), ("SHARE", "Shared post"),
            ("POST", "Shared post"), ("LIKE", "❤️"), ("CALL", "Call"),
        ]
        return table.first { t.contains($0.0) }?.1 ?? "Message"
    }

    static func symbol(for contentType: String) -> String {
        switch label(for: contentType) {
        case "Reel", "Video": "play.rectangle.fill"
        case "Photo", "GIF", "Sticker", "Story": "photo.fill"
        case "Voice message": "waveform"
        case "Link", "Shared post": "link"
        case "Call": "phone.fill"
        default: "ellipsis.bubble.fill"
        }
    }
}
