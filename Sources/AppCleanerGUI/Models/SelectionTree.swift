import CleanerCore
import Foundation

/// 3상태 체크박스 값 (ui-ux.md S2 카테고리, S5 그룹)
enum CheckState: Equatable, Sendable {
    case on
    case off
    case mixed

    /// VoiceOver 값 ("일부 선택됨")
    var spokenValue: String {
        switch self {
        case .on: return L("선택됨")
        case .off: return L("선택 안 됨")
        case .mixed: return L("일부 선택됨")
        }
    }
}

/// 후보 트리의 선택 상태.
///
/// - 선택은 **잎**(하위 항목이 없는 후보) 단위로 저장한다. 컨테이너·카테고리·그룹의 상태는 잎에서 계산한다.
/// - 처음 보는 잎은 엔진이 정한 기본 선택(`isSelected`)을 따른다. 보호 항목(`isSelectable == false`)은 선택되지 않는다.
/// - 엔진에 넘기는 경로(`selectedPaths`)에는 선택된 잎과, 모든 잎이 선택되고 선택 불가 잎이 없는 컨테이너 자신이 들어간다.
struct SelectionTree: Sendable {
    private(set) var roots: [Candidate] = []
    private(set) var selected: Set<String> = []
    private var knownLeaves: Set<String> = []

    init(roots: [Candidate] = []) {
        merge(roots: roots)
    }

    // MARK: 구조

    static func leaves(of candidate: Candidate) -> [Candidate] {
        candidate.children.isEmpty ? [candidate] : candidate.children.flatMap(leaves(of:))
    }

    static func selectableLeaves(of candidate: Candidate) -> [Candidate] {
        leaves(of: candidate).filter(\.isSelectable)
    }

    var allLeaves: [Candidate] { roots.flatMap(Self.leaves(of:)) }

    /// 새 후보 목록으로 바꾼다. 이미 알던 잎은 현재 선택을 유지하고, 새 잎은 기본 선택을 따른다.
    mutating func merge(roots newRoots: [Candidate]) {
        roots = newRoots
        let leaves = newRoots.flatMap(Self.leaves(of:))
        let paths = Set(leaves.map(\.path))
        for leaf in leaves where !knownLeaves.contains(leaf.path) {
            if leaf.isSelected && leaf.isSelectable { selected.insert(leaf.path) }
        }
        knownLeaves = paths
        selected.formIntersection(paths)
    }

    // MARK: 조회

    func isSelected(_ candidate: Candidate) -> Bool { state(of: candidate) == .on }

    func state(of candidate: Candidate) -> CheckState {
        state(ofLeaves: Self.selectableLeaves(of: candidate))
    }

    func state(of candidates: [Candidate]) -> CheckState {
        state(ofLeaves: candidates.flatMap(Self.selectableLeaves(of:)))
    }

    private func state(ofLeaves leaves: [Candidate]) -> CheckState {
        guard !leaves.isEmpty else { return .off }
        let n = leaves.filter { selected.contains($0.path) }.count
        if n == 0 { return .off }
        return n == leaves.count ? .on : .mixed
    }

    /// 선택된 잎 (화면 개수·크기 계산용)
    var selectedLeaves: [Candidate] { allLeaves.filter { $0.isSelectable && selected.contains($0.path) } }
    var keptLeaves: [Candidate] { allLeaves.filter { !($0.isSelectable && selected.contains($0.path)) } }

    /// 엔진 `makePlan`에 넘길 경로
    var selectedPaths: Set<String> {
        var result = Set<String>()
        func visit(_ c: Candidate) {
            if c.children.isEmpty {
                if c.isSelectable && selected.contains(c.path) { result.insert(c.path) }
                return
            }
            c.children.forEach(visit)
            let leaves = Self.leaves(of: c)
            if c.isSelectable && leaves.allSatisfy({ $0.isSelectable && selected.contains($0.path) }) {
                result.insert(c.path)
            }
        }
        roots.forEach(visit)
        return result
    }

    // MARK: 변경

    mutating func set(_ candidate: Candidate, on: Bool) {
        set(Self.selectableLeaves(of: candidate), on: on)
    }

    mutating func set(_ candidates: [Candidate], on: Bool) {
        for leaf in candidates.flatMap(Self.selectableLeaves(of:)) {
            if on { selected.insert(leaf.path) } else { selected.remove(leaf.path) }
        }
    }

    /// 전체 선택이 아니면 모두 선택, 전체 선택이면 모두 해제
    mutating func toggle(_ candidate: Candidate) {
        set(candidate, on: state(of: candidate) != .on)
    }

    mutating func toggle(_ candidates: [Candidate]) {
        set(candidates, on: state(of: candidates) != .on)
    }

    /// 조건에 맞는 잎만 선택하고 나머지는 해제 (고아 "높음만 선택")
    mutating func select(where predicate: (Candidate) -> Bool) {
        selected = Set(allLeaves.filter { $0.isSelectable && predicate($0) }.map(\.path))
    }

    /// 일부 잎의 선택 상태를 통째로 되돌린다 (유지 되돌리기)
    mutating func restore(selection paths: Set<String>, for candidates: [Candidate]) {
        for leaf in candidates.flatMap(Self.leaves(of:)) {
            if paths.contains(leaf.path) && leaf.isSelectable { selected.insert(leaf.path) } else { selected.remove(leaf.path) }
        }
    }
}

/// 남겨두는 항목 요약 (S2 하단 바, S3, S4)
struct KeptSummary: Equatable, Sendable {
    var protected = 0
    var shared = 0
    var userData = 0
    var low = 0
    var other = 0

    var total: Int { protected + shared + userData + low + other }

    /// 항목마다 한 묶음에만 센다: 보호됨 → 낮음 → 공유 → 사용자 데이터 → 기타
    /// (낮은 신뢰도 항목은 기본으로 숨겨져 있으므로 "낮음"으로 먼저 센다)
    init(_ items: [Candidate]) {
        for item in items {
            if !item.isSelectable { protected += 1 }
            else if item.confidence == .low { low += 1 }
            else if item.share.isShared { shared += 1 }
            else if item.nature == .userData { userData += 1 }
            else { other += 1 }
        }
    }

    init() {}

    /// "공유 2 · 사용자 데이터 1 · 낮음 4"
    var breakdown: String {
        var parts: [String] = []
        if shared > 0 { parts.append(L("공유 %lld", shared)) }
        if userData > 0 { parts.append(L("사용자 데이터 %lld", userData)) }
        if low > 0 { parts.append(L("낮음 %lld", low)) }
        if protected > 0 { parts.append(L("보호됨 %lld", protected)) }
        if other > 0 { parts.append(L("직접 해제 %lld", other)) }
        return parts.joined(separator: " · ")
    }
}
