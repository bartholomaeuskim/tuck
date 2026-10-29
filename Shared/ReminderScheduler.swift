import Foundation
import SwiftData
import UserNotifications

/// 완료하지 않았고 알림을 켜 둔 할 일마다 기한 시각에 로컬 알림을 건다.
/// 할 일이 바뀔 때마다 전부 지우고 다시 거는 방식이라 할 일별 알림 ID를 따로 저장하지 않는다.
enum ReminderScheduler {
    /// iOS는 앱당 대기 중인 알림을 64개까지만 보관하므로 기한이 가까운 것부터 이만큼만 건다.
    private static let maxPending = 60

    /// 알림을 켠 할 일을 처음 저장할 때 한 번만 권한을 묻는다.
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// 설정 앱에서 이 앱의 알림을 꺼 두었는지
    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    static func sync(_ context: ModelContext) {
        let now = Date.now
        var descriptor = FetchDescriptor<TodoItem>(
            predicate: #Predicate { !$0.isCompleted && $0.remindsAtDue && $0.dueDate > now },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        descriptor.fetchLimit = maxPending
        let items = (try? context.fetch(descriptor)) ?? []

        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = String(localized: "It's due now.")
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.dueDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        }
    }
}

/// 앱을 보고 있을 때도 알림 배너를 띄운다. (기본값은 앱이 앞에 있으면 표시하지 않음)
final class ForegroundNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationPresenter()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
