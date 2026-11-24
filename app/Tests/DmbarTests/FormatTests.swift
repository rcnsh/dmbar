import Foundation
import Testing

@testable import Dmbar

struct FormatTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ms(_ secondsAgo: Double) -> Int64 { Int64((now.timeIntervalSince1970 - secondsAgo) * 1000) }

    @Test("a list time ages with the clock it is given") func short() {
        #expect(Format.short(ms(30), now: now) == "now")
        #expect(Format.short(ms(5 * 60), now: now) == "5m")
        #expect(Format.short(ms(3 * 3600), now: now) == "3h")
        #expect(Format.short(ms(30), now: now.addingTimeInterval(4 * 60)) == "4m")
    }

    @Test("Today becomes Yesterday at midnight") func day() {
        let cal = Calendar.current
        let date = cal.date(bySettingHour: 23, minute: 50, second: 0, of: now)!
        #expect(Format.day(date, now: date) == "Today")
        #expect(Format.day(date, now: date.addingTimeInterval(20 * 60)) == "Yesterday")
    }
}
