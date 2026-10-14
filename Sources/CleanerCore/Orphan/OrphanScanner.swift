import Foundation

/// 고아 잔여물 스캔 (plan.md 4.5). 앱을 지정하지 않고 "설치 앱 인벤토리"와 "잔여물 후보"를 대조한다.
///
/// 흐름: 인벤토리 → 카테고리 루트 수집(+ 영수증·Homebrew·dotfile) → 기본 판정 → 그룹화·승격 →
/// 강등(Spotlight·최근 수정·같은 벤더) → 데이터 성격·SafetyGuard → 기본 선택 → 유지 목록·최소 신뢰도 → 크기
public struct OrphanScanner: OrphanScanning {
    public let paths: SystemPaths
    private let runner: CommandRunning
    private let inventory: InventoryProviding
    private let rules: RuleDataProviding
    private let safety: SafetyChecking
    private let classifier: DataNatureClassifying
    private let keepList: KeepListStoring
    private let launchServices: LaunchServicesLookup
    private let isMounted: @Sendable (URL) -> Bool
    private let now: @Sendable () -> Date
    /// `useCachedInventory`일 때 이 시간보다 오래된 캐시는 쓰지 않고 다시 구축한다
    private let inventoryCacheMaxAge: TimeInterval
    /// 결과를 보낸 뒤 크기를 계산해 최종 보고서에 채운다 (plan.md 8.3)
    private let computeSizes: Bool

    public init(
        paths: SystemPaths,
        runner: CommandRunning,
        inventory: InventoryProviding,
        rules: RuleDataProviding,
        safety: SafetyChecking,
        classifier: DataNatureClassifying,
        keepList: KeepListStoring,
        launchServices: @escaping LaunchServicesLookup = LaunchServicesRegistry.live,
        isMounted: @escaping @Sendable (URL) -> Bool = VolumePaths.defaultIsMounted,
        now: @escaping @Sendable () -> Date = { Date() },
        inventoryCacheMaxAge: TimeInterval = 300,
        computeSizes: Bool = true
    ) {
        self.paths = paths
        self.runner = runner
        self.inventory = inventory
        self.rules = rules
        self.safety = safety
        self.classifier = classifier
        self.keepList = keepList
        self.launchServices = launchServices
        self.isMounted = isMounted
        self.now = now
        self.inventoryCacheMaxAge = inventoryCacheMaxAge
        self.computeSizes = computeSizes
    }

    public func scan(options: OrphanScanOptions, progress: @escaping @Sendable (OrphanScanEvent) -> Void) async throws -> OrphanScanReport {
        let started = Date()
        let ruleData = rules.current()

        // 1. 인벤토리
        progress(.phase(.buildingInventory))
        let snapshot: InventorySnapshot
        if options.useCachedInventory, let cached = inventory.cached(),
           now().timeIntervalSince(cached.builtAt) < inventoryCacheMaxAge, standardAppsUnchanged(since: cached) {
            snapshot = cached
        } else {
            snapshot = try await inventory.build()
        }
        try Task.checkCancellation()

        // 2. 후보 수집 (+ 기본 판정)
        progress(.phase(.collectingCandidates))
        let index = InventoryIndex(snapshot: snapshot, paths: paths, launchServices: launchServices, isMounted: isMounted)
        let exclusions = ExclusionRules(exclusions: ruleData.exclusions, paths: paths)
        let collector = OrphanCollector(paths: paths, runner: runner, index: index, rules: ruleData, exclusions: exclusions,
                                        options: options, isMounted: isMounted)
        let (rootItems, unreadable) = collector.collectRoots()
        var items = rootItems
        items += collector.collectDotfiles()
        items += collector.collectHomebrew()
        try Task.checkCancellation()
        items += await collector.collectReceipts()
        items = Self.mergeByPath(items)
        try Task.checkCancellation()

        // 3. 판정 (그룹화·승격·강등)
        progress(.phase(.judging))
        let grouper = OrphanGrouper(casks: ruleData.casks, caskRecords: Caskroom.records(paths: paths, fallback: ruleData.casks),
                                    paths: paths)
        grouper.attachCasks(&items)
        var groups = grouper.group(items)
        let spotlightReliable = snapshot.spotlight.isReliable
        let currentDate = now()
        for g in groups.indices {
            adjust(&groups[g], index: index, spotlightReliable: spotlightReliable, now: currentDate, options: options)
        }

        // 4. 후보 변환·데이터 성격·안전 검사·기본 선택
        var result: [OrphanGroup] = groups.compactMap { makeOrphanGroup($0) }

        // 5. 유지 목록·최소 신뢰도
        let (visible, hidden) = Self.applyKeepList(result, entries: keepList.entries())
        result = visible.compactMap { Self.filter($0, minimum: options.minimumConfidence) }
        result.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for g in result { progress(.groupFound(g)) }

        // 6. 크기 (결과를 먼저 보낸 뒤 계산)
        if computeSizes {
            for i in result.indices {
                try Task.checkCancellation()
                result[i].items = await FileStatsCalculator.fill(result[i].items)
            }
        }
        progress(.phase(.finished))

        var warnings: [ScanWarning] = []
        if !unreadable.isEmpty { warnings.append(.unreadable(unreadable)) }
        return OrphanScanReport(groups: result, spotlight: snapshot.spotlight, inventoryAppCount: snapshot.apps.count,
                                duration: Date().timeIntervalSince(started), hiddenByKeepList: hidden, warnings: warnings,
                                ruleDataVersion: ruleData.version, scannedAt: currentDate)
    }

