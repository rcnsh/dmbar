import Foundation
import UserNotifications

/// Posts a notification for each new message and handles what the user does
/// with it: a click opens the conversation, a typed reply is sent.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let category = "message"
    private nonisolated static let replyAction = "reply"
    private nonisolated static let threadKey = "thread"

    /// Called with a thread ID when its notification is clicked.
    var onOpen: ((String) -> Void)?
    /// Called with a reply typed into a notification, and its thread ID.
    var onReply: ((String, String) -> Void)?

    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyAction, title: "Reply", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [reply], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Announces a message. One notification per thread: a newer message
    /// replaces the older one's banner.
    func post(thread: ChatThread, message: Message, preview: Bool) {
        let content = UNMutableNotificationContent()
        let sender = thread.member(message.senderId)?.displayName ?? thread.title
        content.title = thread.isGroup ? thread.title : sender
        if thread.isGroup { content.subtitle = sender }
        content.body = preview ? message.summary : "New message"
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = thread.id
        content.userInfo = [Self.threadKey: thread.id]
        center.add(UNNotificationRequest(identifier: "thread-\(thread.id)", content: content, trigger: nil))
    }

    /// Takes down a thread's notification once it has been read.
    func clear(thread: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["thread-\(thread)"])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let thread = response.notification.request.content.userInfo[Self.threadKey] as? String else { return }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        await MainActor.run {
            if let text {
                onReply?(text, thread)
            } else if !dismissed {
                onOpen?(thread)
            }
        }
    }
}
