import Foundation

struct TimeSuggestion: Identifiable, Hashable {
    /// 캘린더에 넣을 시간
    let interval: DateInterval
    /// 이 빈 시간대가 끝나는 시각(다음 일정 시작, 그날 탐색 시간대의 끝, 또는 마감)
    let freeUntil: Date

    var id: Date { interval.start }
}

/// 할 일을 넣을 시간을 찾은 결과
enum ScheduleProposal: Equatable {
    /// 통째로 들어가는 자리들
    case whole([TimeSuggestion])
    /// 통째로 들어갈 자리가 없어 빈틈에 나눠 넣는 안. 조각은 시간순.
    case split([DateInterval])
    /// 마감 전 빈 시간을 모두 합쳐도 모자란다. free는 실제로 비어 있는 시간의 합.
    case notEnoughTime(free: TimeInterval)
    /// 빈 시간의 합은 충분하지만 통째로 들어갈 빈틈이 없고, 최소 조각 길이 이상으로 나눠 넣을 수도 없다.
    /// (빈틈이 다 짧거나, 45분처럼 최소 조각 두 개보다 짧은 할 일)
    case tooFragmented(free: TimeInterval)
}

/// 캘린더의 바쁜 시간대를 피해 할 일을 넣을 시간을 찾는다. EventKit에 의존하지 않는 순수 계산.
enum FreeTimeFinder {
    /// 추천은 하루 중 이 시간대(자정부터의 분) 안에서만 한다. 설정 화면에서 바꿀 수 있다.
    static let defaultStartMinutes = 8 * 60
    static let defaultEndMinutes = 22 * 60
    static let startMinutesKey = "freeTimeSearchStartMinutes"
    static let endMinutesKey = "freeTimeSearchEndMinutes"
    /// 마감이 멀어도 오늘을 포함해 이 날수만큼만 찾는다.
    static let maxSearchDays = 7
    /// 나눠 넣을 때 조각 하나의 최소 길이
    static let minimumPiece: TimeInterval = 30 * 60
    /// 날짜마다 보여 줄 통째 추천의 최대 개수
    static let suggestionsPerDay = 4

