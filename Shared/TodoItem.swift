import Foundation
import SwiftData

@Model
final class TodoItem {
    var title: String
    /// 마감. 빈 시간 추천은 이 시각 전까지만 한다.
    var dueDate: Date
    /// 예상 소요시간(분). 값이 있어야 빈 시간 추천을 쓸 수 있다.
    var estimatedMinutes: Int?
    var isCompleted: Bool
    /// 마감 시각에 알림을 보낼지. 기존 데이터도 마이그레이션되도록 선언부에 기본값을 둔다.
    var remindsAtDue: Bool = true
    /// 완료 탭 정렬에 쓴다. 완료를 취소하면 nil.
    var completedAt: Date?
    /// 이 할 일을 하려고 캘린더에 잡은 시간. 빈틈에 나눠 넣으면 여러 개가 된다.
    @Relationship(deleteRule: .cascade, inverse: \CalendarBlock.todo)
    var blocks: [CalendarBlock] = []

    init(title: String, dueDate: Date, estimatedMinutes: Int? = nil) {
        self.title = title
        self.dueDate = dueDate
        self.estimatedMinutes = estimatedMinutes
        self.isCompleted = false
    }

    func toggleCompleted() {
        isCompleted.toggle()
        completedAt = isCompleted ? .now : nil
    }

    /// 마감 시각부터 지난 것으로 본다. 완료한 할 일은 지나지 않은 것으로 친다.
    func isOverdue(at date: Date) -> Bool {
        !isCompleted && dueDate <= date
    }

    /// 캘린더에 잡혀 있는 시간(완료하면서 지운 일정은 빼고), 시간순
    var scheduledBlocks: [CalendarBlock] {
        blocks.filter { $0.eventID != nil }.sorted { $0.start < $1.start }
    }
}

/// 할 일을 하려고 캘린더에 잡은 시간 하나
@Model
final class CalendarBlock {
    /// 캘린더 일정 ID. 할 일을 완료하면서 지운 일정이면 nil이고, 완료를 취소하면 같은 시간에 다시 만든다.
    var eventID: String?
    /// 일정의 마지막으로 확인한 시간. 일정 ID가 바뀌었을 때 시작 시각과 제목으로 다시 찾는다.
    var start: Date
    var end: Date
    var todo: TodoItem?

    init(eventID: String?, start: Date, end: Date) {
        self.eventID = eventID
        self.start = start
        self.end = end
    }

    var interval: DateInterval {
        DateInterval(start: start, end: max(start, end))
    }
}

extension ModelContext {
    /// 할 일을 지우면서 아직 끝나지 않은 연결 일정도 함께 지운다.
    func deleteTodo(_ item: TodoItem, calendarService: CalendarService) {
        calendarService.removeLinkedEvents(for: item)
        delete(item)
        try? save()
    }

    /// 완료 상태를 바꾸고 연결 일정을 정리한 뒤 저장한다. 목록의 체크 버튼과 위젯 버튼이 함께 쓴다.
    func toggleCompletion(of item: TodoItem, calendarService: CalendarService) {
        item.toggleCompleted()
        if item.isCompleted {
            // 일찍 끝낸 할 일의 캘린더 일정이 남아 알람이 울리지 않도록 한다.
            calendarService.removeUnstartedLinkedEvents(for: item)
        } else {
            calendarService.restoreLinkedEvents(for: item)
        }
        // 저장되어야 마감 알림이 바로 취소/복구된다.
        try? save()
    }

    /// TodoItem.widgetID로 할 일을 찾는다. 그사이 지워졌으면 nil.
    func todo(widgetID: String) -> TodoItem? {
        guard let data = Data(base64Encoded: widgetID),
              let id = try? JSONDecoder().decode(PersistentIdentifier.self, from: data) else { return nil }
        var descriptor = FetchDescriptor<TodoItem>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return try? fetch(descriptor).first
    }
}

extension TodoItem {
    /// 위젯 버튼(앱 인텐트)에 넘기는 ID. 인텐트 매개변수로 쓸 수 있게 문자열로 바꾼다.
    var widgetID: String {
        (try? JSONEncoder().encode(persistentModelID))?.base64EncodedString() ?? ""
    }
}
