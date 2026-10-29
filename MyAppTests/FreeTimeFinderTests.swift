import Foundation
import Testing
@testable import MyApp

/// 시간대에 따라 결과가 달라지지 않도록 서울 시간 기준 달력으로 고정한다.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}()

/// 2026-10-20(화)
private let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
}

/// day에서 days일 뒤의 시각
private func on(_ days: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.date(byAdding: .day, value: days, to: at(hour, minute))!
}

private func interval(_ start: Date, _ end: Date) -> DateInterval {
    DateInterval(start: start, end: end)
}

private func gap(_ start: Date, minutes: Int) -> DateInterval {
    DateInterval(start: start, duration: TimeInterval(minutes * 60))
}

private let minute: TimeInterval = 60

/// 추천 결과를 "14:25-14:55,15:00-15:30" 형태로 바꿔 비교하기 쉽게 한다.
private func hhmm(_ date: Date) -> String {
    let parts = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour!, parts.minute!)
}

private func ranges(_ intervals: [DateInterval]) -> String {
    intervals.map { "\(hhmm($0.start))-\(hhmm($0.end))" }.joined(separator: ",")
}

/// 날짜가 바뀌는 결과는 "10-21 08:00-22:00" 형태로
private func datedRanges(_ intervals: [DateInterval]) -> String {
    intervals.map { item in
        let parts = calendar.dateComponents([.month, .day], from: item.start)
        return String(format: "%02d-%02d ", parts.month!, parts.day!) + "\(hhmm(item.start))-\(hhmm(item.end))"
    }.joined(separator: ",")
}

@MainActor
private func suggest(_ window: DateInterval, busy: [DateInterval] = [], minutes: Int) -> String {
    let gaps = FreeTimeFinder.freeGaps(in: [window], avoiding: busy)
    return ranges(FreeTimeFinder.suggestions(duration: TimeInterval(minutes) * minute, in: gaps, calendar: calendar).map(\.interval))
}

@MainActor
private func windows(now: Date, deadline: Date, startMinutes: Int = 8 * 60, endMinutes: Int = 22 * 60) -> String {
    datedRanges(FreeTimeFinder.searchWindows(now: now, deadline: deadline, startMinutes: startMinutes, endMinutes: endMinutes, calendar: calendar))
}

@MainActor
private func split(_ gaps: [DateInterval], minutes: Int) -> String? {
    FreeTimeFinder.splitPlan(duration: TimeInterval(minutes) * minute, in: gaps, calendar: calendar).map(datedRanges)
}

@MainActor
private func proposal(_ gaps: [DateInterval], minutes: Int) -> ScheduleProposal {
    FreeTimeFinder.proposal(duration: TimeInterval(minutes) * minute, gaps: gaps, calendar: calendar)
}

// MARK: - 통째로 들어가는 자리

@MainActor
struct FreeTimeFinderTests {
    @Test func emptyDaySuggestsGapStartThenHourlyUpToDailyLimit() {
        #expect(suggest(interval(at(14, 22), at(22)), minutes: 30) == "14:25-14:55,15:00-15:30,16:00-16:30,17:00-17:30")
    }

    @Test func fitsBetweenEvents() {
        #expect(suggest(interval(at(14, 22), at(22)), busy: [interval(at(15), at(16)), interval(at(16, 30), at(17))], minutes: 30)
            == "14:25-14:55,16:00-16:30,17:00-17:30,18:00-18:30")
    }

    @Test func mergesOverlappingUnsortedEvents() {
        #expect(suggest(interval(at(8), at(13)), busy: [interval(at(9, 30), at(11)), interval(at(9), at(10))], minutes: 60)
            == "08:00-09:00,11:00-12:00,12:00-13:00")
    }

    @Test func eventRunningPastEndOfDay() {
        #expect(suggest(interval(at(19), at(22)), busy: [interval(at(21), at(23))], minutes: 60) == "19:00-20:00,20:00-21:00")
    }

    @Test func eventStartedBeforeWindow() {
        #expect(suggest(interval(at(8), at(10)), busy: [interval(at(7), at(8, 30))], minutes: 30) == "08:30-09:00,09:00-09:30")
    }

    @Test func gapExactlyAsLongAsTask() {
        #expect(suggest(interval(at(8), at(22)), busy: [interval(at(8), at(10)), interval(at(10, 45), at(22))], minutes: 45) == "10:00-10:45")
    }

    @Test func gapOneMinuteTooShort() {
        #expect(suggest(interval(at(8), at(22)), busy: [interval(at(8), at(10)), interval(at(10, 44), at(22))], minutes: 45) == "")
    }

    @Test func busyAllDay() {
        #expect(suggest(interval(at(8), at(22)), busy: [interval(at(7), at(23))], minutes: 15) == "")
    }

    @Test func taskLongerThanRestOfDay() {
        #expect(suggest(interval(at(20, 30), at(22)), minutes: 120) == "")
    }

    @Test func roundingUpToFiveMinutesStillFits() {
        #expect(suggest(interval(at(9, 58), at(10, 30)), minutes: 30) == "10:00-10:30")
    }

    @Test func roundingUpToFiveMinutesLeavesTooLittle() {
        #expect(suggest(interval(at(9, 58), at(10, 29)), minutes: 30) == "")
    }

    @Test func roundsToTheHourInHalfHourTimeZone() {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let rounded = FreeTimeFinder.roundUp(Date(timeIntervalSince1970: 1_760_950_000), toMinutes: 60, calendar: kolkata)
        #expect(kolkata.component(.minute, from: rounded) == 0)
    }

    @Test func dailyLimitAppliesToEachDay() {
        let gaps = [interval(at(8), at(22)), interval(on(1, 8), on(1, 22))]
        let suggestions = FreeTimeFinder.suggestions(duration: 60 * minute, in: gaps, calendar: calendar)
        #expect(datedRanges(suggestions.map(\.interval))
            == "10-20 08:00-09:00,10-20 09:00-10:00,10-20 10:00-11:00,10-20 11:00-12:00,"
            + "10-21 08:00-09:00,10-21 09:00-10:00,10-21 10:00-11:00,10-21 11:00-12:00")
    }
}

