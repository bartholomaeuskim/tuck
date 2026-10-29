import EventKit
import Foundation
import SwiftData
import Testing
@testable import MyApp

private var hasCalendarAccess: Bool {
    EKEventStore.authorizationStatus(for: .event) == .fullAccess
}

/// 지금 시각을 분 단위로 내린 값. EventKit은 초 아래를 버리고 저장한다.
private func minuteNow() -> Date {
    Date(timeIntervalSinceReferenceDate: (Date.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
}

/// 실제 캘린더에 일정을 만들고 지우면서 할 일 ↔ 일정(여러 개) 연결을 확인한다.
/// 시뮬레이터에 캘린더 권한이 있어야 돌고, 없으면 건너뛴다.
///   xcrun simctl privacy booted grant calendar com.joonilkim.tuck
/// 일정 제목마다 실행별 태그를 붙이고, 테스트가 끝나면 그 태그가 붙은 일정을 지운다.
@MainActor
@Suite(.serialized, .enabled(if: hasCalendarAccess, "캘린더 전체 접근 권한이 필요하다"))
struct CalendarLinkTests {
    /// 앱이 만든 일정을 같은 저장소에서 확인한다. 새 EKEventStore로 바로 읽으면 알람이 아직 비어 있을 수 있다.
    private let store = EKEventStore()
    private let service: CalendarService
    private let context: ModelContext
    private let tag = String(UUID().uuidString.prefix(8))
    /// 아직 시작하지 않은 일정에 쓰는 시각: 지금부터 2~3시간 뒤의 정시
    private let later: Date

    init() throws {
        service = CalendarService(store: store)
        let container = try ModelContainer(for: TodoItem.self, CalendarBlock.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        later = Calendar.current.dateInterval(of: .hour, for: .now)!.start.addingTimeInterval(3 * 3600)
    }

    private func makeItem(_ name: String) -> TodoItem {
        let item = TodoItem(title: "\(name) \(tag)", dueDate: later.addingTimeInterval(6 * 3600), estimatedMinutes: 60)
        context.insert(item)
        return item
    }

    private func slot(_ start: Date, minutes: Int = 30) -> DateInterval {
        DateInterval(start: start, duration: TimeInterval(minutes * 60))
    }

    private func event(_ block: CalendarBlock) -> EKEvent? {
        block.eventID.flatMap { store.event(withIdentifier: $0) }
    }

    private func taggedEvents() -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: .now.addingTimeInterval(-86400), end: .now.addingTimeInterval(2 * 86400), calendars: nil)
        return store.events(matching: predicate)
            .filter { ($0.title ?? "").hasSuffix(tag) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func cleanUp() {
        for event in taggedEvents() {
            try? store.remove(event, span: .thisEvent)
        }
    }

    @Test func schedulingCreatesEventWithStartAlarm() throws {
        defer { cleanUp() }
        let item = makeItem("schedule")
        try service.schedule(item, at: [slot(later)])

        let block = try #require(item.scheduledBlocks.first)
        let event = try #require(event(block))
        #expect(item.scheduledBlocks.count == 1)
        #expect(event.title == item.title)
        #expect(event.startDate == later)
        #expect(event.endDate == later.addingTimeInterval(1800))
        #expect(event.alarms?.map(\.relativeOffset) == [0])
    }

    @Test func splitPlanCreatesOneEventPerPiece() throws {
        defer { cleanUp() }
        let item = makeItem("split")
        let plan = [slot(later), slot(later.addingTimeInterval(2 * 3600))]
        try service.schedule(item, at: plan)

        #expect(item.scheduledBlocks.map(\.interval) == plan)
        #expect(taggedEvents().map { DateInterval(start: $0.startDate, end: $0.endDate) } == plan)
        #expect(taggedEvents().allSatisfy { $0.alarms?.map(\.relativeOffset) == [0] && $0.title == item.title })
    }

    /// 다시 고르면 있던 일정을 옮겨 쓰고, 모자라면 만들고, 남으면 지운다.
    @Test func reschedulingReusesEvents() throws {
        defer { cleanUp() }
        let item = makeItem("reschedule")
        try service.schedule(item, at: [slot(later), slot(later.addingTimeInterval(2 * 3600))])
        let firstID = item.scheduledBlocks.first?.eventID

        try service.schedule(item, at: [slot(later.addingTimeInterval(3600), minutes: 60)])
        #expect(item.scheduledBlocks.map(\.eventID) == [firstID])
        #expect(taggedEvents().map(\.startDate) == [later.addingTimeInterval(3600)])

        let three = [slot(later), slot(later.addingTimeInterval(3600)), slot(later.addingTimeInterval(7200))]
        try service.schedule(item, at: three)
        #expect(item.scheduledBlocks.first?.eventID == firstID)
        #expect(taggedEvents().map(\.startDate) == three.map(\.start))
    }

    /// 다른 캘린더로 옮겨 일정 ID가 바뀐 직후에 제목을 바꿔도, 옛 제목으로 일정을 찾아 연결을 유지한다.
    @Test func editingAfterIdentifierChangeKeepsTheLink() throws {
        defer { cleanUp() }
        let item = makeItem("edit")
        try service.schedule(item, at: [slot(later)])
        let block = try #require(item.scheduledBlocks.first)
        let eventID = block.eventID
        block.eventID = "stale-identifier"

        let newTitle = "renamed \(tag)"
        service.updateLinkedEvents(for: item, title: newTitle, estimatedMinutes: 45)
        item.title = newTitle

        #expect(block.eventID == eventID)
        let event = try #require(event(block))
        #expect(event.title == newTitle)
        #expect(event.endDate == later.addingTimeInterval(2700))
    }

    /// 나눠 넣은 일정은 조각 길이를 정할 수 없어 제목만 바꾼다.
    @Test func editingSplitScheduleChangesTitlesOnly() throws {
        defer { cleanUp() }
        let item = makeItem("edit-split")
        let plan = [slot(later), slot(later.addingTimeInterval(2 * 3600))]
        try service.schedule(item, at: plan)

        service.updateLinkedEvents(for: item, title: "renamed \(tag)", estimatedMinutes: 90)

        #expect(taggedEvents().map { DateInterval(start: $0.startDate, end: $0.endDate) } == plan)
        #expect(taggedEvents().allSatisfy { $0.title == "renamed \(tag)" })
    }

    /// 나눠 넣었다가 중간에 완료하면 시작한 조각 하나만 남는다. 그 기록을 예상 시간에 맞춰 늘리지 않는다.
    @Test func editingEstimateKeepsCompletedRecord() throws {
        defer { cleanUp() }
        let item = makeItem("edit-completed")
        let started = slot(minuteNow().addingTimeInterval(-600))
        try service.schedule(item, at: [started, slot(later)])
        context.toggleCompletion(of: item, calendarService: service)

        service.updateLinkedEvents(for: item, title: item.title, estimatedMinutes: 120)

        #expect(taggedEvents().map { DateInterval(start: $0.startDate, end: $0.endDate) } == [started])
    }

    @Test func editingEstimateKeepsEndedEvent() throws {
        defer { cleanUp() }
        let item = makeItem("edit-ended")
        let ended = slot(minuteNow().addingTimeInterval(-7200))
        try service.schedule(item, at: [ended])

        service.updateLinkedEvents(for: item, title: item.title, estimatedMinutes: 120)

        #expect(taggedEvents().map { DateInterval(start: $0.startDate, end: $0.endDate) } == [ended])
    }

    @Test func eventDeletedInCalendarRemovesItsBlock() throws {
        defer { cleanUp() }
        let item = makeItem("deleted-elsewhere")
        try service.schedule(item, at: [slot(later), slot(later.addingTimeInterval(2 * 3600))])
        try store.remove(try #require(event(item.scheduledBlocks[0])), span: .thisEvent)

        service.syncLinkedEvents(for: item)

        #expect(item.scheduledBlocks.map(\.start) == [later.addingTimeInterval(2 * 3600)])
    }

    /// 할 일을 지우면 아직 끝나지 않은 일정(시작 전·진행 중)만 함께 지우고, 그때만 삭제 확인을 받는다.
    @Test(arguments: [(180, true), (-10, true), (-120, false)])
    func deletingTodoRemovesOnlyUnfinishedEvent(startOffsetMinutes: Int, removesEvent: Bool) throws {
        defer { cleanUp() }
        let item = makeItem("delete")
        try service.schedule(item, at: [slot(minuteNow().addingTimeInterval(TimeInterval(startOffsetMinutes * 60)))])
        let eventID = try #require(item.scheduledBlocks.first?.eventID)

        #expect(service.unfinishedLinkedEventCount(item) == (removesEvent ? 1 : 0))
        context.deleteTodo(item, calendarService: service)

        #expect((store.event(withIdentifier: eventID) == nil) == removesEvent)
    }

    @Test func deletingSplitTodoRemovesEveryUnfinishedPiece() throws {
        defer { cleanUp() }
        let item = makeItem("delete-split")
        let past = slot(minuteNow().addingTimeInterval(-7200))
        try service.schedule(item, at: [past, slot(later), slot(later.addingTimeInterval(3600))])

        #expect(service.unfinishedLinkedEventCount(item) == 2)
        context.deleteTodo(item, calendarService: service)

        #expect(taggedEvents().map(\.startDate) == [past.start])
    }

    /// TodoRow의 체크 버튼과 같은 순서로 호출한다.
    @Test func completingEarlyRemovesEventsAndUndoRestoresThem() throws {
        defer { cleanUp() }
        let item = makeItem("undo")
        let plan = [slot(later), slot(later.addingTimeInterval(2 * 3600))]
        try service.schedule(item, at: plan)

        context.toggleCompletion(of: item, calendarService: service)
        #expect(taggedEvents().isEmpty)
        #expect(item.scheduledBlocks.isEmpty)
        #expect(item.blocks.map(\.interval).sorted { $0.start < $1.start } == plan)

        context.toggleCompletion(of: item, calendarService: service)
        #expect(item.scheduledBlocks.map(\.interval) == plan)
        #expect(taggedEvents().map { DateInterval(start: $0.startDate, end: $0.endDate) } == plan)
        #expect(taggedEvents().allSatisfy { $0.alarms?.map(\.relativeOffset) == [0] })
        #expect(item.blocks.count == 2)
    }

    /// 이미 시작한 조각은 그 일을 한 시간이라 남기고, 아직 시작하지 않은 조각만 지웠다가 되살린다.
    @Test func completingMidwayKeepsStartedPiece() throws {
        defer { cleanUp() }
        let item = makeItem("midway")
        let started = slot(minuteNow().addingTimeInterval(-600))
        try service.schedule(item, at: [started, slot(later)])
        let startedID = item.scheduledBlocks.first?.eventID

        context.toggleCompletion(of: item, calendarService: service)
        #expect(item.scheduledBlocks.map(\.eventID) == [startedID])
        #expect(taggedEvents().map(\.startDate) == [started.start])

        context.toggleCompletion(of: item, calendarService: service)
        #expect(item.scheduledBlocks.first?.eventID == startedID)
        #expect(taggedEvents().map(\.startDate) == [started.start, later])
    }

    @Test func undoAfterTheTimePassedDoesNotRecreate() {
        defer { cleanUp() }
        let item = makeItem("undo-late")
        item.toggleCompleted()
        item.addBlock(eventID: nil, interval: DateInterval(start: .now.addingTimeInterval(-3600), duration: 1800))

        context.toggleCompletion(of: item, calendarService: service)

        #expect(item.blocks.isEmpty)
        #expect(taggedEvents().isEmpty)
    }

    @Test func syncChecksOnlyIncompleteTodos() throws {
        let open = makeItem("sync-open")
        open.addBlock(eventID: "missing-\(tag)", interval: slot(later))
        let done = makeItem("sync-done")
        done.addBlock(eventID: "missing-done-\(tag)", interval: slot(later))
        done.toggleCompleted()
        try context.save()

        service.syncLinkedEvents(in: context)

        #expect(open.blocks.isEmpty)
        #expect(done.blocks.map(\.eventID) == ["missing-done-\(tag)"])
    }
}