    /// 지금부터 마감까지, 날마다 탐색 시간대 안에 드는 구간. 오늘부터 최대 maxSearchDays일.
    /// 마감이 지났거나 남은 탐색 시간대가 없으면 빈 배열.
    static func searchWindows(
        now: Date,
        deadline: Date,
        startMinutes: Int = FreeTimeFinder.defaultStartMinutes,
        endMinutes: Int = FreeTimeFinder.defaultEndMinutes,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        let today = calendar.startOfDay(for: now)
        var windows: [DateInterval] = []
        for offset in 0..<maxSearchDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let dayStart = calendar.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: day),
                  let dayEnd = calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: day)
            else { continue }
            let start = max(dayStart, now)
            let end = min(dayEnd, deadline)
            if start < end {
                windows.append(DateInterval(start: start, end: end))
            }
            if dayEnd >= deadline { break }
        }
        return windows
    }

    /// 탐색 구간들에서 바쁜 시간을 뺀 빈틈. 시간순.
    static func freeGaps(in windows: [DateInterval], avoiding busy: [DateInterval]) -> [DateInterval] {
        windows.flatMap { freeGaps(in: $0, avoiding: busy) }
    }

    /// 통째로 들어가는 자리가 있으면 그것을, 없으면 나눠 넣는 안을, 그것도 안 되면 비어 있는 시간의 합을 알려 준다.
    static func proposal(duration: TimeInterval, gaps: [DateInterval], calendar: Calendar = .current) -> ScheduleProposal {
        let whole = suggestions(duration: duration, in: gaps, calendar: calendar)
        if !whole.isEmpty { return .whole(whole) }
        if let pieces = splitPlan(duration: duration, in: gaps, calendar: calendar) { return .split(pieces) }
        let free = gaps.reduce(0) { $0 + $1.duration }
        return free < duration ? .notEnoughTime(free: free) : .tooFragmented(free: free)
    }

    /// 빈틈마다 맨 앞(5분 단위로 올림) 시각을 추천하고, 빈틈이 넉넉하면 30분 이상 떨어진 정시들도 추천한다.
    /// 날짜마다 perDay개까지.
    static func suggestions(
        duration: TimeInterval,
        in gaps: [DateInterval],
        perDay: Int = FreeTimeFinder.suggestionsPerDay,
        calendar: Calendar = .current
    ) -> [TimeSuggestion] {
        guard duration > 0 else { return [] }
        var result: [TimeSuggestion] = []
        var countByDay: [Date: Int] = [:]
        for gap in gaps {
            let day = calendar.startOfDay(for: gap.start)
            var start = roundUp(gap.start, toMinutes: 5, calendar: calendar)
            while start.addingTimeInterval(duration) <= gap.end, countByDay[day, default: 0] < perDay {
                result.append(TimeSuggestion(interval: DateInterval(start: start, duration: duration), freeUntil: gap.end))
                countByDay[day, default: 0] += 1
                start = roundUp(start.addingTimeInterval(30 * 60), toMinutes: 60, calendar: calendar)
            }
        }
        return result
    }

    /// 빈틈에 나눠 넣는 안. 조각 수를 가장 적게 하고, 같은 조각 수라면 가장 일찍 끝나는 조합을 고른다.
    /// 조각은 minimumPiece 이상이고 5분 단위이며 빈틈 맨 앞(5분 단위로 올림)에서 시작한다.
    /// 그렇게 나눌 수 없으면 nil.
    static func splitPlan(
        duration: TimeInterval,
        in gaps: [DateInterval],
        minimumPiece: TimeInterval = FreeTimeFinder.minimumPiece,
        calendar: Calendar = .current
    ) -> [DateInterval]? {
        let step: TimeInterval = 5 * 60
        let slots: [DateInterval] = gaps.compactMap { gap in
            let start = roundUp(gap.start, toMinutes: 5, calendar: calendar)
            let usable = (gap.end.timeIntervalSince(start) / step).rounded(.down) * step
            return usable >= minimumPiece ? DateInterval(start: start, duration: usable) : nil
        }

        // 긴 빈틈부터 채워 몇 조각이 필요한지 정한다.
        var capacity: TimeInterval = 0
        var count = 0
        for length in slots.map(\.duration).sorted(by: >) where capacity < duration {
            capacity += length
            count += 1
        }
        guard capacity >= duration, Double(count) * minimumPiece <= duration else { return nil }

        // 그 조각 수로 채워지는 가장 이른 지점까지의 빈틈 중에서 긴 것을 고른다.
        for lastIndex in slots.indices {
            let chosen = slots[...lastIndex]
                .sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.start < $1.start }
                .prefix(count)
            guard chosen.reduce(0, { $0 + $1.duration }) >= duration else { continue }
            return allocate(duration, into: chosen.sorted { $0.start < $1.start }, minimumPiece: minimumPiece)
        }
        return nil
    }

    /// 앞 조각부터 최대한 채우되, 뒤에 남은 조각마다 최소 길이를 남겨 둔다.
    private static func allocate(_ duration: TimeInterval, into slots: [DateInterval], minimumPiece: TimeInterval) -> [DateInterval] {
        var remaining = duration
        var pieces: [DateInterval] = []
        for (index, slot) in slots.enumerated() {
            let reserved = Double(slots.count - index - 1) * minimumPiece
            let length = min(slot.duration, remaining - reserved)
            pieces.append(DateInterval(start: slot.start, duration: length))
            remaining -= length
        }
        return pieces
    }

    /// window 중에서 busy 구간과 겹치지 않는 부분을 시간순으로 돌려준다.
    static func freeGaps(in window: DateInterval, avoiding busy: [DateInterval]) -> [DateInterval] {
        var gaps: [DateInterval] = []
        var cursor = window.start
        for interval in busy.sorted(by: { $0.start < $1.start }) {
            if interval.start > cursor {
                gaps.append(DateInterval(start: cursor, end: min(interval.start, window.end)))
            }
            cursor = max(cursor, interval.end)
            if cursor >= window.end { return gaps }
        }
        gaps.append(DateInterval(start: cursor, end: window.end))
        return gaps
    }

    /// 정시를 기준으로 step분 단위로 올림. (30분·45분 시차 지역에서도 정시에 맞추려고 Calendar를 쓴다.)
    static func roundUp(_ date: Date, toMinutes step: Int, calendar: Calendar) -> Date {
        guard let hourStart = calendar.dateInterval(of: .hour, for: date)?.start else { return date }
        let stepSeconds = TimeInterval(step * 60)
        let offset = date.timeIntervalSince(hourStart)
        return hourStart.addingTimeInterval((offset / stepSeconds).rounded(.up) * stepSeconds)
    }
}
