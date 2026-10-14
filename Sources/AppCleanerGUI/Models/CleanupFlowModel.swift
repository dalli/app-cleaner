import CleanerCore
import Foundation
import Observation

/// 정리가 시작된 화면
enum CleanupOrigin: Sendable, Equatable {
    case appRemoval
    case orphans
}

/// S3 정리 미리보기 시트 + 진행 중 상태
@MainActor
@Observable
final class CleanupFlowModel: Identifiable {
    enum Phase: Equatable {
        case preview
        case running
        case unresponsive(UnresponsiveApp)
        case finished
    }

    let id = UUID()
    let origin: CleanupOrigin
    @ObservationIgnored private let engine: any CleanerEngine
    @ObservationIgnored private let rebuild: (@MainActor (Bool) -> CleanupPlan)?
    @ObservationIgnored private var unresponsiveContinuation: CheckedContinuation<UnresponsiveDecision, Never>?
    @ObservationIgnored var onFinished: (@MainActor (CleanupFlowModel, CleanupResult) -> Void)?

    private(set) var plan: CleanupPlan

    /// 개인정보 보호 권한 기록 초기화 (앱 제거만). 바꾸면 계획을 다시 만든다.
    var resetPrivacy: Bool {
        didSet {
            guard resetPrivacy != oldValue, let rebuild else { return }
            plan = rebuild(resetPrivacy)
        }
    }

    var showKeptItems = false

    private(set) var phase: Phase = .preview
    private(set) var currentStep: CleanupStep?
    private(set) var completedSteps: Set<CleanupStep> = []
    private(set) var movedCount = 0
    private(set) var failures: [CleanupFailure] = []
    private(set) var result: CleanupResult?

    /// - Parameter rebuild: 개인정보 옵션이 바뀌면 계획을 다시 만드는 함수 (앱 제거에서만 제공)
    init(origin: CleanupOrigin, plan: CleanupPlan, engine: any CleanerEngine,
         resetPrivacy: Bool = false, rebuild: (@MainActor (Bool) -> CleanupPlan)? = nil) {
        self.origin = origin
        self.plan = plan
        self.engine = engine
        self.rebuild = rebuild
        self.resetPrivacy = resetPrivacy
    }

    // MARK: 요약 (S3 3칸)

    var canResetPrivacy: Bool { rebuild != nil }
    var moveCount: Int { plan.items.count }
    var reclaimSize: Int64 { plan.totalSize }
    var sizeIsApproximate: Bool { plan.items.contains { $0.size == nil } }
    var keptCount: Int { plan.keptItems.count }
    var keptSummary: KeptSummary { KeptSummary(plan.keptItems) }
    /// 해당 없는 단계는 표시하지 않는다
    var steps: [CleanupStep] { plan.steps }
    var requiresAdmin: Bool { plan.requiresAdmin }
    var adminItems: [Candidate] { plan.adminItems }
    var riskyItems: [Candidate] { plan.riskyItems }
    var canExecute: Bool { !plan.items.isEmpty && phase == .preview }

    /// 진행 단계 설명 (S3 진행 순서)
    func stepTitle(_ step: CleanupStep) -> String {
        switch step {
        case .stopServices: return L("백그라운드 서비스 %lld개 중지", plan.servicesToStop.count)
        case .terminateApps: return L("%@ 종료 요청", plan.targetTitle)
        case .flushPreferences: return L("환경설정 캐시 비우기")
        case .moveItems: return L("%lld개 항목을 휴지통으로 이동", moveCount)
        case .postProcess:
            var parts: [String] = []
            if !plan.receiptsToForget.isEmpty { parts.append(L("설치 기록 정리")) }
            if plan.resetPrivacy { parts.append(L("개인정보 보호 권한 기록 초기화")) }
            return parts.isEmpty ? L("마무리") : parts.joined(separator: " · ")
        }
    }

    func stepDetail(_ step: CleanupStep) -> String {
        switch step {
        case .stopServices: return L("앱보다 먼저 멈춰야 종료 후 다시 실행되지 않습니다.")
        case .terminateApps: return L("저장하지 않은 문서가 있으면 앱이 먼저 물어봅니다. 응답이 없으면 강제 종료할지 다시 확인합니다.")
        case .flushPreferences: return L("설정 파일이 다시 생기지 않도록 시스템 캐시에서도 지웁니다.")
        case .moveItems: return L("영구 삭제하지 않습니다. 삭제 기록에서 언제든 되돌릴 수 있습니다.")
        case .postProcess: return L("설치 기록과 권한 기록을 정리합니다. 이 단계는 되돌릴 수 없지만 앱을 다시 설치하면 새로 만들어집니다.")
        }
    }

