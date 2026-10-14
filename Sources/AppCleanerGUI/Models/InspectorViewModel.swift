import CleanerCore
import Foundation
import Observation

/// S2 검사기의 카테고리 (ui-ux.md S2 순서)
enum InspectorCategory: String, CaseIterable, Hashable, Sendable {
    case appBundle
    case container
    case groupContainer
    case background
    case cachesLogsState
    case preferences
    case support
    case systemFolders
    case lowConfidence

    var title: String {
        switch self {
        case .appBundle: return L("앱 본체")
        case .container: return L("샌드박스 컨테이너")
        case .groupContainer: return L("그룹 컨테이너")
        case .background: return L("백그라운드 서비스")
        case .cachesLogsState: return L("캐시 · 로그 · 저장된 상태")
        case .preferences: return L("환경설정")
        case .support: return L("앱 지원 파일")
        case .systemFolders: return L("시스템 폴더 (관리자 권한)")
        case .lowConfidence: return L("낮은 신뢰도")
        }
    }

    var subtitle: String? {
        switch self {
        case .lowConfidence: return L("이름으로만 찾은 항목")
        case .systemFolders: return L("정리할 때 관리자 암호를 한 번 묻습니다")
        default: return nil
        }
    }

    static func of(_ c: Candidate) -> InspectorCategory {
        if c.category == .appBundle { return .appBundle }
        if c.confidence == .low { return .lowConfidence }
        let group = c.category.displayGroup
        if group == .system || c.domain == .system { return .systemFolders }
        switch group {
        case .appBundle: return .appBundle
        case .container: return .container
        case .groupContainer: return .groupContainer
        case .background: return .background
        case .cachesLogsState: return .cachesLogsState
        case .preferences: return .preferences
        case .support: return .support
        case .system: return .systemFolders
        }
    }
}

/// S2 보기 필터
enum InspectorViewFilter: String, CaseIterable, Hashable, Sendable {
    case all, selected, kept

    var title: String {
        switch self {
        case .all: return L("모두")
        case .selected: return L("선택됨")
        case .kept: return L("남겨둠")
        }
    }
}

struct InspectorSection: Identifiable, Equatable {
    var category: InspectorCategory
    /// 필터를 적용한 최상위 후보 (컨테이너는 걸러진 하위 항목을 가진다)
    var items: [Candidate]
    /// 필터와 무관한 이 카테고리의 원래 후보 (체크 상태·개수 계산용)
    var allItems: [Candidate]
    var id: String { "cat:" + category.rawValue }
}

/// S2 목록의 한 줄 (카테고리 → 후보 → 컨테이너 하위 항목을 펼친 순서)
enum InspectorRow: Identifiable, Equatable {
    case category(InspectorSection)
    case item(Candidate, depth: Int)

    var id: String {
        switch self {
        case .category(let s): return s.id
        case .item(let c, _): return c.id
        }
    }
}

/// S2 잔여물 검사기
@MainActor
@Observable
final class InspectorViewModel {
    enum Phase: Equatable {
        case scanning
        case loaded
        case failed(String)
    }

    let appURL: URL
    @ObservationIgnored private let engine: any CleanerEngine

    private(set) var phase: Phase = .scanning
    private(set) var report: ScanReport?
    private(set) var tree = SelectionTree()

    var viewFilter: InspectorViewFilter = .all
    var showLowConfidence = false
    var collapsed: Set<InspectorCategory> = []
    var collapsedContainers: Set<String> = []
    /// 목록에서 포커스된 행 (정보 패널 대상). 카테고리 행이면 "cat:" 접두사.
    var focusedID: String?

    init(appURL: URL, engine: any CleanerEngine) {
        self.appURL = appURL
        self.engine = engine
    }

    /// 테스트·미리 만든 결과로 바로 시작
    init(report: ScanReport, engine: any CleanerEngine) {
        self.appURL = report.identity.bundleURL
        self.engine = engine
        apply(report)
    }

    func load() async {
        phase = .scanning
        do {
            let r = try await engine.scan(appAt: appURL)
            apply(r)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(L10n.describe(error))
        }
    }

    private func apply(_ r: ScanReport) {
        report = r
        tree = SelectionTree(roots: r.candidates)
        phase = .loaded
        // 정보 패널: 남겨두는 이유가 있는 첫 항목, 없으면 첫 항목
        let ordered = sections(filter: .all, includeLow: false).flatMap(\.items)
        focusedID = (ordered.first(where: \.isRisky) ?? ordered.first)?.id
    }

    // MARK: 표시 데이터

    var identity: AppIdentity? { report?.identity }

    var sections: [InspectorSection] { sections(filter: viewFilter, includeLow: showLowConfidence) }

    func sections(filter: InspectorViewFilter, includeLow: Bool) -> [InspectorSection] {
        guard let report else { return [] }
        var byCategory: [InspectorCategory: [Candidate]] = [:]
        for c in report.candidates { byCategory[InspectorCategory.of(c), default: []].append(c) }
        return InspectorCategory.allCases.compactMap { cat in
            guard let all = byCategory[cat], !all.isEmpty else { return nil }
            if cat == .lowConfidence && !includeLow { return nil }
            let filtered = all.compactMap { self.filtered($0, by: filter) }
            guard !filtered.isEmpty else { return nil }
            return InspectorSection(category: cat, items: filtered, allItems: all)
        }
    }

