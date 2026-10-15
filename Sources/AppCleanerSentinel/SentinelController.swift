import AppKit
import CleanerCore
import Foundation

/// Sentinel 본체: 설정 읽기, 메뉴 막대 메뉴, 휴지통 감시, 정기 스캔, 본 앱으로 넘기기 (ui-ux.md S10)
@MainActor
final class SentinelController: NSObject, NSApplicationDelegate {
    static let recentLimit = 5

    private let options: SentinelOptions
    /// 본 앱의 설정 도메인 (`com.dallisoft.AppCleaner`)
    private let defaults: UserDefaults
    private let trashURL: URL
    private let notifier: SentinelNotifier
    private let scanner = PeriodicScanRunner()
    private var monitor: TrashMonitor?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    private var prefs = SentinelPreferences()
    private var snapshot = TrashSnapshot()
    /// 기준 목록을 한 번이라도 읽었는지 — 읽지 못하다가(권한 없음) 처음 읽힌 목록의 기존 앱은 알리지 않는다
    private var hasBaseline = false
    private var removals = RecentRemovals()
    private var recent: [TrashedApp] = []
    private var trashReadable: Bool?
    private var notificationState: SentinelNotificationState?
    private var observers: [NSObjectProtocol] = []

    init(options: SentinelOptions) {
        self.options = options
        defaults = UserDefaults(suiteName: SentinelIdentity.mainBundleID) ?? .standard
        trashURL = options.trashURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        notifier = SentinelNotifier(logOnly: options.logOnly)
        super.init()
        notifier.onOpen = { [weak self] link in self?.open(link) }
    }

    private var watchesTrash: Bool { prefs.trashWatch || options.watchTrash }
    private var isNeeded: Bool { prefs.needsSentinel || options.watchTrash || options.scanNow }

    // MARK: 시작

