import Foundation

/// 검사 결과 + 사용자 선택 → 정리 실행 계획 (S3 미리보기 / CLI `--dry-run`)
///
/// 규칙
/// - 후보 트리를 펼쳐서 판단한다. 선택된 상위 컨테이너는 **하나의 항목으로** 옮긴다. 단 하위 항목 중 일부만 선택됐거나
///   선택할 수 없는(보호) 하위 항목이 있으면 상위는 옮기지 않고 선택된 하위 항목만 옮긴다.
/// - 선택 불가(보호·동기화) 항목은 절대 계획에 넣지 않는다.
/// - 설치 영수증(`.receipt`)은 파일을 옮기지 않고 `pkgutil --forget` 대상으로 만든다.
/// - 그 밖의 모든 후보는 `keptItems`.
public enum CleanupPlanner {
    public static let orphanTargetName = "고아 잔여물"
    /// 패키지 매니저 캐시만 정리할 때의 대상 이름
    public static let packageCacheTargetName = "패키지 매니저 캐시"

    // MARK: 앱 제거

    public static func plan(for report: ScanReport, selectedPaths: Set<String>, resetPrivacy: Bool) -> CleanupPlan {
        let identity = report.identity
        var (moved, kept) = resolve(report.candidates, selected: normalized(selectedPaths))
        let receipts = extractReceipts(&moved)
        moved = dedupNested(moved)

        let appKey = key(identity.bundleURL.path)
        let appSelected = moved.contains { $0.category == .appBundle || key($0.path) == appKey }

        let covered = coveredCandidates(report.candidates, by: moved)
        var services = collectServices(covered)
        if appSelected { services += identity.embeddedLaunchServices }

        return CleanupPlan(
            kind: .appRemoval,
            targetName: identity.title,
            targetBundleID: identity.bundleID,
            items: moved,
            keptItems: kept,
            servicesToStop: unique(services),
            bundleIDsToTerminate: identity.allBundleIDs,
            bundlePathsToTerminate: [identity.bundleURL],
            preferencesDomains: collectDomains(covered),
            receiptsToForget: receipts,
            resetPrivacy: resetPrivacy,
            advisories: report.advisories,
            ruleDataVersion: report.ruleDataVersion
        )
    }

    // MARK: 고아 잔여물

    public static func plan(for report: OrphanScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        let all = report.groups.flatMap(\.items)
        var (moved, kept) = resolve(all, selected: normalized(selectedPaths))
        let receipts = extractReceipts(&moved)
        moved = dedupNested(moved)
        let covered = coveredCandidates(all, by: moved)
        return CleanupPlan(
            kind: .orphanCleanup,
            targetName: orphanTargetName,
            items: moved,
            keptItems: kept,
            servicesToStop: unique(collectServices(covered)),
            preferencesDomains: collectDomains(covered),
            receiptsToForget: receipts,
            resetPrivacy: false,
            ruleDataVersion: report.ruleDataVersion
        )
    }

    // MARK: 패키지 (docs/packages.md)

    /// 설치 항목·데이터·패키지 매니저 캐시. 서비스 중지·앱 종료·cfprefs 단계는 없다 (이동만).
    public static func plan(for report: PackageScanReport, selectedPaths: Set<String>) -> CleanupPlan {
        let all = report.packages.flatMap(\.candidates) + report.caches
        var (moved, kept) = resolve(dedupByPath(all), selected: normalized(selectedPaths))
        moved = dedupNested(moved)
        let movedKeys = Set(moved.map { key($0.path) })
        let names = report.packages.filter { r in r.candidates.contains { movedKeys.contains(key($0.path)) } }.map(\.package.name)
        var unique: [String] = []
        for n in names where !unique.contains(n) { unique.append(n) }
        return CleanupPlan(
            kind: .packageRemoval,
            targetName: unique.isEmpty ? packageCacheTargetName : unique.joined(separator: ", "),
            items: moved,
            keptItems: kept,
            ruleDataVersion: report.ruleDataVersion
        )
    }

