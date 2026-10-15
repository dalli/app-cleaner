import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// Sentinel(휴지통 감시·정기 고아 스캔 알림)의 판단 로직 (ui-ux.md S10)
@Suite struct SentinelTests {
    // MARK: 본 앱 연결 (URL 스킴)

    @Test func linkRoundTrips() throws {
        let paths = ["/Users/me/.Trash/Slack.app", "/Users/me/.Trash/My App 10.26.01.app", "/Users/me/.Trash/한글 & 기호?#.app"]
        for path in paths {
            let link = SentinelLink.inspect(path: path)
            #expect(link.url.scheme == "com.dallisoft.appcleaner")
            #expect(SentinelLink(url: link.url) == link, "\(link.url)")
        }
        #expect(SentinelLink(url: SentinelLink.orphans.url) == .orphans)
        #expect(SentinelLink(url: SentinelLink.settings.url) == .settings)
        #expect(SentinelLink.orphans.url.absoluteString == "com.dallisoft.appcleaner://orphans")
    }

    @Test func linkRejectsOtherInput() throws {
        func parse(_ s: String) -> SentinelLink? { URL(string: s).flatMap(SentinelLink.init(url:)) }
        #expect(parse("appcleaner://orphans") == nil)                                  // 다른 스킴
        #expect(parse("com.dallisoft.appcleaner://remove?path=/Applications/A.app") == nil)  // 알 수 없는 동작
        #expect(parse("com.dallisoft.appcleaner://inspect?path=Slack.app") == nil)     // 상대 경로
        #expect(parse("com.dallisoft.appcleaner://inspect?path=/etc/passwd") == nil)   // .app 아님
        #expect(parse("com.dallisoft.appcleaner://inspect") == nil)
        #expect(SentinelLink(url: URL(fileURLWithPath: "/Applications/Slack.app")) == nil)
        // 경로는 정규화한다
        #expect(parse("com.dallisoft.appcleaner://inspect?path=/Users/me/.Trash/../.Trash/A.app") == .inspect(path: "/Users/me/.Trash/A.app"))
        #expect(parse("COM.DALLISOFT.APPCLEANER://ORPHANS") == .orphans)
    }

    @Test func helperLocationInsideMainApp() {
        let app = URL(fileURLWithPath: "/Applications/App Cleaner.app")
        let helper = SentinelIdentity.helperURL(inApp: app)
        #expect(helper.path == "/Applications/App Cleaner.app/Contents/Library/LoginItems/App Cleaner Sentinel.app")
        #expect(SentinelIdentity.containingApp(ofHelper: helper)?.path == app.path)
        #expect(SentinelIdentity.cliURL(inApp: app).path == "/Applications/App Cleaner.app/Contents/Helpers/appcleaner")
        // 개발 빌드(.build/debug)처럼 구조가 다르면 nil
        #expect(SentinelIdentity.containingApp(ofHelper: URL(fileURLWithPath: "/tmp/.build/debug/AppCleanerSentinel")) == nil)
        #expect(SentinelIdentity.bundleID == "com.dallisoft.AppCleaner.Sentinel")
    }

    // MARK: 설정

    @Test func preferencesReadSharedKeys() {
        typealias K = SentinelIdentity.Keys
        let empty = SentinelPreferences(read: { _ in nil })
        #expect(empty == SentinelPreferences())
        #expect(!empty.needsSentinel)

        let scan = Date(timeIntervalSince1970: 1_000)
        let values: [String: Any] = [K.trashWatch: true, K.periodicScan: "monthly", K.statusLastScan: scan,
                                     K.statusTrashReadable: false, K.statusNotifications: "denied"]
        let p = SentinelPreferences(read: { values[$0] })
        #expect(p.trashWatch && p.periodicScan == .monthly && p.lastScan == scan)
        #expect(p.trashReadable == false && p.notifications == .denied && p.lastAttempt == nil)
        #expect(p.needsSentinel)
        #expect(SentinelPreferences(periodicScan: .weekly).needsSentinel)
        // 알 수 없는 값은 끔
        #expect(SentinelPreferences(read: { $0 == K.periodicScan ? "daily" : nil }).periodicScan == .off)
    }

    // MARK: 휴지통 유입 판단