    func applicationDidFinishLaunching(_ notification: Notification) {
        reloadPreferences()
        // 설정이 모두 꺼졌는데 로그인 항목이 남아 실행된 경우
        guard isNeeded else {
            sentinelLog("휴지통 감시·정기 스캔이 모두 꺼져 있어 종료합니다")
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        observeSignals()
        apply()
        Task {
            notificationState = await notifier.setUp(request: true)
            if let state = notificationState { store(state.rawValue, SentinelIdentity.Keys.statusNotifications) }
            rebuildMenu()
        }
        if options.scanNow { Task { await runScan() } }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        scanner.stop()
    }

    /// 상태 기록 (S7 표시용). `--log-only`(개발·측정)에서는 본 앱 설정을 건드리지 않는다
    private func store(_ value: Any, _ key: String) {
        guard !options.logOnly else { return }
        defaults.set(value, forKey: key)
    }

    private func reloadPreferences() {
        CFPreferencesAppSynchronize(SentinelIdentity.mainBundleID as CFString)
        prefs = SentinelPreferences(read: { defaults.object(forKey: $0) })
    }

    /// 본 앱 설정 변경(분산 알림)과 App Cleaner의 앱 제거 시작 신호
    private func observeSignals() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: SentinelSignal.settingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        })
        observers.append(center.addObserver(forName: SentinelSignal.appRemovalStarted, object: nil, queue: .main) { [weak self] note in
            let bids = note.userInfo?[SentinelSignal.bundleIDsKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.removals.record(bids, at: Date()) }
        })
    }

    private func settingsChanged() {
        reloadPreferences()
        guard isNeeded else {
            NSApp.terminate(nil)
            return
        }
        apply()
    }

    /// 설정에 맞춰 휴지통 감시·정기 스캔을 켜고 끈다
    private func apply() {
        if watchesTrash {
            if monitor == nil {
                hasBaseline = false
                readTrash(notify: false)
                let m = TrashMonitor(directory: trashURL) { [weak self] in self?.readTrash(notify: true) }
                if !m.start() { sentinelLog("휴지통 감시를 시작하지 못했습니다: \(trashURL.path)") }
                monitor = m
            }
        } else {
            monitor?.stop()
            monitor = nil
            recent = []
        }
        if prefs.periodicScan != .off {
            scanner.start { [weak self] in await self?.tick() }
        } else {
            scanner.stop()
        }
        rebuildMenu()
    }

    // MARK: 휴지통

    /// 휴지통 목록을 다시 읽어 새로 들어온 앱을 알린다
    private func readTrash(notify: Bool) {
        do {
            let current = try TrashSnapshot.read(trash: trashURL)
            let arrivals = current.arrivals(since: snapshot)
            snapshot = current
            let isFirst = !hasBaseline
            hasBaseline = true
            setTrashReadable(true)
            guard notify, !isFirst else { return }
            for app in TrashedApp.notifiable(arrivals, removals: removals, now: Date()) {
                sentinelLog("휴지통에 들어온 앱: \(app.name) (\(app.bundleID ?? "-"))")
                recent.removeAll { $0.url == app.url }
                recent.insert(app, at: 0)
                if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
                notifier.notifyTrashed(app)
            }
            rebuildMenu()
        } catch {
            // 전체 디스크 접근 권한이 없으면 휴지통을 읽지 못한다
            setTrashReadable(false)
        }
    }

    private func setTrashReadable(_ readable: Bool) {
        guard trashReadable != readable else { return }
        trashReadable = readable
        store(readable, SentinelIdentity.Keys.statusTrashReadable)
        if !readable { sentinelLog("휴지통을 읽을 수 없습니다: \(trashURL.path)") }
        rebuildMenu()
    }

    // MARK: 정기 스캔

    private var schedule: PeriodicScanSchedule { PeriodicScanSchedule(interval: prefs.periodicScan) }

    private func tick() async {
        reloadPreferences()
        guard schedule.isDue(lastScan: prefs.lastScan, lastAttempt: prefs.lastAttempt, now: Date()) else { return }
        await runScan()
    }

    private func runScan() async {
        guard let cli = PeriodicScanRunner.locateCLI(mainApp: mainAppURL) else {
            sentinelLog("appcleaner CLI를 찾지 못했습니다")
            return
        }
        let started = Date()
        store(started, SentinelIdentity.Keys.statusLastAttempt)
        rebuildMenu()
        do {
            guard let report = try await scanner.scan(cli: cli) else { return }
            store(started, SentinelIdentity.Keys.statusLastScan)
            let keep = KeepListStore(paths: .live()).entries()
            let summary = OrphanAlertSummary.evaluate(report, keepList: keep, language: sentinelLanguage)
            sentinelLog("정기 스캔: 그룹 \(report.groups.count)개, 알림 \(summary.map { "높음 \($0.itemCount)개" } ?? "없음")")
            if let summary { notifier.notifyOrphans(summary) }
        } catch {
            sentinelLog("정기 스캔 실패: \(error)")
        }
        reloadPreferences()
        rebuildMenu()
    }

    // MARK: 본 앱으로 넘기기

    /// 이 Sentinel을 담은 App Cleaner.app (없으면 설치된 App Cleaner)
    private var mainAppURL: URL? {
        SentinelIdentity.containingApp(ofHelper: Bundle.main.bundleURL)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: SentinelIdentity.mainBundleID)
    }

    /// 링크를 이 Sentinel을 담은 본 앱으로 연다 (다른 사본이 대신 열리지 않도록 앱을 지정).
    /// 휴지통을 이미 비워 앱이 없으면 본 앱이 S5로 연다.
    func open(_ link: SentinelLink) {
        guard let app = mainAppURL else {
            sentinelLog("App Cleaner를 찾지 못했습니다: \(link.url.absoluteString)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([link.url], withApplicationAt: app, configuration: config) { _, error in
            if let error { sentinelLog("App Cleaner를 열지 못했습니다: \(error.localizedDescription)") }
        }
    }

    // MARK: 메뉴 막대

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "trash.circle", accessibilityDescription: "App Cleaner Sentinel")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "App Cleaner Sentinel"
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu()
    }

    /// 메뉴 항목을 지금 상태로 다시 채운다 (열려 있는 메뉴 객체는 그대로 둔다)
    private func rebuildMenu() {
        guard statusItem != nil else { return }
        menu.removeAllItems()
        menu.addItem(label("App Cleaner Sentinel"))
        menu.addItem(.separator())

        if !watchesTrash {
            menu.addItem(label(S("휴지통 감시 꺼짐")))
        } else if trashReadable == false {
            menu.addItem(action(S("휴지통을 읽을 수 없음 — 전체 디스크 접근 필요…")) {
                NSWorkspace.shared.open(SentinelSettingsURL.fullDiskAccess)
            })
        } else {
            menu.addItem(label(S("휴지통 감시 중")))
        }
        menu.addItem(label(scanStatus))
        if notificationState == .denied {
            menu.addItem(action(S("알림이 꺼져 있음 — 알림 설정 열기…")) {
                NSWorkspace.shared.open(SentinelSettingsURL.notifications)
            })
        }

        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(label(S("최근 휴지통으로 간 앱")))
            for app in recent {
                menu.addItem(action(S("%@ 잔여물 정리…", app.name)) { [weak self] in self?.open(.inspect(path: app.url.path)) })
            }
        }

        menu.addItem(.separator())
        menu.addItem(action(S("고아 잔여물 스캔…")) { [weak self] in self?.open(.orphans) })
        menu.addItem(action(S("App Cleaner 열기")) { [weak self] in
            guard let app = self?.mainAppURL else { return }
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        })
        menu.addItem(action(S("설정…")) { [weak self] in self?.open(.settings) })
        menu.addItem(.separator())
        let quit = action(S("Sentinel 종료")) { NSApp.terminate(nil) }
        quit.toolTip = S("다음 로그인 때 다시 실행됩니다. 완전히 끄려면 App Cleaner 설정에서 끄세요.")
        menu.addItem(quit)
    }

    private var scanStatus: String {
        switch prefs.periodicScan {
        case .off:
            return S("정기 스캔 꺼짐")
        case .weekly, .monthly:
            if scanner.isScanning { return S("정기 스캔 중…") }
            let interval = prefs.periodicScan == .weekly ? S("매주") : S("매달")
            guard let due = schedule.nextDue(lastScan: prefs.lastScan, lastAttempt: prefs.lastAttempt, now: Date()),
                  due > Date() else { return S("정기 스캔: %@ · 곧 실행", interval) }
            return S("정기 스캔: %@ · 다음 %@", interval, SentinelFormat.day(due))
        }
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction(handler)
        item.target = target
        item.representedObject = target  // 메뉴 항목이 대상을 붙잡고 있도록
        return item
    }
}

extension SentinelController: NSMenuDelegate {
    /// 메뉴를 열 때: 휴지통을 읽지 못했으면 다시 시도(전체 디스크 접근을 허용하고 돌아온 경우), 다음 예정일 갱신
    func menuNeedsUpdate(_ menu: NSMenu) {
        if watchesTrash && trashReadable == false { readTrash(notify: false) }
        rebuildMenu()
    }
}

/// 메뉴 항목 → 클로저
@MainActor
private final class MenuAction: NSObject {
    let handler: @MainActor () -> Void
    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