    /// 보기 필터 적용. 컨테이너는 남는 하위 항목이 있으면 그 항목만 가진 채로 남는다.
    private func filtered(_ c: Candidate, by filter: InspectorViewFilter) -> Candidate? {
        if filter == .all { return c }
        if c.children.isEmpty {
            let on = c.isSelectable && tree.selected.contains(c.path)
            return (filter == .selected) == on ? c : nil
        }
        var copy = c
        copy.children = c.children.compactMap { filtered($0, by: filter) }
        return copy.children.isEmpty ? nil : copy
    }

    /// 접힘 상태를 반영해 펼친 목록 (List가 DisclosureGroup 대신 이 순서로 그린다)
    var rows: [InspectorRow] {
        var result: [InspectorRow] = []
        for section in sections {
            result.append(.category(section))
            guard !collapsed.contains(section.category) else { continue }
            for c in section.items {
                result.append(.item(c, depth: 1))
                if !c.children.isEmpty && !collapsedContainers.contains(c.id) {
                    result += c.children.map { .item($0, depth: 2) }
                }
            }
        }
        return result
    }

    func isExpanded(_ row: InspectorRow) -> Bool {
        switch row {
        case .category(let s): return !collapsed.contains(s.category)
        case .item(let c, _): return !c.children.isEmpty && !collapsedContainers.contains(c.id)
        }
    }

    func setExpanded(_ row: InspectorRow, _ open: Bool) {
        switch row {
        case .category(let s):
            if open { collapsed.remove(s.category) } else { collapsed.insert(s.category) }
        case .item(let c, _):
            guard !c.children.isEmpty else { return }
            if open { collapsedContainers.remove(c.id) } else { collapsedContainers.insert(c.id) }
        }
    }

    /// ← / → 키: 포커스된 카테고리·컨테이너 접기/펼치기
    func setFocusedExpanded(_ open: Bool) {
        guard let id = focusedID, let row = rows.first(where: { $0.id == id }) else { return }
        setExpanded(row, open)
    }

    var allLeaves: [Candidate] { tree.allLeaves }
    var selectedLeaves: [Candidate] { tree.selectedLeaves }
    var keptLeaves: [Candidate] { tree.keptLeaves }

    func count(for filter: InspectorViewFilter) -> Int {
        switch filter {
        case .all: return allLeaves.count
        case .selected: return selectedLeaves.count
        case .kept: return keptLeaves.count
        }
    }

    var selectedCount: Int { selectedLeaves.count }
    var selectedSize: Int64 { selectedLeaves.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalSize: Int64 { allLeaves.reduce(0) { $0 + ($1.size ?? 0) } }
    var sizeIsApproximate: Bool { allLeaves.contains { $0.size == nil } }
    var keptSummary: KeptSummary { KeptSummary(keptLeaves) }
    var lowConfidenceCount: Int { allLeaves.filter { $0.confidence == .low }.count }
    var canPreview: Bool { selectedCount > 0 }
    var selectedPaths: Set<String> { tree.selectedPaths }

    // MARK: 체크 상태

    func state(of c: Candidate) -> CheckState { tree.state(of: c) }

    func state(of section: InspectorSection) -> CheckState { tree.state(of: section.allItems) }

    func toggle(_ c: Candidate) {
        guard c.isSelectable || !SelectionTree.selectableLeaves(of: c).isEmpty else { return }
        tree.toggle(c)
    }

    func toggle(_ section: InspectorSection) { tree.toggle(section.allItems) }

    func setSelected(_ c: Candidate, _ on: Bool) { tree.set(c, on: on) }

    // MARK: 포커스

    /// 포커스된 후보 (정보 패널)
    var focusedCandidate: Candidate? {
        guard let id = focusedID, !id.hasPrefix("cat:") else { return nil }
        return report?.candidates.lazy.flatMap(\.flattened).first { $0.id == id }
    }

    var focusedCategory: InspectorCategory? {
        guard let id = focusedID, id.hasPrefix("cat:") else { return nil }
        return InspectorCategory(rawValue: String(id.dropFirst(4)))
    }

    /// 사용자 데이터·공유 항목을 직접 체크했는지 (정보 패널 경고 강조, ui-ux.md 결정 3)
    func isRiskySelection(_ c: Candidate) -> Bool {
        c.isRisky && tree.state(of: c) != .off
    }

    /// Space 키: 포커스된 행 선택 토글
    func toggleFocused() {
        if let c = focusedCandidate { toggle(c) }
        else if let cat = focusedCategory, let s = sections.first(where: { $0.category == cat }) { toggle(s) }
    }

    // MARK: 배너

    func banners(permissions: PermissionStatus) -> [ScanWarning] {
        var w = report?.warnings ?? []
        if permissions.fullDiskAccess != .granted && !w.contains(.noFullDiskAccess) { w.append(.noFullDiskAccess) }
        return w
    }

    func makePlan(resetPrivacy: Bool) -> CleanupPlan? {
        guard let report else { return nil }
        return engine.makePlan(for: report, selectedPaths: selectedPaths, resetPrivacy: resetPrivacy)
    }
}
