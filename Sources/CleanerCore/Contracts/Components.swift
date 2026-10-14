import Foundation

// 엔진 구성 요소 계약. 각 구현은 별도 모듈 폴더에 두고 `CleanerEngine` 구현이 조립한다 (plan.md 8.2).
// 모든 구현은 `SystemPaths`와 `CommandRunning`을 주입받아 픽스처에서 동작해야 한다.

// MARK: 앱 제거 — 탐지

/// IdentityResolver: Info.plist, 코드서명, entitlements, 내장 번들 (plan.md 4.1)
public protocol IdentityResolving: Sendable {
    func resolve(appAt url: URL) throws -> AppIdentity
}

/// 정보원 1개 (Receipt, HomebrewZap, PathRules, LaunchPlist — plan.md 4.2)
public protocol CandidateSource: Sendable {
    var sourceName: String { get }
    func candidates(for identity: AppIdentity) throws -> [Candidate]
}

/// 신뢰도 · 공유 · 데이터 성격 → 기본 선택 결정 (plan.md 4.3)
/// `inventory`가 nil이면 공유 판정 대상(Group Container·벤더 폴더·외부 Launch 실행 파일)을 미선택 처리한다 (plan.md 8.2).
public protocol SelectionPolicing: Sendable {
    func evaluate(_ candidates: [Candidate], for identity: AppIdentity, inventory: InventorySnapshot?) -> [Candidate]
}

/// 앱 1개 검사 (정보원 → 병합 → SafetyGuard → SelectionPolicy → 크기)
public protocol AppScanning: Sendable {
    func scan(appAt url: URL, inventory: InventorySnapshot?) async throws -> ScanReport
}

// MARK: 안전

public enum SafetyVerdict: Sendable, Hashable {
    /// 허용. `resolved`는 심볼릭 링크를 해석한 실제 경로
    case allowed(resolved: URL)
    /// 차단. 문구는 진단용 보호 판정 (`EngineText.Key.isProtectionDetail`)
    case blocked(ProtectionReason, EngineText)

    public var isAllowed: Bool { if case .allowed = self { return true }; return false }
}

/// SafetyGuard: 보호 목록, symlink 해석 (plan.md 5.1). 스캔 시와 이동 직전에 두 번 호출된다.
public protocol SafetyChecking: Sendable {
    func verdict(for url: URL, bundleID: String?) -> SafetyVerdict
}

// MARK: 정리 실행·기록

/// Preflight → Mover → Journal을 묶어 계획을 실행한다 (plan.md 4.4, 6장)
public protocol CleanupExecuting: Sendable {
    func execute(
        _ plan: CleanupPlan,
        progress: @escaping @Sendable (CleanupProgress) -> Void,
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> CleanupResult
}

/// Journal: 삭제 기록 및 복원 (plan.md 6.2)
public protocol JournalStoring: Sendable {
    /// 이동 위치 존재 여부를 확인해 status를 갱신한 목록 (최신순)
    func sessions() async -> [JournalSession]
    func session(id: UUID) async -> JournalSession?
    /// `itemPaths`가 nil이면 전체 복원
    func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult
    /// 복원하지 않고 항목별 예상 결과(충돌·복원 불가)만 조회. 세션이 없으면 nil.
    func restorePreview(sessionID: UUID, itemPaths: Set<String>?) async -> RestorePreview?
    func holdingUsage(retentionDays: Int) async -> HoldingUsage
    /// 보류 기간이 지난 세션의 보류 폴더 항목을 영구 삭제 (사용자 확인 후 호출)
    func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure]
    func exportJSON(sessionID: UUID) async -> Data?
}

// MARK: 인벤토리·고아

/// AppInventory: 설치 앱, 내장 번들, entitlements 캐시, Spotlight 상태 (plan.md 4.5.2)
public protocol InventoryProviding: Sendable {
    /// 디스크 캐시 (없으면 nil)
    func cached() -> InventorySnapshot?
    func build() async throws -> InventorySnapshot
    /// S1 앱 목록 (Apple 기본 앱 제외)
    func installedApps() async -> [InstalledApp]
}

/// OrphanScanner (plan.md 4.5)
public protocol OrphanScanning: Sendable {
    func scan(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport
}

public protocol KeepListStoring: Sendable {
    func entries() -> [KeepEntry]
    func add(_ entry: KeepEntry)
    func remove(id: String)
}

/// RuleData 로드·서명 검증·갱신 (plan.md 4.6)
public protocol RuleDataProviding: Sendable {
    func current() -> RuleData
}

public struct StaticRuleDataProvider: RuleDataProviding {
    public let data: RuleData
    public init(_ data: RuleData) { self.data = data }
    public func current() -> RuleData { data }
}

// MARK: 공용 판정 도구

/// 데이터 성격 분류 (plan.md 4.3.3). 앱 제거와 고아 스캔이 함께 쓴다.
/// Container·Group Container는 하위 항목을 펼쳐 `children`을 채우고, 사용자 데이터면 `nature = .userData`.
public protocol DataNatureClassifying: Sendable {
    func classify(_ candidate: Candidate) -> Candidate
}

/// 아무것도 바꾸지 않는 분류기 (테스트·조립 전 기본값)
public struct PassthroughNatureClassifier: DataNatureClassifying {
    public init() {}
    public func classify(_ candidate: Candidate) -> Candidate { candidate }
}

/// 모든 경로를 허용하는 SafetyChecking (테스트 전용 기본값 — 실제 조립에서는 SafetyGuard 사용)
public struct AllowAllSafety: SafetyChecking {
    public init() {}
    public func verdict(for url: URL, bundleID: String?) -> SafetyVerdict { .allowed(resolved: url.resolvingSymlinksInPath()) }
}
