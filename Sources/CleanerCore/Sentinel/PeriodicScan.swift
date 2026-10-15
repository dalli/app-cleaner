import Foundation

/// 정기 고아 스캔 일정 (ui-ux.md S10 "백그라운드 실행 방식").
///
/// 다음 예정 = 마지막 성공 + 주기. 한 번도 성공하지 않았으면 바로.
/// 마지막 시도가 실패했으면(시도 > 성공) 그 시도로부터 `retryDelay` 뒤까지 미룬다.
/// 시계를 되돌려 기록이 미래에 있으면 그 기록은 없는 것으로 본다.
public struct PeriodicScanSchedule: Sendable {
    public static let retryDelay: TimeInterval = 6 * 3600

    public var interval: PeriodicScanInterval
    public var calendar: Calendar

    public init(interval: PeriodicScanInterval, calendar: Calendar = .current) {
        self.interval = interval
        self.calendar = calendar
    }

    /// 다음 예정 시각. 꺼져 있으면 nil
    public func nextDue(lastScan: Date?, lastAttempt: Date?, now: Date) -> Date? {
        guard interval != .off else { return nil }
        let scan = lastScan.flatMap { $0 <= now ? $0 : nil }
        var due = scan.map(adding) ?? now
        if let attempt = lastAttempt, attempt <= now, attempt > (scan ?? .distantPast) {
            due = max(due, attempt.addingTimeInterval(Self.retryDelay))
        }
        return due
    }

    public func isDue(lastScan: Date?, lastAttempt: Date?, now: Date) -> Bool {
        guard let due = nextDue(lastScan: lastScan, lastAttempt: lastAttempt, now: now) else { return false }
        return due <= now
    }

    /// 주기만큼 뒤 (매달은 달력 기준 — 1월 31일 → 2월 말일)
    func adding(_ date: Date) -> Date {
        switch interval {
        case .off: return date
        case .weekly: return calendar.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(7 * 86_400)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(30 * 86_400)
        }
    }
}

/// 정기 스캔 알림 내용 — 유지 목록을 뺀 **신뢰도 높음** 항목이 있을 때만 만든다 (plan.md 7.3, ui-ux.md S10)
public struct OrphanAlertSummary: Sendable, Hashable {
    /// 높음 항목이 있는 그룹(삭제된 앱) 수
    public var groupCount: Int
    public var itemCount: Int
    /// 높음 항목 크기 합 (크기를 모르는 항목은 0)
    public var totalSize: Int64
    /// 크기가 큰 순서의 그룹 이름 (최대 3개)
    public var groupNames: [String]

    public init(groupCount: Int, itemCount: Int, totalSize: Int64, groupNames: [String]) {
        self.groupCount = groupCount
        self.itemCount = itemCount
        self.totalSize = totalSize
        self.groupNames = groupNames
    }

    /// 스캔 결과에서 알림 내용을 만든다. 높음 항목이 없으면 nil.
    /// 엔진이 이미 유지 목록을 적용하지만, 결과를 다른 프로세스(CLI)에서 받으므로 여기서 한 번 더 뺀다.
    /// 보호·동기화 항목처럼 선택할 수 없는 항목은 세지 않는다.
    public static func evaluate(_ report: OrphanScanReport, keepList: [KeepEntry],
                                language: AppLanguage = .current) -> OrphanAlertSummary? {
        let (visible, _) = OrphanScanner.applyKeepList(report.groups, entries: keepList)
        var groups: [(name: String, count: Int, size: Int64)] = []
        for g in visible {
            let high = g.items.filter { $0.confidence == .high && $0.isSelectable }
            guard !high.isEmpty else { continue }
            groups.append((g.title(language), high.count, high.reduce(0) { $0 + ($1.size ?? 0) }))
        }
        guard !groups.isEmpty else { return nil }
        let names = groups.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }.prefix(3).map(\.name)
        return OrphanAlertSummary(groupCount: groups.count, itemCount: groups.reduce(0) { $0 + $1.count },
                                  totalSize: groups.reduce(0) { $0 + $1.size }, groupNames: Array(names))
    }
}
