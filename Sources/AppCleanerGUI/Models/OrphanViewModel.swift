import CleanerCore
import Foundation
import Observation

enum OrphanSort: String, CaseIterable, Hashable, Sendable {
    case size, confidence, lastModified

    var title: String {
        switch self {
        case .size: return L("크기 큰 순")
        case .confidence: return L("신뢰도")
        case .lastModified: return L("마지막 수정일")
        }
    }
}

/// S5 목록의 한 줄
enum OrphanRow: Identifiable, Equatable {
    case group(OrphanGroup)
    case item(Candidate)
    /// "항목 n개 더 보기"
    case more(groupID: String, count: Int)

    var id: String {
        switch self {
        case .group(let g): return "group:" + g.id
        case .item(let c): return c.id
        case .more(let gid, _): return "more:" + gid
        }
    }
}

/// S5 고아 잔여물
@MainActor
@Observable
final class OrphanViewModel {
    enum Phase: Equatable {
        case idle
        case scanning(OrphanScanPhase)
        case finished
        case cancelled
        case failed(String)
    }

    /// "유지" 직후 되돌리기 토스트
    struct KeepUndo: Equatable {
        var entry: KeepEntry
        var group: OrphanGroup
        var index: Int
        var selection: Set<String>
    }

    static let collapsedItemLimit = 3

    @ObservationIgnored private let engine: any CleanerEngine
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private(set) var phase: Phase = .idle
    /// 유지 목록에 넣은 그룹을 뺀 결과
    private(set) var groups: [OrphanGroup] = []
    private(set) var report: OrphanScanReport?
    private(set) var tree = SelectionTree()
    private(set) var hiddenByKeepList = 0
    private(set) var keepUndo: KeepUndo?
    private(set) var hasScanned = false

    var confidenceFilter: Confidence?
    var sort: OrphanSort = .size
    var expanded: Set<String> = []
    var showAllItems: Set<String> = []
    var focusedID: String?
    /// 토스트 표시 시간 (테스트에서 0)
    @ObservationIgnored var toastDuration: Duration = .seconds(8)

    init(engine: any CleanerEngine) {
        self.engine = engine
    }

    // MARK: 스캔

    var isScanning: Bool { if case .scanning = phase { return true }; return false }

