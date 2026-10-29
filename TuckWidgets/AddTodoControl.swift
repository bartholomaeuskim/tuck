import AppIntents
import SwiftUI
import WidgetKit

/// 잠금 화면·제어 센터의 "할 일 추가" 버튼
struct AddTodoControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKind.addTodoControl) {
            ControlWidgetButton(action: AddTodoIntent()) {
                Label("Add To-Do", systemImage: "plus")
            }
        }
        .displayName("Add To-Do")
        .description("Opens tuck and starts a new to-do.")
    }
}