// MARK: - 지금부터 마감까지의 탐색 구간

@MainActor
struct SearchWindowTests {
    @Test func spansEveryDayUntilTheDeadline() {
        #expect(windows(now: at(14, 22), deadline: on(2, 12)) == "10-20 14:22-22:00,10-21 08:00-22:00,10-22 08:00-12:00")
    }

    @Test func beforeDailyStartBeginsAtStart() {
        #expect(windows(now: at(7), deadline: at(20)) == "10-20 08:00-20:00")
    }

    @Test func afterDailyEndSkipsToTomorrow() {
        #expect(windows(now: at(22, 30), deadline: on(1, 10)) == "10-21 08:00-10:00")
    }

    @Test func deadlineInsideTodayEndsThere() {
        #expect(windows(now: at(9), deadline: at(9, 30)) == "10-20 09:00-09:30")
    }

    /// 마감일의 탐색 시작 전에 마감이면 그날은 찾지 않는다.
    @Test(arguments: [(7, 0), (8, 0)])
    func deadlineAtOrBeforeDailyStartAddsNothingThatDay(hour: Int, minute: Int) {
        #expect(windows(now: at(14), deadline: on(1, hour, minute)) == "10-20 14:00-22:00")
    }

    @Test func deadlineAfterDailyEndUsesWholeDay() {
        #expect(windows(now: at(20), deadline: on(1, 23)) == "10-20 20:00-22:00,10-21 08:00-22:00")
    }

    @Test(arguments: [(13, 0), (14, 0)])
    func deadlineAtOrBeforeNowFindsNothing(hour: Int, minute: Int) {
        #expect(windows(now: at(14), deadline: at(hour, minute)) == "")
    }

    @Test func farDeadlineStopsAfterSevenDays() {
        let result = FreeTimeFinder.searchWindows(now: at(14), deadline: on(40, 12), calendar: calendar)
        #expect(result.count == FreeTimeFinder.maxSearchDays)
        #expect(datedRanges([result.last!]) == "10-26 08:00-22:00")
    }

    @Test func usesSearchHoursFromSettings() {
        #expect(windows(now: at(7), deadline: on(1, 12), startMinutes: 9 * 60 + 30, endMinutes: 18 * 60)
            == "10-20 09:30-18:00,10-21 09:30-12:00")
    }

    /// 마감 1분 전까지만 비어 있으면 그 1분이 모자라 1시간짜리는 통째로 못 넣는다.
    @Test func neverSuggestsPastTheDeadline() {
        let fits = FreeTimeFinder.searchWindows(now: at(14), deadline: at(15), calendar: calendar)
        let short = FreeTimeFinder.searchWindows(now: at(14), deadline: at(14, 59), calendar: calendar)
        #expect(suggest(fits[0], minutes: 60) == "14:00-15:00")
        #expect(suggest(short[0], minutes: 60) == "")
    }
}

// MARK: - 나눠 넣기

@MainActor
struct SplitPlanTests {
    @Test func wholeSlotComesFirst() {
        let result = proposal([gap(at(9), minutes: 60), gap(at(13), minutes: 120)], minutes: 120)
        guard case .whole(let suggestions) = result else {
            Issue.record("expected whole, got \(result)")
            return
        }
        #expect(ranges(suggestions.map(\.interval)) == "13:00-15:00")
    }