    /// 같은 경로가 여러 패키지의 후보로 나오면 한 번만 (첫 후보 기준)
    static func dedupByPath(_ items: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0.path)).inserted }
    }

    // MARK: 선택 해석

    /// (옮길 항목, 남겨둘 항목). 옮길 항목 중 "통째로" 옮기는 컨테이너는 `children`을 비운다.
    static func resolve(_ candidates: [Candidate], selected: Set<String>) -> ([Candidate], [Candidate]) {
        var moved: [Candidate] = []
        var kept: [Candidate] = []
        for c in candidates {
            let (m, k) = resolve(c, selected: selected)
            moved += m
            kept += k
        }
        return (moved, kept)
    }

    static func resolve(_ c: Candidate, selected: Set<String>) -> ([Candidate], [Candidate]) {
        // 보호·동기화 항목과 그 하위는 계획에 넣지 않는다.
        guard c.isSelectable else { return ([], [c]) }
        let isSelected = selected.contains(key(c.path))
        guard !c.children.isEmpty else { return isSelected ? ([c], []) : ([], [c]) }

        let descendants = c.children.flatMap(\.flattened)
        let hasProtectedDescendant = descendants.contains { !$0.isSelectable }
        let selectedDescendants = descendants.filter { selected.contains(key($0.path)) }
        let allChildrenSelected = c.children.allSatisfy { child in
            child.flattened.allSatisfy { $0.isSelectable && selected.contains(key($0.path)) }
        }

        if isSelected && !hasProtectedDescendant && (allChildrenSelected || selectedDescendants.isEmpty) {
            var whole = c
            whole.children = []
            return ([whole], [])
        }

        // 일부만: 선택된 하위 항목만 옮긴다. 상위 폴더 자체는 남는다.
        var moved: [Candidate] = []
        var kept: [Candidate] = []
        for child in c.children {
            let (m, k) = resolve(child, selected: selected)
            moved += m
            kept += k
        }
        if moved.isEmpty { return ([], [c]) }
        return (moved, kept)
    }

    /// 다른 이동 항목 아래에 있는 항목 제거 (같은 경로 중복 포함)
    static func dedupNested(_ items: [Candidate]) -> [Candidate] {
        let keys = items.map { key($0.path) }
        var seen = Set<String>()
        var out: [Candidate] = []
        for (i, c) in items.enumerated() {
            let k = keys[i]
            guard seen.insert(k).inserted else { continue }
            let nested = keys.enumerated().contains { j, other in j != i && other != k && k.hasPrefix(other + "/") }
            if !nested { out.append(c) }
        }
        return out
    }

    /// `.receipt` 항목을 꺼내 패키지 ID 목록으로 만든다 (`com.foo.pkg.bom` / `.plist` → `com.foo.pkg`).
    static func extractReceipts(_ items: inout [Candidate]) -> [String] {
        var ids: [String] = []
        items.removeAll { c in
            guard c.category == .receipt else { return false }
            let name = c.url.lastPathComponent
            var id = name
            for ext in [".bom", ".plist"] where id.hasSuffix(ext) { id = String(id.dropLast(ext.count)) }
            if SafeIdentifier.isValid(id), !SafeIdentifier.isApple(id), !ids.contains(id) { ids.append(id) }
            return true
        }
        return ids
    }

    /// 옮길 항목 경로와 같거나 그 아래에 있는 원래 후보 (통째로 옮기는 컨테이너 안의 정보까지 모으기 위해)
    static func coveredCandidates(_ all: [Candidate], by moved: [Candidate]) -> [Candidate] {
        let movedKeys = moved.map { key($0.path) }
        return all.flatMap(\.flattened).filter { c in
            guard c.isSelectable else { return false }
            let k = key(c.path)
            return movedKeys.contains { k == $0 || k.hasPrefix($0 + "/") }
        }
    }

    static func collectServices(_ items: [Candidate]) -> [LaunchServiceRef] {
        items.compactMap(\.launchService).filter { !SafeIdentifier.isApple($0.label) }
    }

    static func collectDomains(_ items: [Candidate]) -> [String] {
        var out: [String] = []
        for d in items.compactMap(\.preferencesDomain)
        where !out.contains(d) && SafeIdentifier.isValid(d) && !SafeIdentifier.isApple(d) {
            out.append(d)
        }
        return out
    }

    static func unique(_ services: [LaunchServiceRef]) -> [LaunchServiceRef] {
        var seen = Set<String>()
        return services.filter { seen.insert("\($0.domain.rawValue)/\($0.label)").inserted }
    }

    static func key(_ path: String) -> String { SafetyGuard.key(SafetyGuard.normalize(path)) }

    static func normalized(_ paths: Set<String>) -> Set<String> { Set(paths.map(key)) }
}
