import EventKit
import SwiftData
import SwiftUI

extension View {
    /// 디버그 빌드에서 `-screenshots YES`로 실행하면 App Store 스크린샷용 예시 할 일과 일정을 넣고 지정한 탭과 시트를 띄운다.
    /// 출시 빌드에서는 아무것도 하지 않는다.
    func screenshotMode(selectedTab: Binding<TodoTab>) -> some View {
        #if DEBUG
        modifier(ScreenshotMode(selectedTab: selectedTab))
        #else
        self
        #endif
    }
}

#if DEBUG
/// 실행 인자
/// - `-screenshots YES`: 할 일과 예시 일정을 모두 지우고 새로 넣는다
/// - `-screenshotTab today|upcoming|done`
/// - `-screenshotSheet free|split|edit`: 빈 시간 찾기(통째 / 나눠 넣기) 또는 수정 화면을 띄운다
private struct ScreenshotMode: ViewModifier {
    @Binding var selectedTab: TodoTab

    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case schedule(TodoItem)
        case edit(TodoItem)

        var id: PersistentIdentifier {
            switch self {
            case .schedule(let item), .edit(let item): item.persistentModelID
            }
        }
    }

    private struct SeededItems {
        let free: TodoItem
        let split: TodoItem
        let edit: TodoItem
    }

    /// 예시 일정에 붙이는 표시. 다음 실행 때 이걸로 찾아 지운다.
    private static let marker = URL(string: "tuck-screenshots:busy")!

    func body(content: Content) -> some View {
        content
            .task { await start() }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .schedule(let item): ScheduleView(item: item)
                case .edit(let item): TodoFormView(item: item)
                }
            }
    }

    private func start() async {
        let arguments = UserDefaults.standard
        guard arguments.bool(forKey: "screenshots") else { return }
        let items = seed()
        switch arguments.string(forKey: "screenshotTab") {
        case "upcoming": selectedTab = .upcoming
        case "done": selectedTab = .done
        default: selectedTab = .today
        }
        // 다른 EKEventStore로 넣은 예시 일정이 앱의 저장소에도 보일 때까지 잠깐 기다린다.
        try? await Task.sleep(for: .seconds(1))
        switch arguments.string(forKey: "screenshotSheet") {
        case "free": sheet = .schedule(items.free)
        case "split": sheet = .schedule(items.split)
        case "edit": sheet = .edit(items.edit)
        default: break
        }
    }

    private func seed() -> SeededItems {
        let isKorean = Bundle.main.preferredLocalizations.first == "ko"
        func text(_ english: String, _ korean: String) -> String { isKorean ? korean : english }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: day, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func interval(_ start: Date, minutes: Int) -> DateInterval {
            DateInterval(start: start, duration: TimeInterval(minutes * 60))
        }

        // 지난번에 넣은 할 일(연결 일정 포함)과 예시 일정을 지운다.
        for item in (try? modelContext.fetch(FetchDescriptor<TodoItem>())) ?? [] {
            modelContext.deleteTodo(item, calendarService: calendarService)
        }
        let store = EKEventStore()
        let range = store.predicateForEvents(withStart: at(-1, 0), end: at(10, 0), calendars: nil)
        for event in store.events(matching: range) where event.url == Self.marker {
            try? store.remove(event, span: .thisEvent, commit: false)
        }

        // 빈 시간 찾기가 피해 갈 일정
        let busy = [
            (text("Team meeting", "팀 회의"), at(1, 9, 30), at(1, 10, 30)),
            (text("Lunch with Alex", "점심 약속"), at(1, 13), at(1, 14)),
            (text("Design review", "디자인 리뷰"), at(1, 15), at(1, 16, 30)),
            (text("Gym", "운동"), at(1, 19), at(1, 20, 30)),
            (text("1:1 with manager", "팀장님 1:1"), at(2, 10), at(2, 11)),
            (text("Doctor's appointment", "병원 예약"), at(2, 14), at(2, 15)),
            (text("Yoga", "요가"), at(2, 18), at(2, 19)),
        ]
        if let target = store.defaultCalendarForNewEvents {
            for (title, start, end) in busy {
                let event = EKEvent(eventStore: store)
                event.calendar = target
                event.title = title
                event.startDate = start
                event.endDate = end
                event.url = Self.marker
                try? store.save(event, span: .thisEvent, commit: false)
            }
        }
        try? store.commit()

        @discardableResult
        func add(
            _ title: String,
            due: Date,
            minutes: Int? = nil,
            reminds: Bool = true,
            scheduled: [DateInterval] = [],
            completed: Bool = false
        ) -> TodoItem {
            let item = TodoItem(title: title, dueDate: due, estimatedMinutes: minutes)
            item.remindsAtDue = reminds
            modelContext.insert(item)
            if !scheduled.isEmpty { try? calendarService.schedule(item, at: scheduled) }
            if completed { item.toggleCompleted() }
            return item
        }

        // 오늘
        add(text("Water the plants", "화분에 물 주기"), due: at(0, 20, 30))
        let slides = add(text("Finish slide deck", "발표 자료 마무리"), due: at(0, 21), minutes: 60, scheduled: [interval(at(0, 20), minutes: 60)])
        add(text("Call the dentist", "치과 예약 전화"), due: at(0, 22))
        add(text("Reply to client email", "고객 메일 답장"), due: at(0, 22, 30), minutes: 15)
        add(text("Pack lunch for tomorrow", "내일 도시락 싸기"), due: at(0, 23), minutes: 20)
        add(text("Pay phone bill", "휴대폰 요금 내기"), due: at(0, 23, 30), minutes: 15)

        // 예정
        let proposal = add(text("Write project proposal", "프로젝트 제안서 쓰기"), due: at(1, 12), minutes: 180)
        add(text("Grocery run", "장보기"), due: at(1, 18), minutes: 45, scheduled: [interval(at(1, 17), minutes: 45)])
        let reading = add(text("Read chapter 4 for book club", "독서 모임 4장 읽기"), due: at(2, 20), minutes: 90)
        add(text("Plan weekend trip", "주말 여행 계획"), due: at(3, 21), minutes: 30, scheduled: [interval(at(3, 19), minutes: 30)])
        add(text("Renew passport", "여권 갱신"), due: at(6, 17), reminds: false)

        // 완료
        add(text("Book flights", "항공권 예매"), due: at(-1, 18), minutes: 30, completed: true)
        add(text("Submit expense report", "경비 정산 제출"), due: at(-1, 17), minutes: 20, completed: true)

        try? modelContext.save()
        return SeededItems(free: reading, split: proposal, edit: slides)
    }
}
#endif