    @Test func splitsWhenNoWholeSlot() {
        #expect(proposal([gap(at(9), minutes: 60), gap(at(13), minutes: 60)], minutes: 120)
            == .split([gap(at(9), minutes: 60), gap(at(13), minutes: 60)]))
    }

    /// 60·45·90분 빈틈에 2시간: 두 조각이면 되므로 세 조각으로 나누지 않는다.
    @Test func usesFewestPieces() {
        #expect(split([gap(at(9), minutes: 60), gap(at(11), minutes: 45), gap(at(14), minutes: 90)], minutes: 120)
            == "10-20 09:00-10:00,10-20 14:00-15:00")
    }

    /// 같은 조각 수라면 가장 일찍 끝나는 조합을 고른다.
    @Test func prefersEarlierPlanWithSameCount() {
        #expect(split([gap(at(9), minutes: 60), gap(at(11), minutes: 60), gap(on(1, 9), minutes: 100), gap(on(2, 9), minutes: 100)], minutes: 120)
            == "10-20 09:00-10:00,10-20 11:00-12:00")
    }

    @Test func needsThreePiecesWhenTwoAreNotEnough() {
        #expect(split([gap(at(9), minutes: 50), gap(at(11), minutes: 40), gap(at(14), minutes: 45)], minutes: 120)
            == "10-20 09:00-09:50,10-20 11:00-11:40,10-20 14:00-14:30")
    }

    /// 앞 조각을 최대한 채우되 뒤 조각이 30분은 되도록 남긴다.
    @Test func leavesMinimumForLaterPieces() {
        #expect(split([gap(at(9), minutes: 90), gap(at(13), minutes: 35)], minutes: 100)
            == "10-20 09:00-10:10,10-20 13:00-13:30")
    }

    @Test func piecesExactlyAtMinimum() {
        #expect(split([gap(at(9), minutes: 30), gap(at(13), minutes: 30)], minutes: 60)
            == "10-20 09:00-09:30,10-20 13:00-13:30")
    }

    @Test func ignoresGapsShorterThanMinimum() {
        #expect(split([gap(at(9), minutes: 25), gap(at(10), minutes: 40), gap(at(11), minutes: 25), gap(at(13), minutes: 40)], minutes: 60)
            == "10-20 10:00-10:30,10-20 13:00-13:30")
    }

    /// 14:03에 시작하는 30분 빈틈은 14:05로 맞추면 25분만 남아 조각이 되지 못한다.
    @Test func roundingStartCanDropGapBelowMinimum() {
        #expect(split([gap(at(14, 3), minutes: 30), gap(at(16), minutes: 30)], minutes: 60) == nil)
    }

    @Test func canSpanSeveralDays() {
        #expect(split([gap(at(20), minutes: 60), gap(on(1, 8), minutes: 60)], minutes: 120)
            == "10-20 20:00-21:00,10-21 08:00-09:00")
    }

    /// 45분짜리는 30분 이상 두 조각으로 나눌 수 없다.
    @Test func shortTaskCannotBeSplit() {
        #expect(split([gap(at(9), minutes: 40), gap(at(13), minutes: 40)], minutes: 45) == nil)
        #expect(proposal([gap(at(9), minutes: 40), gap(at(13), minutes: 40)], minutes: 45) == .tooFragmented(free: 80 * minute))
    }

    @Test func reportsActualFreeTimeWhenNotEnough() {
        #expect(proposal([gap(at(9), minutes: 30), gap(at(13), minutes: 40), gap(at(15), minutes: 10)], minutes: 120)
            == .notEnoughTime(free: 80 * minute))
    }

    @Test func reportsFragmentedWhenGapsAreTooShort() {
        #expect(proposal([gap(at(9), minutes: 20), gap(at(10), minutes: 20), gap(at(11), minutes: 20), gap(at(12), minutes: 20)], minutes: 60)
            == .tooFragmented(free: 80 * minute))
    }

    @Test func noGapsMeansNoFreeTime() {
        #expect(proposal([], minutes: 30) == .notEnoughTime(free: 0))
    }
}

// MARK: - 그 밖의 할 일 규칙

@MainActor
struct DefaultDueDateTests {
    @Test func todayUsesNextFullHour() {
        #expect(TodoTab.today.defaultDueDate(now: at(14, 20), calendar: calendar) == at(15))
    }

    /// 23:30에 다음 정시(내일 0시)를 쓰면 방금 추가한 할 일이 오늘 탭에서 사라진다.
    @Test func lateNightStaysToday() {
        #expect(TodoTab.today.defaultDueDate(now: at(23, 30), calendar: calendar) == at(23, 59))
    }

    @Test func upcomingIsTomorrowMorning() {
        #expect(TodoTab.upcoming.defaultDueDate(now: at(14, 20), calendar: calendar) == on(1, 9))
    }
}

@MainActor
struct OverdueTests {
    private let item = TodoItem(title: "보고서", dueDate: at(15))

    @Test func overdueFromTheDeadline() {
        #expect(!item.isOverdue(at: at(14, 59)))
        #expect(item.isOverdue(at: at(15)))
        #expect(item.isOverdue(at: at(16)))
    }

    @Test func completedIsNeverOverdue() {
        item.toggleCompleted()
        #expect(!item.isOverdue(at: at(16)))
    }
}
