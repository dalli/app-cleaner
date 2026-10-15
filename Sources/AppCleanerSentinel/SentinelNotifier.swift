import CleanerCore
import Foundation
import UserNotifications

/// 알림 보내기·누름 처리 (ui-ux.md S10 "알림").
/// `--log-only`이거나 `.app` 번들 밖에서 실행되면(`UNUserNotificationCenter`를 쓸 수 없음) 표준 출력에만 기록한다.
@MainActor
final class SentinelNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Category {
        static let trashedApp = "trashedApp"
        static let orphans = "orphans"
    }
    enum Action {
        static let cleanLeftovers = "cleanLeftovers"
        static let review = "review"
    }
    nonisolated static let linkKey = "link"

    let logOnly: Bool
    /// 알림(또는 동작 버튼)을 누르면 본 앱의 해당 화면을 연다
    var onOpen: (SentinelLink) -> Void = { _ in }

    init(logOnly: Bool) {
        self.logOnly = logOnly || Bundle.main.bundleIdentifier == nil
    }

    private var center: UNUserNotificationCenter? { logOnly ? nil : UNUserNotificationCenter.current() }

    /// 카테고리 등록, 허용 여부 확인 — 아직 묻지 않았고 `request`면 macOS가 사용자에게 묻는다
    func setUp(request: Bool) async -> SentinelNotificationState? {
        guard let center else { return nil }
        center.delegate = self
        let clean = UNNotificationAction(identifier: Action.cleanLeftovers, title: S("잔여물도 정리"), options: [.foreground])
        let review = UNNotificationAction(identifier: Action.review, title: S("확인하기"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.trashedApp, actions: [clean], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.orphans, actions: [review], intentIdentifiers: []),
        ])
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && request {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }

    /// "Slack을 휴지통으로 옮겼습니다" → 잔여물도 정리 (S2)
    func notifyTrashed(_ app: TrashedApp) {
        let title = S("%@ 휴지통으로 옮겼습니다", SentinelStrings.withObjectParticle(app.name, language: sentinelLanguage))
        let body = S("설정·캐시 같은 잔여물이 남아 있을 수 있습니다. 검사만 하고 아무것도 지우지 않습니다.")
        post(id: "trash-\(app.bundleID ?? app.name)", title: title, body: body, category: Category.trashedApp,
             link: .inspect(path: app.url.path))
    }

    /// "정리할 수 있는 잔여물이 있습니다" → 확인하기 (S5)
    func notifyOrphans(_ summary: OrphanAlertSummary) {
        let body = S("삭제된 앱 %lld개의 잔여물 %@를 찾았습니다 (신뢰도 높음).", summary.groupCount,
                     SentinelFormat.size(summary.totalSize))
        post(id: "orphans", title: S("정리할 수 있는 잔여물이 있습니다"), body: body, category: Category.orphans, link: .orphans)
    }

    private func post(id: String, title: String, body: String, category: String, link: SentinelLink) {
        guard let center else {
            sentinelLog("알림: \(title) — \(body) [\(link.url.absoluteString)]")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.sound = .default
        content.userInfo = [Self.linkKey: link.url.absoluteString]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// 메뉴 막대 앱은 늘 "앞에 있는" 것으로 취급될 수 있으므로 배너를 그대로 보인다
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let raw = response.notification.request.content.userInfo[Self.linkKey] as? String,
              let url = URL(string: raw), let link = SentinelLink(url: url) else { return }
        await MainActor.run { self.onOpen(link) }
    }
}
