import Foundation
import SwiftData

/// 앱과 위젯이 함께 쓰는 SwiftData 저장소. App Group 컨테이너에 둔다.
enum TodoStore {
    static let appGroupID = "group.com.joonilkim.tuck"

    /// App Group을 쓸 수 없으면(서명에 App Group이 빠진 경우 등) 앱 전용 위치에 연다.
    static func makeContainer() throws -> ModelContainer {
        let configuration = groupStoreURL.map { ModelConfiguration(url: $0) } ?? ModelConfiguration()
        return try ModelContainer(for: TodoItem.self, CalendarBlock.self, configurations: configuration)
    }

    private static var groupStoreURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "Library/Application Support/default.store")
    }
}