    /// 캐시 이후 표준 위치에 앱이 설치·삭제되지 않았는지 (새로 설치한 앱의 데이터를 고아로 오판하지 않도록)
    private func standardAppsUnchanged(since snapshot: InventorySnapshot) -> Bool {
        let roots = [paths.system("Applications"), paths.home("Applications"), paths.system("System/Applications"),
                     paths.system("System/Library/CoreServices")]
        let current = Set(roots.flatMap { AppInventory.findApps(in: $0) }.map(\.standardizedFileURL.path))
        let cached = Set(snapshot.apps.map(\.url.standardizedFileURL.path))
        guard current.isSubset(of: cached) else { return false }
        let cachedStandard = cached.filter { p in roots.contains { AppInventory.isInside(URL(fileURLWithPath: p), $0) } }
        return cachedStandard.isSubset(of: current) && snapshot.apps.allSatisfy { FileManager.default.itemExists($0.url) }
    }

    // MARK: - 판정 조정

    /// 승격(같은 앱의 High 근거) → Spotlight 강등 → 최근 수정 강등 → 같은 벤더 강등 → 외장 볼륨 Low 고정
    private func adjust(_ g: inout OrphanGrouper.Group, index: InventoryIndex, spotlightReliable: Bool, now: Date,
                        options: OrphanScanOptions) {
        let hasHigh = g.items.contains { $0.confidence == .high && !$0.offline }
        for i in g.items.indices {
            var item = g.items[i]
            if hasHigh && item.confidence == .medium && !item.offline {
                item.confidence = .high
                item.promoted = true
                item.evidence.append(Evidence(.inventory, "같은 앱의 다른 항목에서 높은 근거 발견"))
            }
            if !spotlightReliable && item.confidence == .medium {
                item.confidence = .low
                item.addNote("Spotlight 색인이 불완전해 신뢰도를 낮춤")
            }
            if item.category != .receipt && !(item.category == .other && item.caskToken != nil) {
                item.lastModified = FileDates.latestModified(item.url)
                if let m = item.lastModified, options.recentModificationWindow > 0,
                   now.timeIntervalSince(m) < options.recentModificationWindow {
                    item.confidence = item.confidence.demoted()
                    item.addNote("최근에 수정됨 — 아직 사용 중일 수 있음")
                }
            } else {
                item.lastModified = FileDates.modified(item.url)
            }
            var vendorApps: [String] = []
            if let b = item.bundleID { vendorApps = index.installedVendorApps(for: b) }
            if vendorApps.isEmpty, let t = item.teamID { vendorApps = index.teams[t] ?? [] }
            if !vendorApps.isEmpty {
                item.confidence = item.confidence.demoted()
                item.addNote("같은 개발사의 앱(\(Self.list(vendorApps)))이 설치되어 있음")
            }
            if item.offline {
                item.confidence = .low
                item.addNote("앱이 외장 볼륨에 있을 수 있음")
            }
            g.items[i] = item
        }
    }

    private static func list(_ names: [String]) -> String {
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.count <= 2 ? unique.joined(separator: ", ") : "\(unique[0]) 외 \(unique.count - 1)개"
    }

    // MARK: - 후보 변환