    func startScan(includeDotfiles: Bool) {
        guard !isScanning else { return }
        scanTask?.cancel()
        groups = []
        report = nil
        tree = SelectionTree()
        expanded = []
        showAllItems = []
        keepUndo = nil
        phase = .scanning(.buildingInventory)
        let engine = self.engine
        let options = OrphanScanOptions(includeDotfiles: includeDotfiles)
        let (stream, continuation) = AsyncStream<OrphanScanEvent>.makeStream()
        let consumer = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        scanTask = Task {
            do {
                let r = try await engine.scanOrphans(options: options) { continuation.yield($0) }
                continuation.finish()
                // 마지막 진행 이벤트를 모두 반영한 뒤 결과를 적용한다
                await consumer.value
                self.apply(r)
            } catch {
                continuation.finish()
                self.scanEnded(error)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func handle(_ event: OrphanScanEvent) {
        guard isScanning else { return }
        switch event {
        case .phase(let p) where p != .finished:
            phase = .scanning(p)
        case .phase:
            break
        case .groupFound(let g):
            guard !groups.contains(where: { $0.id == g.id }) else { return }
            groups.append(g)
            tree.merge(roots: groups.flatMap(\.items))
        }
    }

    /// 스캔 결과 적용. 스캔 중 사용자가 바꾼 선택은 유지한다.
    func apply(_ r: OrphanScanReport) {
        report = r
        groups = r.groups
        hiddenByKeepList = r.hiddenByKeepList
        tree.merge(roots: groups.flatMap(\.items))
        phase = .finished
        hasScanned = true
        // 처음에는 가장 큰 그룹을 펼쳐 항목 행과 판정 근거를 바로 보여 준다
        if expanded.isEmpty, let first = visibleGroups.first { expanded.insert(first.id) }
    }

    private func scanEnded(_ error: any Error) {
        if error is CancellationError {
            phase = .cancelled
            hasScanned = hasScanned || !groups.isEmpty
        } else {
            phase = .failed(L10n.describe(error))
        }
    }

    // MARK: 표시 데이터

    /// 사이드바 숫자 (스캔 전에는 없음)
    var badgeCount: Int? { hasScanned ? groups.count : nil }

    var visibleGroups: [OrphanGroup] {
        let list = groups.filter { confidenceFilter == nil || $0.confidence == confidenceFilter }
        switch sort {
        case .size:
            return list.sorted { $0.totalSize > $1.totalSize }
        case .confidence:
            return list.sorted { ($0.confidence, $0.totalSize) > ($1.confidence, $1.totalSize) }
        case .lastModified:
            return list.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        }
    }

    func count(for confidence: Confidence?) -> Int {
        guard let confidence else { return groups.count }
        return groups.filter { $0.confidence == confidence }.count
    }

    /// 그룹 펼침 시 보일 항목 (처음 3개 + "n개 더 보기")
    func visibleItems(of group: OrphanGroup) -> [Candidate] {
        showAllItems.contains(group.id) ? group.items : Array(group.items.prefix(Self.collapsedItemLimit))
    }

    /// 펼침 상태를 반영한 목록
    var rows: [OrphanRow] {
        var result: [OrphanRow] = []
        for g in visibleGroups {
            result.append(.group(g))
            guard expanded.contains(g.id) else { continue }
            result += visibleItems(of: g).map { .item($0) }
            let hidden = hiddenItemCount(of: g)
            if hidden > 0 { result.append(.more(groupID: g.id, count: hidden)) }
        }
        return result
    }

    func setExpanded(groupID: String, _ open: Bool) {
        if open { expanded.insert(groupID) } else { expanded.remove(groupID) }
    }

    /// ← / → 키
    func setFocusedExpanded(_ open: Bool) {
        guard let id = focusedID else { return }
        if id.hasPrefix("group:") {
            setExpanded(groupID: String(id.dropFirst(6)), open)
        } else if !open, let g = groups.first(where: { $0.items.contains { $0.id == id } }) {
            setExpanded(groupID: g.id, false)
            focusedID = "group:" + g.id
        }
    }

    func hiddenItemCount(of group: OrphanGroup) -> Int {
        showAllItems.contains(group.id) ? 0 : max(0, group.items.count - Self.collapsedItemLimit)
    }

    var selectedLeaves: [Candidate] { tree.selectedLeaves }
    var selectedSize: Int64 { selectedLeaves.reduce(0) { $0 + ($1.size ?? 0) } }
    var selectedItemCount: Int { selectedLeaves.count }
    var selectedGroupCount: Int { groups.filter { tree.state(of: $0.items) != .off }.count }
    var canPreview: Bool { selectedItemCount > 0 && !isScanning }
    var selectedPaths: Set<String> { tree.selectedPaths }

    // MARK: 선택

    func state(of group: OrphanGroup) -> CheckState { tree.state(of: group.items) }
    func state(of item: Candidate) -> CheckState { tree.state(of: item) }
    func toggle(_ group: OrphanGroup) { tree.toggle(group.items) }
    func toggle(_ item: Candidate) { tree.toggle(item) }

    /// "높음만 선택": 높음이면서 사용자 데이터·공유가 아닌 항목만 선택하고 나머지는 해제
    func selectHighOnly() {
        tree.select { $0.confidence == .high && $0.nature != .userData && !$0.share.isShared }
    }

    func toggleFocused() {
        guard let id = focusedID else { return }
        if let g = groups.first(where: { "group:" + $0.id == id }) { toggle(g); return }
        if let item = groups.lazy.flatMap(\.items).first(where: { $0.id == id }) { toggle(item) }
    }

    var focusedPath: String? {
        guard let id = focusedID else { return nil }
        if id.hasPrefix("group:") {
            return groups.first { "group:" + $0.id == id }?.items.first?.path
        }
        return id
    }

    // MARK: 유지 목록

    /// 그룹을 유지 목록에 넣고 목록에서 뺀다. 하단에 "되돌리기" 토스트.
    func keep(_ group: OrphanGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let entry = KeepEntry(kind: .group, key: group.id, displayName: group.title)
        engine.addToKeepList(entry)
        let selection = Set(group.items.flatMap(SelectionTree.leaves(of:)).map(\.path)).intersection(tree.selected)
        groups.remove(at: index)
        tree.merge(roots: groups.flatMap(\.items))
        hiddenByKeepList += 1
        keepUndo = KeepUndo(entry: entry, group: group, index: index, selection: selection)
        scheduleToastDismiss()
    }

    func undoKeep() {
        guard let undo = keepUndo else { return }
        engine.removeFromKeepList(id: undo.entry.id)
        groups.insert(undo.group, at: min(undo.index, groups.count))
        tree.merge(roots: groups.flatMap(\.items))
        tree.restore(selection: undo.selection, for: undo.group.items)
        hiddenByKeepList = max(0, hiddenByKeepList - 1)
        keepUndo = nil
        toastTask?.cancel()
    }

    func dismissToast() {
        keepUndo = nil
        toastTask?.cancel()
    }

    private func scheduleToastDismiss() {
        toastTask?.cancel()
        let duration = toastDuration
        guard duration > .zero else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.keepUndo = nil
        }
    }

    // MARK: 정리

    /// 현재 화면 상태(유지한 그룹 제외)를 반영한 보고서
    var reportForPlan: OrphanScanReport? {
        guard var r = report else { return nil }
        r.groups = groups
        return r
    }

    func makePlan() -> CleanupPlan? {
        guard let r = reportForPlan else { return nil }
        return engine.makePlan(for: r, selectedPaths: selectedPaths)
    }

    /// 정리 후 결과에서 옮긴 항목을 뺀다
    func removeCleaned(paths: Set<String>) {
        guard !paths.isEmpty else { return }
        groups = groups.compactMap { g in
            var g = g
            g.items = g.items.filter { !paths.contains($0.path) }
            return g.items.isEmpty ? nil : g
        }
        tree.merge(roots: groups.flatMap(\.items))
        if var r = report { r.groups = groups; report = r }
    }

    var spotlightIncomplete: Bool { report.map { !$0.spotlight.isReliable } ?? false }
}