    @Test func snapshotFindsOnlyNewAppsAtTopLevel() throws {
        let fx = try Fixture()
        let trash = try fx.dir(fx.home(".Trash"))
        try fx.makeApp(name: "Old", bundleID: "com.example.old", in: trash)
        let first = try TrashSnapshot.read(trash: trash)
        #expect(first.apps.count == 1)
        #expect(first.arrivals(since: TrashSnapshot()).count == 1)

        // 새 앱 + 앱이 아닌 항목 + 폴더째 버린 앱 + 앱처럼 보이는 링크
        let new = try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", in: fx.root("Applications"))
        try FileManager.default.moveItem(at: new, to: trash.appendingPathComponent("Slack.app"))
        try fx.file(trash.appendingPathComponent("notes.txt"))
        try fx.makeApp(name: "Nested", bundleID: "com.example.nested", in: trash.appendingPathComponent("Folder"))
        try fx.symlink(trash.appendingPathComponent("Link.app"), to: fx.root("Applications"))
        let second = try TrashSnapshot.read(trash: trash)
        #expect(second.arrivals(since: first).map(\.lastPathComponent) == ["Slack.app"])
        // 같은 변경에 대한 이벤트가 다시 와도 새 앱이 없다
        #expect(try TrashSnapshot.read(trash: trash).arrivals(since: second).isEmpty)

        // 휴지통 안에서 이름만 바꾸면 새로 들어온 것이 아니다 (볼륨·inode가 같음)
        try FileManager.default.moveItem(at: trash.appendingPathComponent("Slack.app"),
                                         to: trash.appendingPathComponent("Slack 10.26.01.app"))
        let renamed = try TrashSnapshot.read(trash: trash)
        #expect(renamed.arrivals(since: second).isEmpty)
        #expect(renamed.apps.values.contains { $0.lastPathComponent == "Slack 10.26.01.app" })

        // 되돌려 놓았다가 다시 버리면 다시 알린다
        let back = fx.root("Applications/Slack.app")
        try FileManager.default.moveItem(at: trash.appendingPathComponent("Slack 10.26.01.app"), to: back)
        let restored = try TrashSnapshot.read(trash: trash)
        #expect(restored.arrivals(since: renamed).isEmpty)
        try FileManager.default.moveItem(at: back, to: trash.appendingPathComponent("Slack.app"))
        #expect(try TrashSnapshot.read(trash: trash).arrivals(since: restored).map(\.lastPathComponent) == ["Slack.app"])
    }

    @Test func unreadableTrashThrows() throws {
        let fx = try Fixture()
        #expect(throws: (any Error).self) { try TrashSnapshot.read(trash: fx.home(".Trash-missing")) }
    }

    @Test func trashedAppIdentityComesFromInfoPlist() throws {
        let fx = try Fixture()
        let trash = try fx.dir(fx.home(".Trash"))
        // 휴지통이 붙인 이름("Slack 10.26.01")이 아니라 원래 이름
        let app = try fx.makeApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap", in: trash)
        let renamed = trash.appendingPathComponent("Slack 10.26.01.app")
        try FileManager.default.moveItem(at: app, to: renamed)
        let t = TrashedApp.read(at: renamed)
        #expect(t.bundleID == "com.tinyspeck.slackmacgap" && t.name == "Slack" && t.url == renamed)

        let display = try fx.makeApp(name: "zoom.us", bundleID: "us.zoom.xos", in: trash, displayName: "Zoom")
        #expect(TrashedApp.read(at: display).name == "Zoom")

        // Info.plist가 없으면 파일 이름, 번들 ID 없음
        let bare = try fx.dir(trash.appendingPathComponent("Broken.app"))
        let b = TrashedApp.read(at: bare)
        #expect(b.name == "Broken" && b.bundleID == nil)
    }

    @Test func skipsAppleSelfAndOwnRemovals() {
        let now = Date()
        var removals = RecentRemovals()
        func app(_ bid: String?) -> TrashedApp { TrashedApp(url: URL(fileURLWithPath: "/u/.Trash/X.app"), bundleID: bid, name: "X") }
        #expect(app("com.example.widget").skipReason(removals: removals, now: now) == nil)
        #expect(app(nil).skipReason(removals: removals, now: now) == .noBundleID)
        #expect(app("bad/../id").skipReason(removals: removals, now: now) == .noBundleID)
        #expect(app("com.apple.Safari").skipReason(removals: removals, now: now) == .appleApp)
        #expect(app("COM.APPLE.iMovieApp").skipReason(removals: removals, now: now) == .appleApp)
        #expect(app("com.dallisoft.AppCleaner").skipReason(removals: removals, now: now) == .selfApp)
        #expect(app("com.dallisoft.AppCleaner.Sentinel").skipReason(removals: removals, now: now) == .selfApp)
        #expect(app("com.dallisoft.AppCleanerX").skipReason(removals: removals, now: now) == nil)

        // App Cleaner가 직접 제거한 앱은 일정 시간 동안 알리지 않는다
        removals.record(["com.example.Widget"], at: now)
        #expect(app("com.example.widget").skipReason(removals: removals, now: now.addingTimeInterval(5)) == .removedByAppCleaner)
        #expect(app("com.example.widget").skipReason(removals: removals, now: now.addingTimeInterval(RecentRemovals.defaultLifetime + 1)) == nil)
        removals.prune(now: now.addingTimeInterval(RecentRemovals.defaultLifetime + 1))
        #expect(!removals.contains("com.example.widget", now: now))
    }

