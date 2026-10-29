import SwiftUI
import WidgetKit

@main
struct TuckWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        AddTodoControl()
    }
}
