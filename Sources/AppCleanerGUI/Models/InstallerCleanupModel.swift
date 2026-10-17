import CleanerCore
import Foundation
import Observation

/// 설치 파일 정리 시트: 새 버전을 설치한 뒤 남은 디스크 이미지 꺼내기 + 설치 파일·이전 사본을 휴지통으로
@MainActor
@Observable
final class InstallerCleanupModel: Identifiable {
    enum Phase: Equatable {
        case review
        case running
        case finished
    }

    let id = UUID()
    let report: InstallerLeftoverReport
    @ObservationIgnored private let engine: any CleanerEngine
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?

    private(set) var selectedPaths: Set<String>
    private(set) var ejectMounts: Set<String>
    private(set) var phase: Phase = .review
    private(set) var result: CleanupResult?
    private(set) var ejectFailures: [CleanupFailure] = []
    private(set) var ejectedCount = 0

    init(report: InstallerLeftoverReport, engine: any CleanerEngine) {
        self.report = report
        self.engine = engine
        selectedPaths = Set(report.candidates.filter { $0.isSelected && $0.isSelectable }.map(\.path))
        ejectMounts = Set(report.mounted.map(\.id))
    }

    func isSelected(_ c: Candidate) -> Bool { selectedPaths.contains(c.path) }

    func toggle(_ c: Candidate) {
        guard c.isSelectable, phase == .review else { return }
        if !selectedPaths.insert(c.path).inserted { selectedPaths.remove(c.path) }
    }

    func isEjecting(_ m: MountedInstaller) -> Bool { ejectMounts.contains(m.id) }

    func toggleEject(_ m: MountedInstaller) {
        guard phase == .review else { return }
        if !ejectMounts.insert(m.id).inserted { ejectMounts.remove(m.id) }
    }

    var selectedSize: Int64 {
        report.candidates.filter { selectedPaths.contains($0.path) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    var canRun: Bool { phase == .review && (!selectedPaths.isEmpty || !ejectMounts.isEmpty) }

    /// 디스크 이미지를 먼저 꺼낸 뒤(그 안의 앱이 열려 있지 않게) 고른 항목을 휴지통으로 옮긴다 — 삭제 기록에 남아 되돌릴 수 있다
    func run() async {
        guard canRun else { return }
        phase = .running
        let mounts = report.mounted.filter { ejectMounts.contains($0.id) }.map(\.mountPoint)
        if !mounts.isEmpty {
            ejectFailures = await engine.ejectDiskImages(at: mounts)
            ejectedCount = mounts.count - ejectFailures.count
        }
        let plan = engine.makePlan(for: report, selectedPaths: selectedPaths)
        if !plan.items.isEmpty {
            result = await engine.execute(plan, progress: { _ in }, onUnresponsive: { _ in .skip })
        }
        phase = .finished
        onFinished?()
    }

    var failures: [CleanupFailure] { ejectFailures + (result?.failures ?? []) }

    var summary: String {
        L("꺼낸 디스크 이미지: %lld · 휴지통으로 옮긴 항목: %lld (%@). 삭제 기록에서 되돌릴 수 있습니다.",
          ejectedCount, result?.movedCount ?? 0, Fmt.bytes(result?.movedSize ?? 0))
    }
}
