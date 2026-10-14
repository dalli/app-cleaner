import Foundation

/// 앱 1개 검사 (plan.md 4.1~4.3, ui-ux.md S2).
///
/// 식별 → 앱 본체 후보 → 모든 정보원(병렬) → 경로 병합 → SafetyGuard → 데이터 성격 → SelectionPolicy → 크기 → 경고·안내.
/// 카테고리 루트만 나열하고 `~/Library` 전체를 재귀 탐색하지 않는다 (8.3: 2초 목표).
public struct AppScanner: AppScanning {
    public let paths: SystemPaths
    public let runner: any CommandRunning
    public let rules: any RuleDataProviding
    public let identityResolver: any IdentityResolving
    public let sources: [any CandidateSource]
    public let safety: any SafetyChecking
    public let classifier: any DataNatureClassifying
    public let policy: any SelectionPolicing
    public let isRunning: @Sendable (String) -> Bool
    public let hasFullDiskAccess: @Sendable () -> Bool

    static let mdfind = "/usr/bin/mdfind"
    static let systemextensionsctl = "/usr/bin/systemextensionsctl"

    public init(
        paths: SystemPaths,
        runner: any CommandRunning,
        rules: any RuleDataProviding,
        identityResolver: any IdentityResolving,
        sources: [any CandidateSource],
        safety: any SafetyChecking,
        classifier: any DataNatureClassifying,
        policy: any SelectionPolicing,
        isRunning: @escaping @Sendable (String) -> Bool,
        hasFullDiskAccess: @escaping @Sendable () -> Bool
    ) {
        self.paths = paths
        self.runner = runner
        self.rules = rules
        self.identityResolver = identityResolver
        self.sources = sources
        self.safety = safety
        self.classifier = classifier
        self.policy = policy
        self.isRunning = isRunning
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    /// 이 브랜치의 구현으로 조립한 기본 스캐너. `safety`에는 실제 조립 시 SafetyGuard를 넘긴다.
    public static func standard(
        paths: SystemPaths,
        runner: any CommandRunning,
        signatureReader: any CodeSignatureReading = SecCodeSignatureReader(),
        rules: any RuleDataProviding,
        safety: any SafetyChecking,
        isRunning: @escaping @Sendable (String) -> Bool = { _ in false },
        hasFullDiskAccess: @escaping @Sendable () -> Bool = { true }
    ) -> AppScanner {
        AppScanner(
            paths: paths,
            runner: runner,
            rules: rules,
            identityResolver: IdentityResolver(paths: paths, runner: runner, signatureReader: signatureReader, rules: rules),
            sources: standardSources(paths: paths, runner: runner, rules: rules),
            safety: safety,
            classifier: DataNatureClassifier(),
            policy: SelectionPolicy(paths: paths, rules: rules),
            isRunning: isRunning,
            hasFullDiskAccess: hasFullDiskAccess
        )
    }

    /// 경로 규칙 → Launch plist → 영수증 → Homebrew zap (병합 시 앞 정보원의 카테고리가 우선)
    public static func standardSources(paths: SystemPaths, runner: any CommandRunning, rules: any RuleDataProviding) -> [any CandidateSource] {
        [
            PathRuleSource(paths: paths, rules: rules),
            LaunchPlistSource(paths: paths),
            ReceiptSource(paths: paths, runner: runner),
            HomebrewZapSource(paths: paths, rules: rules),
        ]
    }

    // MARK: - 검사

    public func scan(appAt url: URL, inventory: InventorySnapshot?) async throws -> ScanReport {
        let identity = try identityResolver.resolve(appAt: url)

        var found = [appBundleCandidate(identity)]
        found += await collect(identity)
        var candidates = Self.removeCoveredDescendants(found.mergedByPath())
        candidates = applySafety(candidates, identity)
        candidates = candidates.map { classifier.classify($0) }
        candidates = policy.evaluate(candidates, for: identity, inventory: inventory)
        candidates = await FileStatsCalculator.fill(candidates)
        candidates = Self.deselectNestedSelections(candidates)
        candidates = Self.sorted(candidates)

        return ScanReport(
            identity: identity,
            candidates: candidates,
            warnings: warnings(identity, inventory: inventory),
            advisories: advisories(identity, candidates),
            ruleDataVersion: rules.current().version
        )
    }

    /// 앱 본체: High. `/Applications`에 있고 사용자가 쓸 수 없으면(root 소유) 시스템 도메인.
    func appBundleCandidate(_ identity: AppIdentity) -> Candidate {
        let fm = FileManager.default
        let bundle = identity.bundleURL
        let inSystemApps = bundle.isInside(paths.system("Applications"))
        let writable = fm.isWritableFile(atPath: bundle.path) && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
        return Candidate(url: bundle, category: .appBundle, domain: inSystemApps && !writable ? .system : .user,
                         confidence: .high, evidence: [Evidence(.bundleIdentifier, EngineText(.appBundle, identity.bundleID))])
    }

    /// 정보원을 병렬로 실행한다. 정보원 하나가 실패해도 나머지 결과는 유지한다.
    func collect(_ identity: AppIdentity) async -> [Candidate] {
        await withTaskGroup(of: (Int, [Candidate]).self) { group in
            for (i, source) in sources.enumerated() {
                group.addTask { (i, (try? source.candidates(for: identity)) ?? []) }
            }
            var results = [[Candidate]](repeating: [], count: sources.count)
            for await (i, list) in group { results[i] = list }
            return results.flatMap { $0 }
        }
    }

    /// 다른 후보 안에 있는 후보는, 그 상위 후보의 신뢰도가 같거나 높으면 뺀다 (상위를 옮기면 함께 옮겨짐).
    /// 상위가 더 낮은 경우(예: 벤더 공용 폴더 Low 안의 앱 폴더 Medium)는 둘 다 남긴다.
    static func removeCoveredDescendants(_ candidates: [Candidate]) -> [Candidate] {
        candidates.filter { c in
            !candidates.contains { other in c.url.isStrictlyInside(other.url) && other.confidence >= c.confidence }
        }
    }

    /// SafetyGuard 판정: 보호 경로·링크 우회는 제외, 그 밖의 차단 사유는 선택 불가로 남긴다.
    func applySafety(_ candidates: [Candidate], _ identity: AppIdentity) -> [Candidate] {
        candidates.compactMap { c in
            var c = c
            switch safety.verdict(for: c.url, bundleID: identity.bundleID) {
            case .allowed:
                return c
            case .blocked(let reason, let message):
                // 정보원이 이미 보호 사유를 붙인 항목(iCloud 등)은 안내용으로 남긴다.
                if c.protection == nil && (reason == .protectedPath || reason == .symlinkEscape) { return nil }
                c.protection = c.protection ?? reason
                // SafetyGuard 메시지는 진단용 평문이라 키 없이 남긴다 (GUI는 보호 사유 설명을 대신 보여 준다)
                let note = EngineText.verbatim(message)
                if !message.isEmpty && !c.notes.contains(note) { c.notes.append(note) }
                c.isSelected = false
                return c
            }
        }
    }

    /// 선택된 상위 후보가 있으면 하위 후보는 선택 해제 (같은 항목을 두 번 옮기지 않도록).
    static func deselectNestedSelections(_ candidates: [Candidate]) -> [Candidate] {
        let selected = candidates.filter(\.isSelected)
        return candidates.map { c in
            guard c.isSelected, let parent = selected.first(where: { c.url.isStrictlyInside($0.url) }) else { return c }
            var c = c
            c.isSelected = false
            let note = EngineText(.movedWithParent, parent.url.lastPathComponent)
            if !c.notes.contains(note) { c.notes.append(note) }
            return c
        }
    }

    static func sorted(_ candidates: [Candidate]) -> [Candidate] {
        let order = ItemCategory.DisplayGroup.allCases
        return candidates.enumerated().sorted { a, b in
            let ga = order.firstIndex(of: a.element.category.displayGroup) ?? 0
            let gb = order.firstIndex(of: b.element.category.displayGroup) ?? 0
            if ga != gb { return ga < gb }
            return a.element.url.path < b.element.url.path
        }.map(\.element)
    }

    // MARK: - 경고 (S2 상태 배너)

    func warnings(_ identity: AppIdentity, inventory: InventorySnapshot?) -> [ScanWarning] {
        var out: [ScanWarning] = []
        if identity.allBundleIDs.contains(where: isRunning) { out.append(.appRunning) }
        let copies = otherCopies(identity)
        if !copies.isEmpty { out.append(.otherCopies(copies)) }
        if !hasFullDiskAccess() { out.append(.noFullDiskAccess) }
        let unreadable = unreadableRoots()
        if !unreadable.isEmpty { out.append(.unreadable(unreadable)) }
        if inventory == nil { out.append(.inventoryUnavailable) }
        return out
    }

    /// 같은 BID를 가진 다른 앱 사본 (Spotlight — plan.md 4.2 "Spotlight의 역할")
    func otherCopies(_ identity: AppIdentity) -> [URL] {
        // 질의 문자열에 따옴표가 섞이지 않도록 BID 형태만 허용한다.
        guard BundleIDRules.looksLikeBundleID(identity.bundleID),
              let out = runner.output(Self.mdfind, ["kMDItemCFBundleIdentifier == '\(identity.bundleID)'"]) else { return [] }
        let target = identity.bundleURL.standardizedFileURL
        let targetResolved = target.resolvingSymlinksInPath()
        var seen = Set<String>()
        return out.lines.compactMap { line -> URL? in
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if url.isInside(target) || url.resolvingSymlinksInPath().isInside(targetResolved) { return nil }
            if url.isInside(paths.trash) { return nil }
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    /// 존재하지만 읽지 못한 카테고리 루트 (전체 디스크 접근 권한 부족 등)
    func unreadableRoots() -> [URL] {
        let fm = FileManager.default
        let roots = ["Containers", "Group Containers", "Application Support", "Caches", "Preferences", "LaunchAgents"]
            .map { paths.userLibrary.appendingPathComponent($0) }
        return roots.filter { fm.isDirectory($0) && (try? fm.contentsOfDirectory(atPath: $0.path)) == nil }
    }

    // MARK: - 안내 (S4 "직접 확인할 것")

    func advisories(_ identity: AppIdentity, _ candidates: [Candidate]) -> [Advisory] {
        var out: [Advisory] = [.loginItems, .keychain(searchTerm: identity.title)]
        for id in systemExtensions(identity) { out.append(.systemExtension(identifier: id)) }
        for c in candidates where c.category == .kernelExtension { out.append(.kernelExtension(path: c.url.path)) }
        if let token = identity.homebrewCask { out.append(.homebrewZap(token: token)) }
        return out
    }

    /// `systemextensionsctl list`에서 이 앱(BID) 또는 같은 Team ID·벤더의 확장
    func systemExtensions(_ identity: AppIdentity) -> [String] {
        guard let out = runner.output(Self.systemextensionsctl, ["list"]) else { return [] }
        let bids = BundleIDMatcher(identity: identity)
        let vendor = BundleIDRules.vendorPrefix(identity.bundleID)
        var found: [String] = []
        for line in out.lines {
            let tokens = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard let bid = tokens.first(where: { BundleIDRules.looksLikeBundleID($0) && $0.contains(".") && !$0.hasPrefix("[") })
            else { continue }
            let teamMatch = identity.teamID.map { tokens.contains($0) } ?? false
            let vendorMatch = vendor.map { bid.lowercased().hasPrefix($0 + ".") } ?? false
            if bids.match(bid) != nil || (teamMatch && vendorMatch), !found.contains(bid) { found.append(bid) }
        }
        return found
    }
}
