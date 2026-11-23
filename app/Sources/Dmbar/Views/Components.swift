import SwiftUI

/// The look shared across screens.
enum Theme {
    /// Instagram's gradient, kept for the app's own accents.
    static let brand = LinearGradient(
        colors: [Color(red: 0.98, green: 0.69, blue: 0.25), Color(red: 0.91, green: 0.19, blue: 0.42), Color(red: 0.51, green: 0.23, blue: 0.86)],
        startPoint: .bottomLeading, endPoint: .topTrailing)
    /// Instagram's blue (#0095F6), for the unread mark.
    static let unread = Color(red: 0, green: 149 / 255, blue: 246 / 255)
    /// The user's own bubbles.
    static let mine = LinearGradient(
        colors: [Color(red: 0.42, green: 0.36, blue: 0.98), Color(red: 0.62, green: 0.32, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let slide = Animation.snappy(duration: 0.3, extraBounce: 0.02)
}

/// A round profile picture, or initials on a colour picked from the ID while
/// the picture loads or when there is none.
struct Avatar: View {
    var url: String
    var name: String
    var seed: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            placeholder
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        // Unicode scalars, not hashValue, so the colour is the same every launch.
        let hue = Double((seed.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) } &* 137).magnitude % 360) / 360
        return ZStack {
            LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: hue, saturation: 0.7, brightness: 0.6)],
                startPoint: .top, endPoint: .bottom)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

extension Avatar {
    /// The picture for a thread: a group's own image, else its first member's.
    init(thread: ChatThread, size: CGFloat = 40) {
        let url = thread.imageUrl.isEmpty ? (thread.members.first?.avatarUrl ?? "") : thread.imageUrl
        self.init(url: url, name: thread.title, seed: thread.id, size: size)
    }

    init(user: User, size: CGFloat = 40) {
        self.init(url: user.avatarUrl, name: user.displayName, seed: user.id, size: size)
    }
}

/// A round glass button holding one symbol.
struct GlassIconButton: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Three dots that pulse in turn while someone types.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin((t * 4) - Double(i) * 0.9)
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.45 + 0.4 * max(0, phase))
                        .offset(y: -2 * max(0, phase))
                }
            }
        }
        .accessibilityLabel("Typing")
    }
}

enum Format {
    /// A short time for a list row: "now", "5m", "3h", "Tue", "12 Mar".
    static func short(_ ms: Int64, now: Date = .now) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        case ..<(86400 * 6): return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// A heading for a day in a conversation: "Today", "Yesterday", "Tue 12 Mar".
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
