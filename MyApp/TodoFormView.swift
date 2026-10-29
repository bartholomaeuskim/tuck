import SwiftData
import SwiftUI
import UIKit

/// 할 일 추가와 수정을 함께 처리한다. item이 nil이면 새 할 일.
struct TodoFormView: View {
    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    private let item: TodoItem?
    @State private var title: String
    @State private var dueDate: Date
    @State private var remindsAtDue: Bool
    /// 0이면 '없음'
    @State private var estimatedMinutes: Int
    @State private var isConfirmingDelete = false
    /// 삭제하면 함께 지워질 캘린더 일정(아직 끝나지 않은 것)의 수
    @State private var deletingEventCount = 0
    /// 설정 앱에서 이 앱의 알림을 꺼 두었는지
    @State private var notificationsDenied = false
    @FocusState private var isTitleFocused: Bool

    private static let durationOptions = [0, 15, 30, 45, 60, 90, 120, 180, 240]

    init(defaultDueDate: Date) {
        item = nil
        _title = State(initialValue: "")
        _dueDate = State(initialValue: defaultDueDate)
        _remindsAtDue = State(initialValue: true)
        _estimatedMinutes = State(initialValue: 0)
    }

    init(item: TodoItem) {
        self.item = item
        _title = State(initialValue: item.title)
        _dueDate = State(initialValue: item.dueDate)
        _remindsAtDue = State(initialValue: item.remindsAtDue)
        _estimatedMinutes = State(initialValue: item.estimatedMinutes ?? 0)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                        .focused($isTitleFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            if !trimmedTitle.isEmpty { save() }
                        }
                }

                Section {
                    DatePicker("Deadline", selection: $dueDate)
                    Toggle("Remind at Deadline", isOn: $remindsAtDue)
                } footer: {
                    if remindsAtDue, notificationsDenied {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications are turned off in Settings, so you won't get this reminder.")
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                            }
                            .font(.footnote)
                        }
                    }
                }

                Section {
                    Picker("Estimated Time", selection: $estimatedMinutes) {
                        ForEach(Self.durationOptions, id: \.self) { minutes in
                            if minutes == 0 {
                                Text("None").tag(minutes)
                            } else {
                                Text(DisplayFormat.duration(minutes: minutes)).tag(minutes)
                            }
                        }
                    }
                } footer: {
                    Text("Add an estimated time, then tap the calendar button in the list to find free time before the deadline.")
                }

                if let item, !item.isCompleted, !item.scheduledBlocks.isEmpty {
                    // 마감과 헷갈리지 않도록 캘린더에 잡은 시간을 따로 보여 준다.
                    Section("Scheduled") {
                        ForEach(item.scheduledBlocks) { block in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DisplayFormat.dayAndTimeRange(block.interval))
                                if block.end > dueDate {
                                    Text("\(Image(systemName: "exclamationmark.triangle")) Ends after the deadline")
                                        .font(.caption)
                                        .foregroundStyle(Color.orange)
                                }
                            }
                        }
                    }
                }

                if let item {
                    Section {
                        Button("Delete To-Do", role: .destructive) {
                            deletingEventCount = calendarService.unfinishedLinkedEventCount(item)
                            isConfirmingDelete = true
                        }
                        .confirmationDialog("Delete this to-do?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) { delete() }
                        } message: {
                            if deletingEventCount > 0 {
                                Text("The \(deletingEventCount) linked calendar events will also be deleted.")
                            }
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "New To-Do" : "Edit To-Do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
            .onAppear {
                if item == nil { isTitleFocused = true }
            }
            .task(id: scenePhase) {
                // 설정 앱에서 알림을 켜고 돌아오면 안내를 바로 지운다.
                if scenePhase == .active { notificationsDenied = await ReminderScheduler.isDenied() }
            }
        }
    }

    private func save() {
        let minutes = estimatedMinutes > 0 ? estimatedMinutes : nil
        if let item {
            if item.title != trimmedTitle || item.estimatedMinutes != minutes {
                calendarService.updateLinkedEvents(for: item, title: trimmedTitle, estimatedMinutes: minutes)
            }
            item.title = trimmedTitle
            item.dueDate = dueDate
            item.remindsAtDue = remindsAtDue
            item.estimatedMinutes = minutes
        } else {
            let item = TodoItem(title: trimmedTitle, dueDate: dueDate, estimatedMinutes: minutes)
            item.remindsAtDue = remindsAtDue
            modelContext.insert(item)
        }
        try? modelContext.save()
        dismiss()
        Task { [modelContext, remindsAtDue] in
            // 알림을 켠 할 일을 저장할 때만 권한을 묻는다.
            if remindsAtDue { await ReminderScheduler.requestAuthorizationIfNeeded() }
            ReminderScheduler.sync(modelContext)
        }
    }

    private func delete() {
        guard let item else { return }
        dismiss()
        modelContext.deleteTodo(item, calendarService: calendarService)
    }
}
