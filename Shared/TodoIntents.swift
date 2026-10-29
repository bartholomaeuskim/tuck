import AppIntents
import Foundation
import Observation
import SwiftData

/// 위젯의 체크 버튼. 위젯 확장 안에서 실행되어 App Group 저장소의 할 일을 완료 처리한다.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete To-Do"
    static let isDiscoverable = false

    @Parameter(title: "To-Do")
    var todoID: String

    init() {}

    init(todoID: String) {
        self.todoID = todoID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let container = try TodoStore.makeContainer()
        let context = container.mainContext
        // 위젯이 오래된 내용을 보여 주는 사이 앱에서 이미 완료했거나 지웠을 수 있다.
        if let item = context.todo(widgetID: todoID), !item.isCompleted {
            context.toggleCompletion(of: item, calendarService: CalendarService())
            ReminderScheduler.sync(context)
        }
        return .result()
    }
}

/// 잠금 화면 제어 항목 "할 일 추가". 앱을 열고 오늘 탭에 새 할 일 폼을 띄운다.
/// 앱에서 실행되므로 앱과 위젯 확장 양쪽에 들어 있어야 한다.
struct AddTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Opens tuck and starts a new to-do.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AddTodoRequest.shared.isPending = true
        return .result()
    }
}

/// AddTodoIntent가 남긴 요청. 오늘 탭이 보이면 폼을 띄우고 지운다.
@MainActor
@Observable
final class AddTodoRequest {
    static let shared = AddTodoRequest()
    var isPending = false
}

enum WidgetKind {
    static let today = "TodayTodos"
    static let addTodoControl = "com.joonilkim.tuck.AddTodoControl"
}
