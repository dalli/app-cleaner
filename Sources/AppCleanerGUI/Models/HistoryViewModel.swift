import CleanerCore
import Foundation
import Observation

/// S6 삭제 기록
@MainActor
@Observable
final class HistoryViewModel {
    /// 되돌리기 확인 시트
    struct RestoreRequest: Identifiable, Equatable {
        let id = UUID()
        var session: JournalSession
        var items: [JournalItem]
        /// 원래 위치에 같은 이름이 이미 있는 항목
        var conflicts: Set<String>
        /// 항목별 충돌 처리 (기본: 이름 바꿔 복원)
        var policies: [String: RestoreOptions.ConflictPolicy]
        var reregisterServices = true

        var hasStoppedServices: Bool { !session.stoppedServices.isEmpty }
    }

    @ObservationIgnored private let engine: any CleanerEngine
    /// 원래 위치에 같은 이름이 있는지 (읽기 전용 확인)
    @ObservationIgnored private let pathExists: @Sendable (String) -> Bool

    private(set) var sessions: [JournalSession] = []
    private(set) var usage: HoldingUsage?
    private(set) var isLoading = false
    private(set) var lastRestore: RestoreResult?
    private(set) var isRestoring = false

    var selectedSessionID: UUID? {
        didSet { if selectedSessionID != oldValue { checkedItems = [] } }
    }
    var checkedItems: Set<String> = []
    var restoreRequest: RestoreRequest?
    var confirmPurge = false

    init(engine: any CleanerEngine, pathExists: @escaping @Sendable (String) -> Bool) {
        self.engine = engine
        self.pathExists = pathExists
    }

    /// 화면을 열 때마다 호출: 엔진이 이동 위치 존재를 확인해 상태를 갱신한다
    func load(retentionDays: Int) async {
        isLoading = true
        sessions = await engine.sessions()
        usage = await engine.holdingUsage(retentionDays: retentionDays)
        isLoading = false
        if selectedSessionID == nil || !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions.first?.id
        }
    }

    var selectedSession: JournalSession? { sessions.first { $0.id == selectedSessionID } }

    // MARK: 항목 상태

    func isRestorable(_ item: JournalItem, in session: JournalSession) -> Bool {
        item.restoredAt == nil && !session.missingItems.contains(item.originalPath)
    }

    func restorableItems(of session: JournalSession) -> [JournalItem] {
        session.items.filter { isRestorable($0, in: session) }
    }

    /// 표의 "현재 위치"
    func currentLocation(_ item: JournalItem, in session: JournalSession) -> String {
        if item.restoredAt != nil { return L("원래 위치로 복원됨") }
        if session.missingItems.contains(item.originalPath) {
            return item.destination == .trash ? L("휴지통에서 비워짐 — 복원 불가") : L("보류 폴더에서 삭제됨 — 복원 불가")
        }
        return item.destination == .trash ? L("휴지통") : L("보류 폴더")
    }

    func toggleChecked(_ item: JournalItem) {
        if checkedItems.contains(item.originalPath) { checkedItems.remove(item.originalPath) }
        else { checkedItems.insert(item.originalPath) }
    }

    // MARK: 되돌리기

    func requestRestoreAll() {
        guard let s = selectedSession else { return }
        prepareRestore(session: s, items: restorableItems(of: s))
    }

    func requestRestoreChecked() {
        guard let s = selectedSession else { return }
        prepareRestore(session: s, items: restorableItems(of: s).filter { checkedItems.contains($0.originalPath) })
    }

    /// ⌘Z: 가장 최근에 되돌릴 수 있는 작업
    func requestUndoLatest() {
        guard let s = sessions.first(where: { !restorableItems(of: $0).isEmpty }) else { return }
        selectedSessionID = s.id
        prepareRestore(session: s, items: restorableItems(of: s))
    }

    func prepareRestore(session: JournalSession, items: [JournalItem]) {
        guard !items.isEmpty else { return }
        let conflicts = Set(items.map(\.originalPath).filter(pathExists))
        let policies = Dictionary(uniqueKeysWithValues: items.map { ($0.originalPath, RestoreOptions.ConflictPolicy.renameRestored) })
        restoreRequest = RestoreRequest(session: session, items: items, conflicts: conflicts, policies: policies)
    }

    /// 항목별 충돌 선택을 지키기 위해 정책별로 나눠 엔진을 호출한다
    func performRestore() async {
        guard let req = restoreRequest else { return }
        restoreRequest = nil
        isRestoring = true
        var total = RestoreResult()
        let grouped = Dictionary(grouping: req.items.map(\.originalPath)) { req.policies[$0] ?? .renameRestored }
        for policy in [RestoreOptions.ConflictPolicy.renameRestored, .skip] {
            guard let paths = grouped[policy], !paths.isEmpty else { continue }
            let r = await engine.restore(
                sessionID: req.session.id,
                itemPaths: Set(paths),
                options: RestoreOptions(conflictPolicy: policy, reregisterServices: req.reregisterServices)
            )
            total.restored += r.restored
            total.skipped += r.skipped
            total.missing += r.missing
            total.failures += r.failures
        }
        lastRestore = total
        isRestoring = false
        checkedItems = []
        sessions = await engine.sessions()
    }

    func dismissRestoreResult() { lastRestore = nil }

    // MARK: 보류 폴더

    var expiredSessionIDs: [UUID] { usage?.expiredSessionIDs ?? [] }

    /// 사용자가 추가 확인한 뒤에만 호출한다 (자동 삭제하지 않음)
    func purgeExpired(retentionDays: Int) async -> [CleanupFailure] {
        let ids = expiredSessionIDs
        guard !ids.isEmpty else { return [] }
        let failures = await engine.purgeHolding(sessionIDs: ids)
        await load(retentionDays: retentionDays)
        return failures
    }

    func exportJSON() async -> Data? {
        guard let id = selectedSessionID else { return nil }
        return await engine.exportSession(id: id)
    }

    /// 보류 폴더 위치 (기록에서 찾고, 없으면 기본 위치)
    var holdingFolderPath: String {
        for s in sessions {
            if let item = s.items.first(where: { $0.destination == .holding }) {
                // .../Holding/<sessionID>/<원래 경로> → .../Holding
                if let r = item.movedTo.range(of: "/Holding/") {
                    return String(item.movedTo[..<r.upperBound].dropLast())
                }
            }
        }
        return "/Library/Application Support/App Cleaner/Holding"
    }

    /// 단계 기록 문구
    static func stepText(_ raw: String) -> String {
        if let step = CleanupStep(rawValue: raw) { return step.progressTitle }
        return raw
    }

    static func sessionTitle(_ s: JournalSession) -> String { s.targetName }

    /// "오늘 14:02 · 앱 제거 · 10개 · 3.0 GB"
    static func sessionSubtitle(_ s: JournalSession, now: Date = Date()) -> String {
        var parts = [Fmt.sessionTime(s.startedAt, now: now), s.kind.title, L("%lld개", s.items.count), Fmt.bytes(s.totalSize)]
        if !s.missingItems.isEmpty { parts.append(L("%lld개 복원 불가", s.missingItems.count)) }
        return parts.joined(separator: " · ")
    }
}
