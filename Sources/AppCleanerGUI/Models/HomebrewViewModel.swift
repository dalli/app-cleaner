import CleanerCore
import Foundation
import Observation

enum HomebrewSort: String, CaseIterable, Hashable, Sendable {
    case name, size

    var title: String {
        switch self {
        case .name: return L("이름")
        case .size: return L("크기 큰 순")
        }
    }
}

/// Homebrew 화면: formula·cask 목록 (읽기 전용 — 제거는 `brew uninstall` 명령 안내)
@MainActor
@Observable
final class HomebrewViewModel {
    /// 고유 명칭이라 번역하지 않는다
    static let title = "Homebrew"

    @ObservationIgnored private let engine: any CleanerEngine
    @ObservationIgnored private var sizeTask: Task<Void, Never>?

    private(set) var items: [HomebrewItem] = []
    private(set) var sizes: [String: Int64] = [:]
    private(set) var pendingSizes: Set<String> = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    var search = ""
    var sort: HomebrewSort = .name
    var kindFilter: HomebrewKind?
    var focusedID: String?

    init(engine: any CleanerEngine) {
        self.engine = engine
    }

    /// 목록을 먼저 보여주고 크기는 백그라운드에서 채운다
    func load() async {
        isLoading = true
        items = await engine.homebrewItems()
        isLoading = false
        hasLoaded = true
        computeSizes()
    }

    func reload() {
        Task { await load() }
    }

    private func computeSizes() {
        sizeTask?.cancel()
        sizes = [:]
        pendingSizes = Set(items.map(\.id))
        guard !items.isEmpty else { return }
        let engine = self.engine
        let items = self.items
        sizeTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int64?).self) { group in
                for item in items {
                    group.addTask {
                        var total: Int64 = 0
                        var known = false
                        for url in item.contentPaths {
                            if let size = await engine.size(of: url) { total += size; known = true }
                        }
                        return (item.id, known ? total : nil)
                    }
                }
                for await (id, size) in group {
                    guard !Task.isCancelled else { return }
                    self?.setSize(size, for: id)
                }
            }
        }
    }

    private func setSize(_ size: Int64?, for id: String) {
        pendingSizes.remove(id)
        if let size { sizes[id] = size }
    }

    // MARK: 표시 데이터

    func size(of item: HomebrewItem) -> Int64? { sizes[item.id] }
    func isCalculating(_ item: HomebrewItem) -> Bool { pendingSizes.contains(item.id) }

    var filteredItems: [HomebrewItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = items.filter { item in
            (kindFilter == nil || item.kind == kindFilter) && (q.isEmpty || item.name.lowercased().contains(q))
        }
        switch sort {
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            list.sort { (sizes[$0.id] ?? -1, $1.name) > (sizes[$1.id] ?? -1, $0.name) }
        }
        return list
    }

    /// 종류 필터 개수 (검색과 무관하게 전체 기준)
    func count(for kind: HomebrewKind?) -> Int {
        guard let kind else { return items.count }
        return items.filter { $0.kind == kind }.count
    }

    var dependencyCount: Int { items.filter { !$0.installedOnRequest }.count }
    var totalSize: Int64 { sizes.values.reduce(0, +) }
    var sizeIsApproximate: Bool { !pendingSizes.isEmpty }

    var focusedItem: HomebrewItem? { items.first { $0.id == focusedID } }
}
