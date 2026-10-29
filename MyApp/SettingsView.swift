import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(FreeTimeFinder.startMinutesKey) private var startMinutes = FreeTimeFinder.defaultStartMinutes
    @AppStorage(FreeTimeFinder.endMinutesKey) private var endMinutes = FreeTimeFinder.defaultEndMinutes

    /// 시작과 끝 사이에 둘 최소 간격(분)
    private static let minimumSpan = 15

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: time($startMinutes), in: startRange, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: time($endMinutes), in: endRange, displayedComponents: .hourAndMinute)
                } header: {
                    Text("Free Time Search")
                } footer: {
                    Text("Suggestions only use this part of the day.")
                }

                Section {
                    Button {
                        // 앱 언어는 iOS의 앱별 언어 설정(설정 > 이 앱 > 언어)을 따른다.
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        HStack {
                            Text("Language")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Text(currentLanguageName)
                                .foregroundStyle(Color.secondary)
                            Image(systemName: "arrow.up.forward")
                                .font(.footnote)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                } footer: {
                    // 기기에 언어가 하나뿐이면 설정 앱의 이 앱 페이지에 '언어' 항목이 나오지 않는다.
                    Text("Choose this app's language in Settings. If you don't see Language there, first add another language in General > Language & Region.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// 자정부터의 분 ↔ 오늘 그 시각
    private func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
    }

    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { date(minutes.wrappedValue) },
            set: { newValue in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var startRange: ClosedRange<Date> {
        date(0)...date(max(0, endMinutes - Self.minimumSpan))
    }

    private var endRange: ClosedRange<Date> {
        let lastMinute = 23 * 60 + 59
        return date(min(lastMinute, startMinutes + Self.minimumSpan))...date(lastMinute)
    }

    /// "한국어", "English" 처럼 지금 앱이 쓰는 언어 이름
    private var currentLanguageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

#Preview {
    SettingsView()
}
