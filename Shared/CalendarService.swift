import EventKit
import Foundation
import Observation
import SwiftData

/// EventKit 접근과 할 일 ↔ 캘린더 일정 연결을 한곳에 모은다. EKEventStore는 앱 전체에서 하나만 쓴다.
/// 할 일 하나에 일정이 여러 개(CalendarBlock) 연결될 수 있고, 수정·삭제·완료 때 모두 함께 처리한다.
@Observable
final class CalendarService {
    private let store: EKEventStore
    private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)

    /// 테스트는 만든 일정을 같은 저장소에서 확인하도록 store를 넘긴다.
    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    private var hasFullAccess: Bool { authorizationStatus == .fullAccess }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refreshStatus()
    }

    /// 설정 앱에서 권한을 바꾸고 돌아왔을 때 호출한다.
    func refreshStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    /// window 안에서 실제로 시간을 차지하는 일정들.
    /// 종일 일정, '한가함'으로 표시된 일정, 취소·거절한 일정, ignoring에 든 일정(이 할 일의 일정)은 뺀다.
    func busyIntervals(in window: DateInterval, ignoring ignoredEventIDs: Set<String>) -> [DateInterval] {
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        return store.events(matching: predicate)
            .filter { event in
                !event.isAllDay
                    && event.availability != .free
                    && event.status != .canceled
                    && !event.isDeclinedByCurrentUser
                    && !ignoredEventIDs.contains(event.eventIdentifier ?? "")
            }
            .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
    }

    // MARK: - 할 일과 연결된 일정

    /// 할 일의 일정을 plan의 시간들로 맞춘다. 있던 일정은 옮기고(알람도 같이 옮겨진다),
    /// 모자라면 기본 캘린더에 새로 만들고, 남으면 지운다. 하나라도 실패하면 아무것도 바꾸지 않는다.
    func schedule(_ item: TodoItem, at plan: [DateInterval]) throws {
        let existing = syncLinkedEvents(for: item)
        var staged: [(event: EKEvent, interval: DateInterval)] = []
        do {
            for (index, interval) in plan.enumerated() {
                let event: EKEvent
                if index < existing.count {
                    event = existing[index].event
                } else {
                    guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarError.noWritableCalendar }
                    event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    // 시작 시각에 캘린더 알림이 오도록 한다.
                    event.addAlarm(EKAlarm(relativeOffset: 0))
                }
                event.title = item.title
                event.startDate = interval.start
                event.endDate = interval.end
                try store.save(event, span: .thisEvent, commit: false)
                staged.append((event, interval))
            }
            for leftover in existing.dropFirst(plan.count) {
                try store.remove(leftover.event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            store.reset()
            throw error
        }

        for block in item.blocks {
            item.removeBlock(block)
        }
        for (event, interval) in staged {
            guard let identifier = event.eventIdentifier else { throw CalendarError.missingIdentifier }
            item.addBlock(eventID: identifier, interval: interval)
        }
    }

    /// 캘린더 앱에서 옮기거나 지운 일정을 완료하지 않은 할 일에 반영한다.
    /// 앱이 앞으로 돌아올 때와 캘린더가 바뀔 때(EKEventStoreChanged) 호출한다.
    /// 완료한 할 일은 쌓이기만 하므로 매번 확인하지 않고, 완료를 취소할 때 맞춘다.
    func syncLinkedEvents(in context: ModelContext) {
        guard hasFullAccess else { return }
        let descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { !$0.isCompleted })
        for item in (try? context.fetch(descriptor)) ?? [] where !item.blocks.isEmpty {
            syncLinkedEvents(for: item)
        }
        if context.hasChanges { try? context.save() }
    }

    /// 연결된 일정들의 지금 상태를 블록에 반영하고, 찾은 일정을 시간순으로 돌려준다.
    /// 캘린더에서 지운 일정의 블록은 없앤다. 완료하면서 지운 일정(eventID가 nil)의 블록은 그대로 둔다.
    @discardableResult
    func syncLinkedEvents(for item: TodoItem) -> [(block: CalendarBlock, event: EKEvent)] {
        // 권한이 없으면 일정을 찾을 수 없어 지워진 것처럼 보이므로 연결을 건드리지 않는다.
        guard hasFullAccess else { return [] }
        var found: [(block: CalendarBlock, event: EKEvent)] = []
        for block in item.blocks where block.eventID != nil {
            guard let event = linkedEvent(for: block, title: item.title) else {
                item.removeBlock(block)
                continue
            }
            if block.eventID != event.eventIdentifier { block.eventID = event.eventIdentifier }
            if block.start != event.startDate { block.start = event.startDate }
            if block.end != event.endDate { block.end = event.endDate }
            found.append((block, event))
        }
        return found.sorted { $0.event.startDate < $1.event.startDate }
    }

    /// 할 일의 제목·예상 소요시간을 바꿀 때 연결된 일정에도 반영한다.
    /// 일정 ID가 바뀌었으면 옛 제목으로 다시 찾아야 하므로 할 일을 고치기 전에 호출한다.
    /// 길이는 아직 할 일정 하나에만 맞춘다. 나눠 넣은 일정은 조각 길이를 정할 수 없고,
    /// 완료했거나 이미 끝난 일정은 그 일을 한 기록이라 그대로 둔다.
    func updateLinkedEvents(for item: TodoItem, title: String, estimatedMinutes: Int?) {
        let linked = syncLinkedEvents(for: item)
        for (block, event) in linked {
            event.title = title
            if linked.count == 1, !item.isCompleted, event.endDate > .now, let estimatedMinutes {
                event.endDate = event.startDate.addingTimeInterval(TimeInterval(estimatedMinutes * 60))
                block.end = event.endDate
            }
            try? store.save(event, span: .thisEvent)
        }
    }

    /// 할 일을 지우면 함께 지워질 일정(아직 끝나지 않은 연결 일정)의 수. 삭제 확인에 쓴다.
    func unfinishedLinkedEventCount(_ item: TodoItem) -> Int {
        item.blocks.compactMap { linkedEvent(for: $0, title: item.title) }.filter { $0.endDate > .now }.count
    }

    /// 할 일을 지울 때 호출한다. 아직 끝나지 않은 일정만 지우고, 이미 지난 일정은 기록으로 남긴다.
    func removeLinkedEvents(for item: TodoItem) {
        for (block, event) in syncLinkedEvents(for: item) where event.endDate > .now {
            guard (try? store.remove(event, span: .thisEvent)) != nil else { continue }
            item.removeBlock(block)
        }
    }

    /// 할 일을 완료했을 때 호출한다. 아직 시작하지 않은 일정은 알람이 울리지 않도록 지우되,
    /// 실수로 누른 경우 되돌릴 수 있게 블록에 시간을 남겨 둔다. 이미 시작한 일정은 그 일을 한 시간으로 남긴다.
    func removeUnstartedLinkedEvents(for item: TodoItem) {
        for (block, event) in syncLinkedEvents(for: item) where event.startDate > .now {
            guard (try? store.remove(event, span: .thisEvent)) != nil else { continue }
            block.eventID = nil
        }
    }

    /// 완료를 취소했을 때 호출한다. 완료하면서 지운 일정은 아직 안 지났으면 같은 시간에 다시 만들고,
    /// 남아 있던 일정은 캘린더의 현재 상태에 맞춘다. 캘린더 앱에서 넣은 메모나 장소는 되살리지 못한다.
    func restoreLinkedEvents(for item: TodoItem) {
        let linked = syncLinkedEvents(for: item)
        let removed = item.blocks.filter { $0.eventID == nil }
        guard !removed.isEmpty else { return }
        let restorable = removed.filter { $0.end > .now }.map(\.interval)
        guard !restorable.isEmpty else {
            for block in removed {
                item.removeBlock(block)
            }
            return
        }
        // 남아 있던 일정(시작한 뒤라 지우지 않은 것)은 같은 시간에 그대로 두고, 지운 시간만 새로 만든다.
        // 실패하면 다음에 다시 해 볼 수 있게 블록을 그대로 둔다.
        let plan = (linked.map { $0.block.interval } + restorable).sorted { $0.start < $1.start }
        try? schedule(item, at: plan)
    }

    /// identifier로 먼저 찾는다. 일정을 다른 캘린더로 옮기면 identifier가 바뀔 수 있어서,
    /// 못 찾으면 마지막으로 확인한 시작 시각에 같은 제목으로 있는 일정을 찾는다.
    private func linkedEvent(for block: CalendarBlock, title: String) -> EKEvent? {
        guard hasFullAccess, let eventID = block.eventID else { return nil }
        if let event = store.event(withIdentifier: eventID) { return event }
        let predicate = store.predicateForEvents(withStart: block.start, end: block.start.addingTimeInterval(60), calendars: nil)
        return store.events(matching: predicate).first { $0.startDate == block.start && $0.title == title }
    }
}

extension TodoItem {
    func addBlock(eventID: String?, interval: DateInterval) {
        let block = CalendarBlock(eventID: eventID, start: interval.start, end: interval.end)
        modelContext?.insert(block)
        blocks.append(block)
    }

    func removeBlock(_ block: CalendarBlock) {
        blocks.removeAll { $0 === block }
        modelContext?.delete(block)
    }
}

enum CalendarError: LocalizedError {
    case noWritableCalendar
    case missingIdentifier

    var errorDescription: String? {
        switch self {
        case .noWritableCalendar: String(localized: "There's no calendar to add events to. Check your default calendar in the Calendar app.")
        case .missingIdentifier: String(localized: "Couldn't save the event to your calendar.")
        }
    }
}

private extension EKEvent {
    var isDeclinedByCurrentUser: Bool {
        attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}
