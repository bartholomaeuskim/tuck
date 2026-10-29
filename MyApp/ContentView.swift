import EventKit
import SwiftData
import SwiftUI
import WidgetKit

struct ContentView: View {
    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// 오늘/예정을 나누는 기준. 자정이 지나거나 앱으로 돌아오면 갱신한다.
    @State private var now = Date.now
    @State private var selectedTab = TodoTab.today

    var body: some View {
        TabView(selection: $selectedTab) {
            TodoListView(tab: .today, now: now)
                .tabItem { Label(TodoTab.today.title, systemImage: TodoTab.today.systemImage) }
                .tag(TodoTab.today)
            TodoListView(tab: .upcoming, now: now)
                .tabItem { Label(TodoTab.upcoming.title, systemImage: TodoTab.upcoming.systemImage) }
                .tag(TodoTab.upcoming)
            TodoListView(tab: .done, now: now)
                .tabItem { Label(TodoTab.done.title, systemImage: TodoTab.done.systemImage) }
                .tag(TodoTab.done)
        }
        .onChange(of: AddTodoRequest.shared.isPending, initial: true) { _, isPending in
            // 잠금 화면의 "할 일 추가"로 열리면 오늘 탭으로 가서 폼을 띄운다.
            if isPending { selectedTab = .today }
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) {
                now = .now
            }
        }
        .task {
            // 할 일이 저장될 때마다 기한 알림을 다시 걸고 위젯을 새로 그린다.
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                ReminderScheduler.sync(modelContext)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.today)
            }
        }
        .task {
            // 캘린더 앱 등에서 일정이 바뀌면 목록의 일정 표시를 실제 캘린더에 맞춘다.
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                calendarService.syncLinkedEvents(in: modelContext)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            now = .now
            calendarService.refreshStatus()
            calendarService.syncLinkedEvents(in: modelContext)
            ReminderScheduler.sync(modelContext)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [TodoItem.self, CalendarBlock.self], inMemory: true)
        .environment(CalendarService())
}
