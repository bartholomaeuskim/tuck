import Foundation

/// 화면에 보이는 날짜·시간 문자열. 형식은 앱 언어(Locale.current)를 따른다.
enum DisplayFormat {
    /// 30 → "30 min" / "30분" / "30分" / "30分钟"
    static func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func timeRange(_ interval: DateInterval) -> String {
        (interval.start..<interval.end).formatted(date: .omitted, time: .shortened)
    }

    /// "Today", "Tomorrow", "Yesterday", 그 밖에는 "Wed, Oct 21"
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month().day().weekday(.abbreviated))
        }
        return date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
    }

    static func dayAndTime(_ date: Date) -> String {
        "\(day(date)) \(time(date))"
    }

    /// "Today 3:00 – 4:00 PM"
    static func dayAndTimeRange(_ interval: DateInterval) -> String {
        "\(day(interval.start)) \(timeRange(interval))"
    }
}
