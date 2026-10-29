import SwiftData
import SwiftUI

enum TodoTab {
    case today, upcoming, done

    var title: String {
        switch self {
        case .today: String(localized: "Today")
        case .upcoming: String(localized: "Upcoming")
        case .done: String(localized: "Completed")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .upcoming: "calendar"
        case .done: "checkmark.circle"
        }
    }

    /// 새 할 일의 기본 기한. 오늘 탭은 다음 정시, 예정 탭은 내일 오전 9시.
    func defaultDueDate(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .upcoming:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .today, .done:
            let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
            if calendar.isDate(nextHour, inSameDayAs: now) { return nextHour }
            // 밤 11시 이후에는 다음 정시가 내일이 되어 오늘 탭에서 사라지므로 오늘 23:59로 둔다.
            return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
        }
    }
}

struct TodoListView: View {
    let tab: TodoTab
    let now: Date

    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [TodoItem]
    @State private var isShowingSettings = false
    @State private var isAdding = false
    @State private var editingItem: TodoItem?
    @State private var schedulingItem: TodoItem?
    @State private var deletingItem: TodoItem?
    @State private var deletingEventCount = 0

    /// now는 '오늘'의 경계를 정하는 기준 시각. 날짜가 바뀌면 상위 뷰가 새 값을 넘겨준다.
    init(tab: TodoTab, now: Date) {
        self.tab = tab
        self.now = now
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        switch tab {
        case .today:
            _items = Query(filter: #Predicate<TodoItem> { !$0.isCompleted && $0.dueDate < startOfTomorrow }, sort: \.dueDate)
        case .upcoming:
            _items = Query(filter: #Predicate<TodoItem> { !$0.isCompleted && $0.dueDate >= startOfTomorrow }, sort: \.dueDate)
        case .done:
            // 최근에 완료한 것부터. completedAt이 없는 예전 항목은 뒤로 가고 기한순으로 놓인다.
            _items = Query(
                filter: #Predicate<TodoItem> { $0.isCompleted },
                sort: [SortDescriptor(\.completedAt, order: .reverse), SortDescriptor(\.dueDate, order: .reverse)]
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    TodoRow(
                                        item: item,
                                        showsDay: section.rowsShowDay,
                                        onEdit: { editingItem = item },
                                        onSchedule: { schedulingItem = item }
                                    )
                                    .swipeActions(edge: .trailing) {
                                        if item.scheduledBlocks.isEmpty {
                                            Button("Delete", systemImage: "trash", role: .destructive) {
                                                modelContext.deleteTodo(item, calendarService: calendarService)
                                            }
                                        } else {
                                            // 확인창을 먼저 띄우므로 destructive 역할 대신 색만 맞춘다.
                                            Button("Delete", systemImage: "trash") { confirmDelete(item) }
                                                .tint(.red)
                                        }
                                    }
                                    // 확인창이 지우려는 행을 가리키도록 행마다 단다.
                                    .confirmationDialog(
                                        "Delete this to-do?",
                                        isPresented: Binding(get: { deletingItem == item }, set: { if !$0 { deletingItem = nil } }),
                                        titleVisibility: .visible
                                    ) {
                                        Button("Delete", role: .destructive) {
                                            modelContext.deleteTodo(item, calendarService: calendarService)
                                        }
                                    } message: {
                                        Text("The \(deletingEventCount) linked calendar events will also be deleted.")
                                    }
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(tab.title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                if tab != .done {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add To-Do", systemImage: "plus") { isAdding = true }
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $isAdding) {
                TodoFormView(defaultDueDate: tab.defaultDueDate(now: .now))
            }
            .sheet(item: $editingItem) { item in
                TodoFormView(item: item)
            }
            .sheet(item: $schedulingItem) { item in
                ScheduleView(item: item)
            }
            .onChange(of: AddTodoRequest.shared.isPending, initial: true) { _, isPending in
                guard isPending, tab == .today else { return }
                AddTodoRequest.shared.isPending = false
                isAdding = true
            }
        }
    }

    /// 함께 지워질 캘린더 일정이 있을 때만 확인한다. 사용자가 그 일정에 메모나 장소를 넣어 뒀을 수 있다.
    private func confirmDelete(_ item: TodoItem) {
        deletingEventCount = calendarService.unfinishedLinkedEventCount(item)
        if deletingEventCount > 0 {
            deletingItem = item
        } else {
            modelContext.deleteTodo(item, calendarService: calendarService)
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        switch tab {
        case .today:
            ContentUnavailableView("Nothing Due Today", systemImage: tab.systemImage, description: Text("Tap + to add a to-do."))
        case .upcoming:
            ContentUnavailableView("No Upcoming To-Dos", systemImage: tab.systemImage, description: Text("To-dos due tomorrow or later show up here."))
        case .done:
            ContentUnavailableView("No Completed To-Dos", systemImage: tab.systemImage, description: Text("To-dos you check off show up here."))
        }
    }

    // MARK: - Sections

    private struct TodoSection: Identifiable {
        let id: String
        let title: String?
        let items: [TodoItem]
        /// 섹션 제목에 날짜가 없으면 행에 날짜까지 보여준다.
        let rowsShowDay: Bool
    }

    /// items는 이미 기한순으로 정렬되어 있다.
    private var sections: [TodoSection] {
        let calendar = Calendar.current
        switch tab {
        case .today:
            let startOfToday = calendar.startOfDay(for: now)
            let overdue = items.filter { $0.dueDate < startOfToday }
            let today = items.filter { $0.dueDate >= startOfToday }
            var result: [TodoSection] = []
            if !overdue.isEmpty {
                result.append(TodoSection(id: "overdue", title: String(localized: "Overdue"), items: overdue, rowsShowDay: true))
            }
            if !today.isEmpty {
                result.append(TodoSection(id: "today", title: overdue.isEmpty ? nil : String(localized: "Today"), items: today, rowsShowDay: false))
            }
            return result

        case .upcoming:
            var groups: [(day: Date, items: [TodoItem])] = []
            for item in items {
                let day = calendar.startOfDay(for: item.dueDate)
                if groups.last?.day == day {
                    groups[groups.count - 1].items.append(item)
                } else {
                    groups.append((day, [item]))
                }
            }
            return groups.map { group in
                TodoSection(id: group.day.ISO8601Format(), title: DisplayFormat.day(group.day), items: group.items, rowsShowDay: false)
            }

        case .done:
            return [TodoSection(id: "done", title: nil, items: items, rowsShowDay: true)]
        }
    }
}

struct TodoRow: View {
    let item: TodoItem
    let showsDay: Bool
    let onEdit: () -> Void
    let onSchedule: () -> Void

    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @State private var reachedDue = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation {
                    modelContext.toggleCompletion(of: item, calendarService: calendarService)
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.isCompleted ? "Mark as Not Completed" : "Mark as Completed")

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? Color.secondary : Color.primary)
                    details
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !item.isCompleted, item.estimatedMinutes != nil {
                Button(action: onSchedule) {
                    Image(systemName: item.scheduledBlocks.isEmpty ? "calendar.badge.plus" : "calendar.badge.checkmark")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Find Free Time")
            }
        }
    }

    private var details: some View {
        // List 안의 Label은 아이콘 간격이 넓어서 Text에 아이콘을 넣어 붙인다.
        HStack(spacing: 10) {
            // 깃발은 마감, 달력은 캘린더에 잡은 시간
            Text("\(Image(systemName: "flag")) \(showsDay ? DisplayFormat.dayAndTime(item.dueDate) : DisplayFormat.time(item.dueDate))")
                .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                .task(id: item.dueDate) { await waitForDue() }
                .accessibilityLabel("Deadline")
                .accessibilityValue(DisplayFormat.dayAndTime(item.dueDate))
            if !item.isCompleted, !item.remindsAtDue {
                Image(systemName: "bell.slash")
                    .accessibilityLabel("Deadline reminder off")
            }
            if let minutes = item.estimatedMinutes {
                Text("\(Image(systemName: "hourglass")) \(DisplayFormat.duration(minutes: minutes))")
            }
            if let scheduled = scheduledSummary {
                Text("\(Image(systemName: "calendar")) \(scheduled)")
                    .accessibilityLabel("Scheduled")
                    .accessibilityValue(scheduled)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 다음에 할 시간(다 지났으면 마지막 시간). 나눠 넣었으면 "+1"처럼 나머지 수를 붙인다.
    /// 목록은 마감 날짜로 묶이므로, 마감과 같은 날이 아니면 날짜도 붙인다.
    private var scheduledSummary: String? {
        let blocks = item.scheduledBlocks
        guard let next = blocks.first(where: { $0.end > .now }) ?? blocks.last else { return nil }
        let sameDay = Calendar.current.isDate(next.start, inSameDayAs: item.dueDate)
        let time = sameDay ? DisplayFormat.time(next.start) : DisplayFormat.dayAndTime(next.start)
        return blocks.count > 1 ? "\(time) +\(blocks.count - 1)" : time
    }

    private var isOverdue: Bool {
        item.isOverdue(at: reachedDue ? item.dueDate : .now)
    }

    /// 앱을 켜 둔 채 마감이 지나도 행은 다시 그려지지 않으므로 마감 시각까지 기다렸다가 표시를 바꾼다.
    private func waitForDue() async {
        reachedDue = false
        let remaining = item.dueDate.timeIntervalSinceNow
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
        if !Task.isCancelled { reachedDue = true }
    }
}
