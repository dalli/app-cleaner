import CleanerCore
import Foundation
import Observation

enum AppSort: String, CaseIterable, Hashable, Sendable {
    case size, name, lastUsed

    var title: String {
        switch self {
        case .size: return L("크기 큰 순")
        case .name: return L("이름")
        case .lastUsed: return L("마지막 사용일")
        }
    }
}

/// S1 앱 목록
@MainActor
@Observable
final class AppListViewModel {
    @ObservationIgnored private let engine: any CleanerEngine
    @ObservationIgnored private var sizeTask: Task<Void, Never>?

    private(set) var apps: [InstalledApp] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// 크기를 계산 중인 앱 (id)
    private(set) var pendingSizes: Set<String> = []

    var search = ""
    var sort: AppSort = .size
    var sourceFilter: InstallSource?
    var focusedID: String?

    init(engine: any CleanerEngine) {
        self.engine = engine
    }

    /// 목록을 먼저 보여주고 크기는 백그라운드에서 채운다 (ui-ux.md S1)
    func load() async {
        isLoading = true
        apps = await engine.installedApps()
        isLoading = false
        hasLoaded = true
        computeMissingSizes()
    }

    func reload() {
        Task { await load() }
    }

    private func computeMissingSizes() {
        sizeTask?.cancel()
        let missing = apps.filter { $0.size == nil }
        pendingSizes = Set(missing.map(\.id))
        guard !missing.isEmpty else { return }
        let engine = self.engine
        sizeTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int64?).self) { group in
                for app in missing {
                    group.addTask { (app.id, await engine.size(of: app.url)) }
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
        if let i = apps.firstIndex(where: { $0.id == id }) { apps[i].size = size }
    }

    // MARK: 표시 데이터

    var filteredApps: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var list = apps.filter { app in
            (sourceFilter == nil || app.source == sourceFilter)
                && (q.isEmpty || app.name.lowercased().contains(q) || app.bundleID.lowercased().contains(q))
        }
        switch sort {
        case .size:
            list.sort { ($0.size ?? -1, $1.name) > ($1.size ?? -1, $0.name) }
        case .name:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .lastUsed:
            list.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }
        return list
    }

    /// 출처 필터 개수 (검색과 무관하게 전체 기준)
    func count(for source: InstallSource?) -> Int {
        guard let source else { return apps.count }
        return apps.filter { $0.source == source }.count
    }

    var totalSize: Int64 { apps.reduce(0) { $0 + ($1.size ?? 0) } }
    var sizeIsApproximate: Bool { !pendingSizes.isEmpty || apps.contains { $0.size == nil } }

    func isCalculating(_ app: InstalledApp) -> Bool { app.size == nil && pendingSizes.contains(app.id) }

    /// 마지막 사용이 6개월 이상 지났는지 (강조색)
    static func isLongUnused(_ app: InstalledApp, now: Date = Date()) -> Bool {
        guard let last = app.lastUsed,
              let limit = Calendar.current.date(byAdding: .month, value: -6, to: now) else { return false }
        return last <= limit
    }

    var focusedApp: InstalledApp? { apps.first { $0.id == focusedID } }
}
