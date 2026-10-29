import EventKit
import SwiftData
import SwiftUI
import UIKit

/// 지금부터 마감 전까지(최대 7일) 캘린더의 빈 시간에서 할 일을 할 시간을 추천하고, 고르면 캘린더 일정으로 추가한다.
/// 통째로 들어가는 자리가 없으면 빈틈에 나눠 넣는 안을, 그것도 안 되면 비어 있는 시간의 합을 보여 준다.
struct ScheduleView: View {
    let item: TodoItem

    @Environment(CalendarService.self) private var calendarService
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FreeTimeFinder.startMinutesKey) private var startMinutes = FreeTimeFinder.defaultStartMinutes
    @AppStorage(FreeTimeFinder.endMinutesKey) private var endMinutes = FreeTimeFinder.defaultEndMinutes

    /// 찾아본 마지막 시각. 마감 전에 찾아볼 시간이 없으면 nil.
    @State private var searchedUntil: Date?
    @State private var busyCount = 0
    @State private var proposal: ScheduleProposal?
    /// 이 할 일로 이미 캘린더에 잡은 시간
    @State private var scheduled: [DateInterval] = []
    /// 고른 시간(통째면 하나, 나눠 넣으면 여러 개). 확인창을 띄운다.
    @State private var pendingPlan: [DateInterval]?
    @State private var alert: AlertContent?

    private struct AlertContent {
        let title: String
        let message: String
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let suggestions: [TimeSuggestion]
        var id: Date { day }
    }

    private var hasSchedule: Bool { !scheduled.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                switch calendarService.authorizationStatus {
                case .fullAccess:
                    proposalSections
                case .notDetermined:
                    Section {
                        Button("Allow Calendar Access") {
                            Task { await calendarService.requestAccess() }
                        }
                    } footer: {
                        Text("Reads your calendar to find free time before the deadline, then adds the time you pick as an event.")
                    }
                default:
                    Section {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } footer: {
                        Text("Finding free time requires Full Access so the app can read your calendar. You can change calendar access in Settings.")
                    }
                }
            }
            .navigationTitle("Find Free Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: calendarService.authorizationStatus) {
                reload()
            }
            .task {
                // 다른 앱에서 캘린더가 바뀌면 다시 계산한다.
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    reload()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { calendarService.refreshStatus() }
            }
            .confirmationDialog(
                hasSchedule ? "Change the scheduled time?" : "Add to calendar?",
                isPresented: Binding(get: { pendingPlan != nil }, set: { if !$0 { pendingPlan = nil } }),
                titleVisibility: .visible,
                presenting: pendingPlan
            ) { plan in
                Button(hasSchedule ? "Change Schedule" : "Add to Calendar") { schedule(plan) }
            } message: { plan in
                Text((plan.map { DisplayFormat.dayAndTimeRange($0) } + [item.title]).joined(separator: "\n"))
            }
            .alert(
                alert?.title ?? "",
                isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
                presenting: alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
        }
    }

    // MARK: - 할 일 요약

    private var summarySection: some View {
        Section {
            LabeledContent("To-Do", value: item.title)
            if let minutes = item.estimatedMinutes {
                LabeledContent("Estimated Time", value: DisplayFormat.duration(minutes: minutes))
            }
            LabeledContent("Deadline", value: DisplayFormat.dayAndTime(item.dueDate))
            if !scheduled.isEmpty {
                LabeledContent("Scheduled") {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(scheduled, id: \.start) { interval in
                            Text(DisplayFormat.dayAndTimeRange(interval))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 추천

    @ViewBuilder
    private var proposalSections: some View {
        switch proposal {
        case .whole(let suggestions)?:
            let groups = dayGroups(suggestions)
            ForEach(groups) { group in
                Section {
                    ForEach(group.suggestions) { suggestion in
                        Button {
                            pick([suggestion.interval])
                        } label: {
                            suggestionRow(suggestion)
                        }
                        .disabled(isCurrent(suggestion.interval))
                    }
                } header: {
                    Text(DisplayFormat.day(group.day))
                } footer: {
                    if group.id == groups.last?.id { searchFooter }
                }
            }
        case .split(let pieces)?:
            Section {
                ForEach(pieces, id: \.start) { piece in
                    HStack {
                        Text(DisplayFormat.day(piece.start))
                        Spacer()
                        Text("\(DisplayFormat.timeRange(piece)) · \(DisplayFormat.duration(minutes: Int(piece.duration / 60)))")
                            .foregroundStyle(.secondary)
                    }
                }
                Button(hasSchedule ? "Change Schedule" : "Add to Calendar") { pick(pieces) }
            } header: {
                Text("Split into \(pieces.count) Parts")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("There's no single free block long enough before the deadline, so the time is split into parts of 30 minutes or more.")
                    searchFooter
                }
            }
        case .notEnoughTime(let free)?:
            messageSection(String(localized: "There's only \(DisplayFormat.duration(minutes: Int(free / 60))) of free time before the deadline."))
        case .tooFragmented(let free)?:
            messageSection(String(localized: "There's \(DisplayFormat.duration(minutes: Int(free / 60))) of free time before the deadline, but no single free block is long enough."))
        case nil:
            messageSection(noSearchTimeMessage)
        }
    }

    private func messageSection(_ message: String) -> some View {
        Section {
            Text(message)
                .foregroundStyle(.secondary)
        } footer: {
            searchFooter
        }
    }

    @ViewBuilder
    private var searchFooter: some View {
        if let searchedUntil {
            VStack(alignment: .leading, spacing: 2) {
                Text("Searched until \(DisplayFormat.dayAndTime(searchedUntil)).")
                Text("Avoided \(busyCount) calendar events.")
            }
        }
    }

    private func suggestionRow(_ suggestion: TimeSuggestion) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayFormat.timeRange(suggestion.interval))
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(isCurrent(suggestion.interval) ? String(localized: "Scheduled") : String(localized: "Free until \(DisplayFormat.time(suggestion.freeUntil))"))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Image(systemName: hasSchedule ? "arrow.right.circle" : "calendar.badge.plus")
                .font(.title3)
        }
        .contentShape(Rectangle())
    }

    private var noSearchTimeMessage: String {
        if item.dueDate <= .now {
            return String(localized: "The deadline has passed, so there's no time to suggest.")
        }
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: .now) ?? .now
        let end = calendar.date(bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: .now) ?? .now
        return String(localized: "There's no time to search before the deadline. Free time is searched between \(DisplayFormat.time(start)) and \(DisplayFormat.time(end)) each day.")
    }

    private func dayGroups(_ suggestions: [TimeSuggestion]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        for suggestion in suggestions {
            let day = calendar.startOfDay(for: suggestion.interval.start)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1] = DayGroup(day: day, suggestions: last.suggestions + [suggestion])
            } else {
                groups.append(DayGroup(day: day, suggestions: [suggestion]))
            }
        }
        return groups
    }

    /// 이미 이 시간 하나로 잡혀 있으면 다시 고를 필요가 없다.
    private func isCurrent(_ interval: DateInterval) -> Bool {
        scheduled == [interval]
    }

    // MARK: - 동작

    private func reload() {
        guard calendarService.authorizationStatus == .fullAccess else { return }
        let linked = calendarService.syncLinkedEvents(for: item)
        scheduled = linked.map { $0.block.interval }
        let windows = FreeTimeFinder.searchWindows(now: .now, deadline: item.dueDate, startMinutes: startMinutes, endMinutes: endMinutes)
        guard let first = windows.first, let last = windows.last, let minutes = item.estimatedMinutes else {
            searchedUntil = nil
            busyCount = 0
            proposal = nil
            return
        }
        searchedUntil = last.end
        // 이 할 일의 일정은 옮길 수 있으므로 바쁜 시간으로 치지 않는다.
        let ownEventIDs = Set(linked.compactMap { $0.block.eventID })
        let busy = calendarService.busyIntervals(in: DateInterval(start: first.start, end: last.end), ignoring: ownEventIDs)
        // 밤사이처럼 탐색 시간대 밖에 있는 일정은 피한 일정으로 세지 않는다.
        busyCount = busy.filter { event in
            windows.contains { $0.start < event.end && event.start < $0.end }
        }.count
        let gaps = FreeTimeFinder.freeGaps(in: windows, avoiding: busy)
        proposal = FreeTimeFinder.proposal(duration: TimeInterval(minutes * 60), gaps: gaps)
    }

    /// 시트를 열어 둔 채 시간이 지나면 이미 시작 시각이 지난 추천이 남아 있을 수 있다.
    private func hasPassed(_ plan: [DateInterval]) -> Bool {
        (plan.first?.start ?? .distantPast) < .now
    }

    private func pick(_ plan: [DateInterval]) {
        if hasPassed(plan) {
            refreshAfterTimePassed()
        } else {
            pendingPlan = plan
        }
    }

    private func refreshAfterTimePassed() {
        reload()
        alert = AlertContent(title: String(localized: "That Time Has Passed"), message: String(localized: "The suggestions were updated."))
    }

    private func schedule(_ plan: [DateInterval]) {
        guard !hasPassed(plan) else { return refreshAfterTimePassed() }
        do {
            try calendarService.schedule(item, at: plan)
            // 자동 저장 전에 앱이 종료되면 일정과의 연결이 끊겨 다음에 중복 일정이 생기므로 바로 저장한다.
            try? modelContext.save()
            dismiss()
        } catch {
            alert = AlertContent(title: String(localized: "Couldn't Add to Calendar"), message: error.localizedDescription)
        }
    }
}
