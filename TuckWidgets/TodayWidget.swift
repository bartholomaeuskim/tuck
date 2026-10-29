import AppIntents
import SwiftData
import SwiftUI
import WidgetKit

/// 위젯에 그릴 할 일. 타임라인 항목은 다른 스레드로 넘어가므로 모델 대신 값만 담는다.
struct WidgetTodo: Identifiable, Hashable {
    /// CompleteTodoIntent에 넘기는 TodoItem.widgetID
    let id: String
    let title: String
    let dueDate: Date
}

struct TodayEntry: TimelineEntry {
    let date: Date
    let todos: [WidgetTodo]

    static let sample = TodayEntry(date: .now, todos: [
        WidgetTodo(id: "1", title: String(localized: "Write the report draft"), dueDate: .now.addingTimeInterval(3600)),
        WidgetTodo(id: "2", title: String(localized: "Grocery shopping"), dueDate: .now.addingTimeInterval(3 * 3600)),
        WidgetTodo(id: "3", title: String(localized: "Call the dentist"), dueDate: .now.addingTimeInterval(5 * 3600)),
    ])
}

struct TodayProvider: TimelineProvider {
    /// 앱의 오늘 탭과 같이 기한이 지난 것까지 포함해 기한순으로 앞에서 3개
    static let limit = 3

    func placeholder(in context: Context) -> TodayEntry {
        .sample
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        Task { @MainActor in
            completion(context.isPreview ? .sample : Self.loadEntry(now: .now))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        Task { @MainActor in
            let now = Date.now
            let entry = Self.loadEntry(now: now)
            // 보이는 할 일의 기한마다 다시 그려 빨간색으로 바꾸고, 자정에는 오늘 목록을 새로 읽는다.
            let dueTimes = entry.todos.map(\.dueDate).filter { $0 > now }
            let entries = [entry] + dueTimes.map { TodayEntry(date: $0, todos: entry.todos) }
            let calendar = Calendar.current
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
            completion(Timeline(entries: entries, policy: .after(tomorrow)))
        }
    }

    @MainActor
    private static func loadEntry(now: Date) -> TodayEntry {
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted && $0.dueDate < startOfTomorrow },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        descriptor.fetchLimit = limit
        guard let container = try? TodoStore.makeContainer(),
              let items = try? container.mainContext.fetch(descriptor) else {
            return TodayEntry(date: now, todos: [])
        }
        let todos = items.map { WidgetTodo(id: $0.widgetID, title: $0.title, dueDate: $0.dueDate) }
        return TodayEntry(date: now, todos: todos)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.today, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today's To-Dos")
        .description("Check off today's to-dos without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct TodayWidgetView: View {
    let entry: TodayEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryRectangular:
            lockScreen
        default:
            homeScreen
        }
    }

    // MARK: - 홈 화면

    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            if entry.todos.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing Due Today")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.todos) { todo in
                    homeRow(todo)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func homeRow(_ todo: WidgetTodo) -> some View {
        HStack(spacing: 8) {
            completeButton(todo)
                .font(.title3)
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 0) {
                    Text(todo.title)
                        .font(.footnote)
                        .lineLimit(1)
                    dueText(todo)
                        .font(.caption2)
                }
            } else {
                Text(todo.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                dueText(todo)
                    .font(.caption)
            }
        }
    }

    // MARK: - 잠금 화면

    @ViewBuilder
    private var lockScreen: some View {
        if entry.todos.isEmpty {
            Text("Nothing Due Today")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entry.todos) { todo in
                    HStack(spacing: 6) {
                        completeButton(todo)
                        // 남는 폭은 모두 제목에 주고, 모자라면 시간 대신 제목을 줄인다.
                        Text(todo.title)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        lockScreenDueText(todo)
                            .layoutPriority(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 잠금 화면은 한 가지 색으로만 그려져 빨간색이 보이지 않으므로 지난 마감은 기호로 표시한다.
    /// 폭이 좁아서 오늘 마감은 시각만, 다른 날은 날짜만 보여 준다.
    private func lockScreenDueText(_ todo: WidgetTodo) -> Text {
        let isToday = Calendar.current.isDate(todo.dueDate, inSameDayAs: entry.date)
        let label = isToday ? DisplayFormat.time(todo.dueDate) : DisplayFormat.day(todo.dueDate)
        let text = todo.dueDate <= entry.date ? Text("\(Image(systemName: "exclamationmark.circle")) \(label)") : Text(label)
        return text
            .font(.caption)
            .monospacedDigit()
    }

    // MARK: - 공통

    private func completeButton(_ todo: WidgetTodo) -> some View {
        Button(intent: CompleteTodoIntent(todoID: todo.id)) {
            Image(systemName: "circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark as Completed")
    }

    /// 오늘 기한은 시각만, 어제 이전에 지난 기한은 날짜도 보여 준다.
    private func dueText(_ todo: WidgetTodo) -> some View {
        let isToday = Calendar.current.isDate(todo.dueDate, inSameDayAs: entry.date)
        return Text(isToday ? DisplayFormat.time(todo.dueDate) : DisplayFormat.dayAndTime(todo.dueDate))
            .foregroundStyle(todo.dueDate <= entry.date ? Color.red : Color.secondary)
            .lineLimit(1)
    }
}