    @Test func notifiableFiltersArrivals() {
        let urls = ["A", "B", "C"].map { URL(fileURLWithPath: "/u/.Trash/\($0).app") }
        let ids = ["A": "com.example.a", "B": "com.apple.b", "C": "com.example.c"]
        var removals = RecentRemovals()
        removals.record(["com.example.c"], at: Date())
        let out = TrashedApp.notifiable(urls, removals: removals, now: Date()) { url in
            let n = url.deletingPathExtension().lastPathComponent
            return TrashedApp(url: url, bundleID: ids[n], name: n)
        }
        #expect(out.map(\.name) == ["A"])
    }

    @Test func trashLocation() {
        #expect(TrashedApp.isInTrash(URL(fileURLWithPath: "/Users/me/.Trash/Slack.app")))
        #expect(TrashedApp.isInTrash(URL(fileURLWithPath: "/Volumes/Ext/.Trashes/501/Slack.app")))
        #expect(!TrashedApp.isInTrash(URL(fileURLWithPath: "/Applications/Slack.app")))
        #expect(!TrashedApp.isInTrash(URL(fileURLWithPath: "/Users/me/Trash/Slack.app")))
    }

    /// 휴지통에 있는 앱을 검사하면 본체는 후보에서 빼고 잔여물만 찾는다 (본체를 다시 옮기지 않도록)
    @Test func scanningTrashedAppSkipsAppBundle() async throws {
        let fx = try Fixture()
        let bid = "com.example.trashed"
        let app = try fx.makeApp(name: "Trashed", bundleID: bid, in: try fx.dir(fx.home(".Trash")))
        let prefs = try fx.file(fx.home("Library/Preferences/\(bid).plist"))
        let caches = try fx.dir(fx.home("Library/Caches/\(bid)"))
        let report = try await ScanKit.scanner(fx).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        #expect(!report.candidates.contains { $0.category == .appBundle })
        #expect(report.candidates.item(app) == nil)
        #expect(report.candidates.item(prefs) != nil && report.candidates.item(caches) != nil)
        #expect(report.identity.bundleID == bid)

        // 휴지통 밖이면 본체도 후보
        let installed = try fx.makeApp(name: "Installed", bundleID: "com.example.installed")
        let r2 = try await ScanKit.scanner(fx).scan(appAt: installed, inventory: InventorySnapshot(apps: []))
        #expect(r2.candidates.contains { $0.category == .appBundle })
    }

    @Test func appRemovalSignalOnlyForAppBundleMoves() {
        let app = Candidate(url: URL(fileURLWithPath: "/Applications/A.app"), category: .appBundle, confidence: .high, isSelected: true)
        let prefs = Candidate(url: URL(fileURLWithPath: "/u/Library/Preferences/com.example.a.plist"), category: .preferences,
                              confidence: .high, isSelected: true)
        let remove = CleanupPlan(kind: .appRemoval, targetName: "A", targetBundleID: "com.example.a", items: [app, prefs], ruleDataVersion: "t")
        #expect(SentinelSignal.removedBundleIDs(in: remove) == ["com.example.a"])
        // 휴지통의 앱(본체 없음)·고아 정리는 신호를 보내지 않는다
        let leftovers = CleanupPlan(kind: .appRemoval, targetName: "A", targetBundleID: "com.example.a", items: [prefs], ruleDataVersion: "t")
        #expect(SentinelSignal.removedBundleIDs(in: leftovers).isEmpty)
        let orphans = CleanupPlan(kind: .orphanCleanup, targetName: "고아", items: [app], ruleDataVersion: "t")
        #expect(SentinelSignal.removedBundleIDs(in: orphans).isEmpty)
    }