    // MARK: 실행

    func start() {
        guard canExecute else { return }
        phase = .running
        let plan = self.plan
        let engine = self.engine
        let (stream, continuation) = AsyncStream<CleanupProgress>.makeStream()
        let consumer = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        Task {
            let result = await engine.execute(
                plan,
                progress: { continuation.yield($0) },
                onUnresponsive: { [self] app in await self.askUnresponsive(app) }
            )
            continuation.finish()
            // 남은 진행 이벤트를 모두 반영한 뒤 완료로 바꾼다 (마지막 단계 체크 누락 방지)
            await consumer.value
            self.finish(result)
        }
    }

    private func handle(_ event: CleanupProgress) {
        switch event {
        case .stepStarted(let s): currentStep = s
        case .stepFinished(let s):
            completedSteps.insert(s)
            if currentStep == s { currentStep = nil }
        case .itemMoved(_, let completed, _): movedCount = completed
        case .itemFailed(let path, let reason): failures.append(CleanupFailure(path: path, reason: reason))
        }
    }

    private func askUnresponsive(_ app: UnresponsiveApp) async -> UnresponsiveDecision {
        await withCheckedContinuation { cont in
            unresponsiveContinuation = cont
            phase = .unresponsive(app)
        }
    }

    /// 강제 종료 / 건너뛰기 / 취소
    func respond(_ decision: UnresponsiveDecision) {
        guard let cont = unresponsiveContinuation else { return }
        unresponsiveContinuation = nil
        phase = .running
        cont.resume(returning: decision)
    }

    private func finish(_ result: CleanupResult) {
        self.result = result
        phase = .finished
        onFinished?(self, result)
    }
}

/// S4 정리 완료
@MainActor
@Observable
final class CompletionModel {
    enum UndoState: Equatable {
        case idle
        case running
        case done(restored: Int, skipped: Int, missing: Int, failed: Int)
    }

    let origin: CleanupOrigin
    let plan: CleanupPlan
    let result: CleanupResult
    @ObservationIgnored private let engine: any CleanerEngine
    private(set) var undoState: UndoState = .idle
    var showKeptItems = false

    init(origin: CleanupOrigin, plan: CleanupPlan, result: CleanupResult, engine: any CleanerEngine) {
        self.origin = origin
        self.plan = plan
        self.result = result
        self.engine = engine
    }

    /// 결과와 계획의 안내를 합친다 (중복 제거)
    var advisories: [Advisory] {
        var seen = Set<String>()
        return (result.advisories + plan.advisories).filter { seen.insert($0.stableID).inserted }
    }

    var keptSummary: KeptSummary { KeptSummary(plan.keptItems) }
    var canUndo: Bool { result.movedCount > 0 && undoState == .idle }

    var title: String {
        if result.cancelled { return L("정리를 취소했습니다") }
        return origin == .orphans ? L("고아 잔여물을 정리했습니다") : L("%@ 정리했습니다", Josa.eulReul(plan.targetTitle))
    }

    var summary: String {
        let size = Fmt.bytes(result.movedSize)
        if result.movedToHolding > 0 {
            return L("%lld개 항목, %@를 휴지통과 보류 폴더로 옮겼습니다. 삭제 기록에서 되돌릴 수 있습니다.", result.movedCount, size)
        }
        if result.cancelled {
            return result.movedCount > 0
                ? L("취소하기 전에 옮긴 %lld개 항목은 되돌릴 수 있습니다.", result.movedCount)
                : L("아무것도 옮기지 않았습니다.")
        }
        return L("%lld개 항목, %@를 휴지통으로 옮겼습니다. 휴지통을 비우기 전까지 되돌릴 수 있습니다.", result.movedCount, size)
    }

    func undo() async {
        guard canUndo else { return }
        undoState = .running
        let r = await engine.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        undoState = .done(restored: r.restored.count, skipped: r.skipped.count, missing: r.missing.count, failed: r.failures.count)
    }
}