    private func makeOrphanGroup(_ g: OrphanGrouper.Group) -> OrphanGroup? {
        var candidates: [Candidate] = []
        for item in g.items {
            // 영수증은 이동하지 않고 `pkgutil --forget`으로 처리하므로 경로 보호 목록(/private/var/db)을 거치지 않는다
            if item.category != .receipt {
                guard safety.verdict(for: item.url, bundleID: item.bundleID).isAllowed else { continue }
            }
            var c = Candidate(
                url: item.url.standardizedFileURL, category: item.category, domain: item.domain, confidence: item.confidence,
                share: item.share, evidence: item.evidence, lastModified: item.lastModified,
                launchService: item.launchService, preferencesDomain: item.preferencesDomain, notes: item.notes
            )
            c = classifier.classify(c)
            c = Self.applySelection(c)
            candidates.append(c)
        }
        guard !candidates.isEmpty else { return nil }
        let confidence = candidates.map(\.confidence).max() ?? .low
        let sharedUsers = candidates.flatMap(\.share.usedBy).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let share: ShareStatus = sharedUsers.isEmpty ? .exclusive
            : .shared(usedBy: sharedUsers, reason: "같은 개발사의 앱이 설치되어 있음")
        var notes: [String] = []
        if g.items.contains(where: \.offline) { notes.append("앱이 외장 볼륨에 있을 수 있음") }
        if g.items.contains(where: { $0.notes.contains("Spotlight 색인이 불완전해 신뢰도를 낮춤") }) {
            notes.append("Spotlight 색인이 불완전해 일부 항목의 신뢰도를 낮춤")
        }
        var advisories: [Advisory] = []
        for token in Set(g.items.filter { $0.category == .other }.compactMap(\.caskToken)).sorted() {
            advisories.append(.homebrewZap(token: token))
            notes.append("Homebrew 기록만 남아 있음 — brew uninstall --zap --cask \(token) 권장")
        }
        return OrphanGroup(id: g.key, displayName: g.displayName, nameIsGuess: g.nameIsGuess, bundleID: g.bundleID,
                           teamID: g.teamID, items: candidates, confidence: confidence, share: share, notes: notes,
                           advisories: advisories)
    }

    /// 고아 스캔 기본 선택: High + 선택 가능한 데이터 성격 + 비공유 + 보호 아님 (Medium은 선택하지 않음 — plan.md 4.5.4)
    static func applySelection(_ c: Candidate) -> Candidate {
        var c = c
        c.isSelected = c.confidence == .high && c.nature.selectableByDefault && !c.share.isShared && c.protection == nil
        c.children = c.children.map { child in
            var child = child
            child.confidence = min(child.confidence, c.confidence)
            child.isSelected = child.confidence == .high && child.nature.selectableByDefault && !child.share.isShared
                && child.protection == nil && !c.share.isShared && c.protection == nil
            return applySelectionToDescendants(child)
        }
        return c
    }

    private static func applySelectionToDescendants(_ c: Candidate) -> Candidate {
        var c = c
        c.children = c.children.map { child in
            var child = child
            child.confidence = min(child.confidence, c.confidence)
            child.isSelected = child.confidence == .high && child.nature.selectableByDefault && !child.share.isShared
                && child.protection == nil
            return applySelectionToDescendants(child)
        }
        return c
    }

    // MARK: - 병합·필터

    /// 같은 경로를 여러 경로(카테고리 루트·영수증)로 찾은 경우 병합
    static func mergeByPath(_ items: [OrphanItem]) -> [OrphanItem] {
        var order: [String] = []
        var byPath: [String: OrphanItem] = [:]
        for item in items {
            let key = item.standardizedPath
            guard var existing = byPath[key] else {
                order.append(key)
                byPath[key] = item
                continue
            }
            existing.confidence = max(existing.confidence, item.confidence)
            for e in item.evidence where !existing.evidence.contains(e) { existing.evidence.append(e) }
            for n in item.notes { existing.addNote(n) }
            existing.bundleID = existing.bundleID ?? item.bundleID
            existing.teamID = existing.teamID ?? item.teamID
            existing.name = existing.name ?? item.name
            existing.appNameHint = existing.appNameHint ?? item.appNameHint
            existing.caskToken = existing.caskToken ?? item.caskToken
            existing.packageID = existing.packageID ?? item.packageID
            existing.launchService = existing.launchService ?? item.launchService
            existing.preferencesDomain = existing.preferencesDomain ?? item.preferencesDomain
            existing.offline = existing.offline && item.offline
            byPath[key] = existing
        }
        return order.compactMap { byPath[$0] }
    }

    /// 유지 목록: 그룹 키 또는 항목 경로가 일치하면 숨긴다. 숨긴 그룹·항목 수를 함께 돌려준다.
    static func applyKeepList(_ groups: [OrphanGroup], entries: [KeepEntry]) -> ([OrphanGroup], Int) {
        let groupKeys = Set(entries.filter { $0.kind == .group }.map(\.key))
        let itemPaths = Set(entries.filter { $0.kind == .item }.map { URL(fileURLWithPath: $0.key).standardizedFileURL.path })
        var hidden = 0
        var out: [OrphanGroup] = []
        for var g in groups {
            if groupKeys.contains(g.id) {
                hidden += 1
                continue
            }
            let before = g.items.count
            g.items.removeAll { itemPaths.contains($0.url.standardizedFileURL.path) }
            hidden += before - g.items.count
            guard !g.items.isEmpty else { continue }
            g.confidence = g.items.map(\.confidence).max() ?? .low
            out.append(g)
        }
        return (out, hidden)
    }

    static func filter(_ group: OrphanGroup, minimum: Confidence) -> OrphanGroup? {
        var g = group
        g.items = g.items.filter { $0.confidence >= minimum }
        guard !g.items.isEmpty else { return nil }
        g.confidence = g.items.map(\.confidence).max() ?? .low
        return g
    }
}