    // MARK: 정기 스캔 일정

    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func scheduleComputesNextDue() {
        let now = Self.date("2026-10-15T12:00:00Z")
        let off = PeriodicScanSchedule(interval: .off, calendar: Self.utc)
        #expect(off.nextDue(lastScan: nil, lastAttempt: nil, now: now) == nil)
        #expect(!off.isDue(lastScan: nil, lastAttempt: nil, now: now))

        let weekly = PeriodicScanSchedule(interval: .weekly, calendar: Self.utc)
        // 한 번도 스캔하지 않았으면 바로
        #expect(weekly.isDue(lastScan: nil, lastAttempt: nil, now: now))
        let threeDaysAgo = Self.date("2026-10-12T12:00:00Z")
        #expect(weekly.nextDue(lastScan: threeDaysAgo, lastAttempt: threeDaysAgo, now: now) == Self.date("2026-10-19T12:00:00Z"))
        #expect(!weekly.isDue(lastScan: threeDaysAgo, lastAttempt: threeDaysAgo, now: now))
        #expect(weekly.isDue(lastScan: Self.date("2026-10-08T12:00:00Z"), lastAttempt: nil, now: now))

        // 매달은 달력 기준 (1월 31일 → 2월 말일)
        let monthly = PeriodicScanSchedule(interval: .monthly, calendar: Self.utc)
        #expect(monthly.nextDue(lastScan: Self.date("2027-01-31T09:00:00Z"), lastAttempt: nil, now: Self.date("2027-02-01T00:00:00Z"))
                == Self.date("2027-02-28T09:00:00Z"))
        #expect(monthly.isDue(lastScan: Self.date("2026-09-15T11:00:00Z"), lastAttempt: nil, now: now))
        #expect(!monthly.isDue(lastScan: Self.date("2026-09-15T13:00:00Z"), lastAttempt: nil, now: now))
    }

    @Test func failedAttemptWaitsBeforeRetry() {
        let now = Self.date("2026-10-15T12:00:00Z")
        let weekly = PeriodicScanSchedule(interval: .weekly, calendar: Self.utc)
        let longAgo = Self.date("2026-09-01T00:00:00Z")
        // 실패(시도 > 성공) 직후에는 6시간 기다린다
        let failed = now.addingTimeInterval(-3600)
        #expect(weekly.nextDue(lastScan: longAgo, lastAttempt: failed, now: now) == failed.addingTimeInterval(PeriodicScanSchedule.retryDelay))
        #expect(!weekly.isDue(lastScan: longAgo, lastAttempt: failed, now: now))
        #expect(weekly.isDue(lastScan: longAgo, lastAttempt: now.addingTimeInterval(-7 * 3600), now: now))
        #expect(!weekly.isDue(lastScan: nil, lastAttempt: failed, now: now))
        // 성공보다 오래된 시도는 무시
        #expect(weekly.isDue(lastScan: longAgo, lastAttempt: longAgo.addingTimeInterval(-60), now: now))
        // 시계를 되돌려 기록이 미래에 있으면 없는 것으로 본다
        #expect(weekly.isDue(lastScan: now.addingTimeInterval(86_400), lastAttempt: nil, now: now))
    }

    // MARK: 정기 스캔 알림 판단

    static func orphanItem(_ path: String, _ confidence: Confidence, size: Int64? = 100,
                           protection: ProtectionReason? = nil, nature: DataNature? = nil) -> Candidate {
        Candidate(url: URL(fileURLWithPath: path), category: .preferences, confidence: confidence, nature: nature,
                  protection: protection, size: size)
    }

    static func report(_ groups: [OrphanGroup]) -> OrphanScanReport {
        OrphanScanReport(groups: groups, spotlight: .unknown, inventoryAppCount: 10, duration: 1, ruleDataVersion: "t")
    }

    @Test func alertOnlyWhenHighItemsRemain() {
        let medium = OrphanGroup(id: "bid:com.m", displayName: "M", nameIsGuess: false,
                                 items: [Self.orphanItem("/u/L/P/com.m.plist", .medium), Self.orphanItem("/u/L/C/com.m", .low)],
                                 confidence: .medium)
        #expect(OrphanAlertSummary.evaluate(Self.report([medium]), keepList: []) == nil)
        #expect(OrphanAlertSummary.evaluate(Self.report([]), keepList: []) == nil)

        let big = OrphanGroup(id: "bid:com.big", displayName: "Big", nameIsGuess: false, items: [
            Self.orphanItem("/u/L/C/com.big", .high, size: 3_000),
            Self.orphanItem("/u/L/P/com.big.plist", .high, size: nil),
            Self.orphanItem("/u/L/S/Big", .medium, size: 9_000),           // 보통은 세지 않는다
        ], confidence: .high)
        let small = OrphanGroup(id: "bid:com.small", displayName: "Small", nameIsGuess: false, items: [
            Self.orphanItem("/u/L/C/com.small", .high, size: 10),
        ], confidence: .high)
        let protected = OrphanGroup(id: "bid:com.p", displayName: "P", nameIsGuess: false, items: [
            Self.orphanItem("/u/L/M/iCloud~com~p", .high, protection: .protectedPath),
            Self.orphanItem("/u/L/M/synced", .high, nature: .synced),
        ], confidence: .high)
        let summary = OrphanAlertSummary.evaluate(Self.report([small, medium, protected, big]), keepList: [], language: .ko)
        #expect(summary == OrphanAlertSummary(groupCount: 2, itemCount: 3, totalSize: 3_010, groupNames: ["Big", "Small"]))
    }

    @Test func alertRespectsKeepList() {
        let a = OrphanGroup(id: "bid:com.a", displayName: "A", nameIsGuess: false,
                            items: [Self.orphanItem("/u/L/C/com.a", .high)], confidence: .high)
        let b = OrphanGroup(id: "bid:com.b", displayName: "B", nameIsGuess: false,
                            items: [Self.orphanItem("/u/L/C/com.b", .high), Self.orphanItem("/u/L/P/com.b.plist", .medium)],
                            confidence: .high)
        let keepGroup = KeepEntry(kind: .group, key: "bid:com.a", displayName: "A")
        let keepItem = KeepEntry(kind: .item, key: "/u/L/C/com.b", displayName: "com.b")
        #expect(OrphanAlertSummary.evaluate(Self.report([a, b]), keepList: [keepGroup])?.groupNames == ["B"])
        // 남은 것이 보통뿐이면 알리지 않는다
        #expect(OrphanAlertSummary.evaluate(Self.report([a, b]), keepList: [keepGroup, keepItem]) == nil)
    }

    // MARK: 문구

    @Test func objectParticleOnlyInKorean() {
        #expect(SentinelStrings.withObjectParticle("Slack", language: .ko) == "Slack을")
        #expect(SentinelStrings.withObjectParticle("Zoom", language: .ko) == "Zoom을")
        #expect(SentinelStrings.withObjectParticle("메모", language: .ko) == "메모를")
        #expect(SentinelStrings.withObjectParticle("카카오톡", language: .ko) == "카카오톡을")
        #expect(SentinelStrings.withObjectParticle("Slack", language: .en) == "Slack")
        #expect(SentinelStrings.withObjectParticle("Slack", language: .ja) == "Slack")
    }

    @Test func notificationTextsRenderPerLanguage() {
        func text(_ key: String, _ language: AppLanguage, _ args: any CVarArg...) -> String {
            SentinelStrings.format(key, args, language: language)
        }
        #expect(text("%@ 휴지통으로 옮겼습니다", .ko, "Slack을") == "Slack을 휴지통으로 옮겼습니다")
        #expect(text("%@ 휴지통으로 옮겼습니다", .en, "Slack") == "Slack was moved to the Trash")
        #expect(text("%@ 휴지통으로 옮겼습니다", .ja, "Slack") == "Slack をゴミ箱に入れました")
        let key = "삭제된 앱 %lld개의 잔여물 %@를 찾았습니다 (신뢰도 높음)."
        #expect(text(key, .en, 1, "1.2 GB") == "Found 1.2 GB of leftovers from 1 deleted app (high confidence).")
        #expect(text(key, .en, 3, "1.2 GB") == "Found 1.2 GB of leftovers from 3 deleted apps (high confidence).")
        #expect(text(key, .ko, 3, "1.2 GB") == "삭제된 앱 3개의 잔여물 1.2 GB를 찾았습니다 (신뢰도 높음).")
        #expect(text(key, .ja, 3, "1.2 GB").hasPrefix("削除された App 3 個"))
        #expect(text("정기 스캔: %@ · 다음 %@", .en, "Monthly", "Nov 14") == "Periodic scan: Monthly · next Nov 14")
    }
}
