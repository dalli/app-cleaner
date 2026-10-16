import CleanerCore
import Foundation
import ServiceManagement
import Testing
@testable import AppCleanerGUI

/// S7 Sentinel 설정과 Sentinel 링크 처리 (ui-ux.md S10). 로그인 항목은 메모리 구현으로만 바꾼다.
@MainActor
@Suite("Sentinel (S7·S10)")
struct SentinelSettingsTests {
    @Test func settingsPersistUnderSharedKeys() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(defaults: store)
        #expect(!settings.trashWatchEnabled && settings.periodicScan == .off)
        settings.trashWatchEnabled = true
        settings.periodicScan = .monthly
        // Sentinel이 같은 키로 읽는다
        #expect(store.object(forKey: SentinelIdentity.Keys.trashWatch) as? Bool == true)
        #expect(store.object(forKey: SentinelIdentity.Keys.periodicScan) as? String == "monthly")
        let reopened = AppSettings(defaults: store)
        #expect(reopened.trashWatchEnabled && reopened.periodicScan == .monthly)

        // Sentinel이 기록한 상태
        let scanned = Date(timeIntervalSince1970: 1_000_000)
        store.set(scanned, forKey: SentinelIdentity.Keys.statusLastScan)
        store.set("denied", forKey: SentinelIdentity.Keys.statusNotifications)
        let status = reopened.sentinelPreferences()
        #expect(status.lastScan == scanned && status.notifications == .denied)
    }

    @Test func enablingAFeatureRegistersSentinelOnce() {
        let sentinel = InMemorySentinelService()
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), sentinel: sentinel)
        #expect(model.sentinelRegistration == .disabled)

        model.setTrashWatch(true)
        #expect(sentinel.registration == .enabled && model.sentinelRegistration == .enabled)
        #expect(sentinel.settingsChangedCount == 1)
        #expect(model.settings.trashWatchEnabled)

        // 이미 등록돼 있으면 다시 등록하지 않고 설정 변경만 알린다 (메뉴에서 종료했으면 다시 띄움)
        model.setPeriodicScan(.weekly)
        #expect(sentinel.settingsChangedCount == 2 && sentinel.launchCount == 1)
        #expect(model.settings.periodicScan == .weekly)
    }

    @Test func turningEverythingOffUnregisters() async {
        let sentinel = InMemorySentinelService()
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), sentinel: sentinel)
        model.setTrashWatch(true)
        model.setPeriodicScan(.monthly)
        model.setTrashWatch(false)
        // 정기 스캔이 아직 켜져 있으므로 유지
        #expect(sentinel.registration == .enabled)
        model.setPeriodicScan(.off)
        #expect(await waitUntil { model.sentinelRegistration == .disabled })
        #expect(sentinel.registration == .disabled)
        // 실행 중인 Sentinel은 알림을 받고 스스로 종료한다
        #expect(sentinel.settingsChangedCount == 4)
    }

    @Test func registrationFailureIsShown() {
        let sentinel = InMemorySentinelService()
        sentinel.registerError = CocoaError(.featureUnsupported)
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), sentinel: sentinel)
        model.setTrashWatch(true)
        #expect(model.sentinelError != nil)
        #expect(model.sentinelRegistration == .disabled)
        // 다시 켜면 오류가 사라진다
        model.setTrashWatch(false)
        model.setTrashWatch(true)
        #expect(model.sentinelError == nil && model.sentinelRegistration == .enabled)
    }

    /// 다른 빌드로 등록된 로그인 항목은 실행되지 않는다 (#50) — 앱 시작 때 해제 → 다시 등록하고 빌드를 기록한다
    @Test func startupReregistersSentinelRegisteredByAnotherBuild() async {
        let store = InMemorySettingsStore()
        store.set(true, forKey: SentinelIdentity.Keys.trashWatch)
        store.set("old", forKey: "sentinelRegisteredBuild")
        let sentinel = InMemorySentinelService(registration: .enabled, buildID: "new")
        let model = AppModel(engine: fastEngine(), settings: AppSettings(defaults: store), sentinel: sentinel)
        #expect(await waitUntil { model.settings.sentinelRegisteredBuild == "new" })
        #expect(sentinel.unregisterCount == 1 && sentinel.registerCount == 1)
        #expect(model.sentinelRegistration == .enabled && model.sentinelError == nil)
        #expect(store.object(forKey: "sentinelRegisteredBuild") as? String == "new")

        // 같은 빌드로 다시 시작하면 그대로 둔다
        _ = AppModel(engine: fastEngine(), settings: AppSettings(defaults: store), sentinel: sentinel)
        #expect(sentinel.unregisterCount == 1 && sentinel.registerCount == 1)
    }

    @Test func startupLeavesSentinelAloneWhenNotWantedOrBuildUnknown() {
        // 기능이 모두 꺼져 있음
        let off = InMemorySentinelService(registration: .enabled, buildID: "new")
        _ = AppModel(engine: fastEngine(), settings: .inMemory(), sentinel: off)
        // 빌드를 알 수 없음 (개발 실행)
        let store = InMemorySettingsStore()
        store.set(true, forKey: SentinelIdentity.Keys.trashWatch)
        let unknown = InMemorySentinelService(registration: .enabled, buildID: nil)
        _ = AppModel(engine: fastEngine(), settings: AppSettings(defaults: store), sentinel: unknown)
        // 사용자 승인 대기
        let pending = InMemorySentinelService(registration: .requiresApproval, buildID: "new")
        _ = AppModel(engine: fastEngine(), settings: AppSettings(defaults: store), sentinel: pending)
        for s in [off, unknown, pending] { #expect(s.unregisterCount == 0 && s.registerCount == 0) }
    }

    @Test func registeringRecordsBuild() {
        let sentinel = InMemorySentinelService(buildID: "b1")
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), sentinel: sentinel)
        model.setTrashWatch(true)
        #expect(model.settings.sentinelRegisteredBuild == "b1")
    }

    /// 한 번도 등록하지 않은 로그인 항목은 번들에 Sentinel이 있어도 `.notFound` (macOS 27) —
    /// "사용할 수 없음"으로 보면 등록을 시도하지 않아 켤 수 없다
    @Test func notFoundStatusMeansNotRegistered() {
        #expect(SentinelRegistration(status: .notFound) == .disabled)
        #expect(SentinelRegistration(status: .notRegistered) == .disabled)
        #expect(SentinelRegistration(status: .enabled) == .enabled)
        #expect(SentinelRegistration(status: .requiresApproval) == .requiresApproval)
    }

    /// Sentinel(로그인 항목)은 본 앱의 전체 디스크 접근을 함께 쓴다 — 본 앱에 권한이 있으면 지난 "읽을 수 없음"으로 안내하지 않는다
    @Test func trashUnreadableNoticeFollowsMainAppFullDiskAccess() {
        func model(fullDiskAccess: PermissionStatus.State) -> AppModel {
            var o = DemoCleanerEngine.Options()
            o.delayScale = 0
            o.fullDiskAccess = fullDiskAccess
            let store = InMemorySettingsStore()
            store.set(true, forKey: SentinelIdentity.Keys.trashWatch)
            store.set(false, forKey: SentinelIdentity.Keys.statusTrashReadable)
            return AppModel(engine: DemoCleanerEngine(options: o), settings: AppSettings(defaults: store),
                            sentinel: InMemorySentinelService(registration: .enabled))
        }
        #expect(model(fullDiskAccess: .denied).sentinelNeedsFullDiskAccess)
        #expect(!model(fullDiskAccess: .granted).sentinelNeedsFullDiskAccess)

        // 휴지통 감시를 끄면 안내하지 않는다
        let off = model(fullDiskAccess: .denied)
        off.setTrashWatch(false)
        #expect(!off.sentinelNeedsFullDiskAccess)
    }

    // MARK: 링크 (com.dallisoft.appcleaner://)

    @Test func inspectLinkOpensTrashedApp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sentinel-\(UUID().uuidString)/.Trash/Gone.app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        model.select(.history)
        #expect(model.handleOpen([SentinelLink.inspect(path: dir.path).url]))
        #expect(model.route == .apps)
        let inspector = try #require(model.inspector)
        #expect(inspector.appURL.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(inspector.isInTrash)
    }

    @Test func inspectLinkFallsBackToOrphansWhenTrashWasEmptied() {
        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        model.open(.inspect(path: "/nonexistent-\(UUID().uuidString)/.Trash/Gone.app"))
        #expect(model.route == .orphans)
        #expect(model.inspector == nil)
        #expect(model.orphans.isScanning || model.orphans.hasScanned)
    }

    @Test func orphansAndSettingsLinks() {
        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        #expect(model.handleOpen([URL(string: "com.dallisoft.appcleaner://orphans")!]))
        #expect(model.route == .orphans)
        #expect(model.orphans.isScanning || model.orphans.hasScanned)
        #expect(model.handleOpen([SentinelLink.settings.url]))
        #expect(model.route == .settings)
        // 모르는 링크·앱이 아닌 파일은 무시
        #expect(!model.handleOpen([URL(string: "com.dallisoft.appcleaner://remove")!]))
        #expect(!model.handleOpen([URL(filePath: "/tmp/readme.txt")]))
        // 기존 드롭 경로는 그대로
        #expect(model.handleOpen([slackURL]))
        #expect(model.inspector?.appURL == slackURL)
        #expect(!(model.inspector?.isInTrash ?? true))
    }
}
