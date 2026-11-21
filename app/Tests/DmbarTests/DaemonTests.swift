import Foundation
import Testing

@testable import Dmbar

/// Where `make build` puts the daemon, relative to this file.
private nonisolated let dmbard = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "bin/dmbard")

/// The Swift client against the real daemon binary serving its demo inbox:
/// the two halves agree on the wire format, with no account involved.
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: dmbard.path), "run `make build` first"), .timeLimit(.minutes(1)))
struct DaemonTests {
    @Test func `the client reads the inbox, pages history and sees its own send echoed`() async throws {
        let process = Process()
        process.executableURL = dmbard
        process.arguments = ["-demo", "-exit-with-stdin", "-log-level", "error"]
        process.environment = ["DMBAR_TOKEN": "test-token"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        defer { process.terminate() }

        struct Ready: Decodable { var addr: String }
        var base: URL?
        for try await line in stdout.fileHandleForReading.bytes.lines {
            base = URL(string: "http://\(try JSONDecoder().decode(Ready.self, from: Data(line.utf8)).addr)/")
            break
        }
        let client = Client(base: try #require(base), token: "test-token")

        var inbox = Inbox()
        var events = client.events().makeAsyncIterator()
        // The stream opens with the state; wait until the demo is connected.
        while inbox.connection != .connected || inbox.threads.isEmpty {
            inbox.apply(try #require(try await events.next()))
        }
        #expect(inbox.me?.username == "you")
        #expect(inbox.threads.first?.title == "Mara Lindqvist")
        #expect(inbox.unreadCount == 2, "Mara and the group are unread; the muted chat isn't counted")

        let newest = try await client.history(thread: "101", before: nil, limit: 10)
        #expect(newest.messages.count == 10 && newest.more)
        inbox.load(newest.messages, more: newest.more, thread: "101", before: nil)
        let older = try await client.history(thread: "101", before: newest.messages[0].id, limit: 10)
        inbox.load(older.messages, more: older.more, thread: "101", before: newest.messages[0].id)
        let loaded = try #require(inbox.messages["101"])
        #expect(loaded.count == 20 && loaded == loaded.sorted { $0.atMs < $1.atMs })

        inbox.pending = [Pending(id: UUID(), threadId: "101", text: "hello from the test", createdAt: .now)]
        let otid = try await client.send(thread: "101", text: "hello from the test", otid: nil, replyTo: nil)
        var echoed: Message?
        while echoed == nil {
            let event = try #require(try await events.next())
            inbox.apply(event)
            if case .messageAdded(let m) = event, m.otid == otid { echoed = m }
        }
        #expect(echoed?.senderId == inbox.me?.id && echoed?.text == "hello from the test")
        #expect(inbox.pending.isEmpty, "the echo replaced the pending copy")
        #expect(inbox.messages["101"]?.last?.id == echoed?.id)

        let last = try #require(inbox.thread("101")?.lastMessage)
        try await client.markRead(thread: "101", messageId: last.id, atMs: last.atMs)
        try await client.typing(thread: "101", active: true)

        await #expect(throws: APIError.self) {
            try await Client(base: try #require(base), token: "wrong").history(thread: "101", before: nil)
        }
    }
}
