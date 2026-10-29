import SwiftData
import SwiftUI
import UserNotifications

@main struct MyApp: App {
    @State private var calendarService = CalendarService()
    private let container: ModelContainer

    init() {
        UNUserNotificationCenter.current().delegate = ForegroundNotificationPresenter.shared
        // 위젯과 같은 저장소를 보도록 App Group에서 연다.
        do {
            container = try TodoStore.makeContainer()
        } catch {
            fatalError("Couldn't open the to-do store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(calendarService)
        }
        .modelContainer(container)
    }
}
