import Foundation

/// 권한 상태 (ui-ux.md S7, S8, 사이드바 권한 카드)
public struct PermissionStatus: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case granted, denied, unknown }
    public var fullDiskAccess: State
    public var appManagement: State

    public init(fullDiskAccess: State, appManagement: State = .unknown) {
        self.fullDiskAccess = fullDiskAccess
        self.appManagement = appManagement
    }
}

public struct RuleDataInfo: Codable, Sendable, Hashable {
    public var version: String
    public var updatedAt: Date?
    public var signatureVerified: Bool
    public var caskCount: Int

    public init(version: String, updatedAt: Date?, signatureVerified: Bool, caskCount: Int) {
        self.version = version
        self.updatedAt = updatedAt
        self.signatureVerified = signatureVerified
        self.caskCount = caskCount
    }
}

/// GUI·CLI가 사용하는 엔진 진입점. GUI는 이 프로토콜에만 의존한다.
public protocol CleanerEngine: Sendable {
    // S1
    func installedApps() async -> [InstalledApp]
    func size(of url: URL) async -> Int64?

    // S2
    func scan(appAt url: URL) async throws -> ScanReport

    // S3
    /// `selectedPaths`: 사용자가 최종 선택한 후보 경로 (하위 항목 포함)
    func makePlan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan
    func makePlan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan

    // 진행 중 → S4
    func execute(
        _ plan: CleanupPlan,
        progress: @escaping @Sendable (CleanupProgress) -> Void,
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> CleanupResult

    // S5
    func scanOrphans(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport
    func keepList() -> [KeepEntry]
    func addToKeepList(_ entry: KeepEntry)
    func removeFromKeepList(id: String)

    // S6
    func sessions() async -> [JournalSession]
    func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult
    /// 되돌리기 확인 전에 충돌·복원 불가 항목을 미리 조회 (`restore`와 같은 판정). 세션이 없으면 nil.
    func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview?
    /// 관리자 권한 항목을 옮겨 두는 보류 폴더 위치 ("Finder에서 보기")
    var holdingFolderURL: URL { get }
    func holdingUsage(retentionDays: Int) async -> HoldingUsage
    func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure]
    func exportSession(id: UUID) async -> Data?

    // S7 · S8
    func permissions() -> PermissionStatus
    func ruleDataInfo() -> RuleDataInfo
}
