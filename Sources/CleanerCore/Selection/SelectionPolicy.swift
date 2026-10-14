import Foundation

/// 신뢰도 × 공유 여부 × 데이터 성격 → 기본 선택 (plan.md 4.3, 앱 제거 흐름).
///
/// 공유 판정(4.3.2)은 `InventorySnapshot`에서 **대상 앱 자신을 뺀** 다른 앱을 기준으로 한다.
/// | 조건 | 처리 |
/// |---|---|
/// | Group Container를 다른 앱(내장 번들 포함)의 entitlements도 사용 | 공유 — 미선택, "Excel 외 1개 앱이 함께 사용 중" |
/// | Launch plist 실행 파일이 앱 번들 밖 + 같은 Team ID 앱 설치됨 | 공유 — 미선택 (벤더 공용 업데이터) |
/// | 벤더 공용 폴더 / `<TEAM>.` 접두 항목 + 같은 Team ID 앱 설치됨 | 공유 — 미선택 + 경고 |
/// | 위 항목인데 이 개발사의 마지막 앱 | 단독 — Medium으로 제시 |
/// | 인벤토리 없음 | 위 공유 판정 대상은 모두 미선택 |
///
/// 최종: `isSelected = protection == nil && confidence >= .medium && !share.isShared && nature.selectableByDefault`.
/// Medium은 선택 상태를 유지한다 (ui-ux.md 결정 #2). 컨테이너는 하위 항목이 모두 선택될 때만 자신도 선택된다.
public struct SelectionPolicy: SelectionPolicing {
    public let paths: SystemPaths
    public let rules: any RuleDataProviding

    public init(paths: SystemPaths, rules: any RuleDataProviding) {
        self.paths = paths
        self.rules = rules
    }

    enum Notes {
        static let inventoryUnknown = "설치된 앱 목록을 확인하기 전이라 다른 앱과 함께 쓰는지 판단하지 못해 기본 선택하지 않았습니다"
        static let lowName = "이름만 일치해 확실하지 않아 기본 선택하지 않았습니다"
        static let low = "신뢰도가 낮아 기본 선택하지 않았습니다"
        static let userData = "사용자 데이터가 들어 있어 기본 선택하지 않았습니다"
        static let synced = "iCloud에 동기화되는 데이터라 옮기지 않습니다 — 지우면 다른 기기에서도 사라집니다"
        static let lastOfVendor = "이 개발사의 마지막 앱이라 함께 정리합니다"
    }

    struct Context {
        var identity: AppIdentity
        var inventory: InventorySnapshot?
        /// 대상 앱을 제외한 인벤토리 앱
        var others: [InventoryApp]
        /// 같은 Team ID(또는 같은 BID 벤더 접두사)의 다른 앱
        var sameVendor: [InventoryApp]
        /// 이 앱의 것으로 확인된 위치 (앱 번들, BID로 찾은 항목) — Launch 실행 파일이 여기 있으면 외부가 아니다
        var internalRoots: [URL]
        var vendorFolders: Set<String>
    }

    public func evaluate(_ candidates: [Candidate], for identity: AppIdentity, inventory: InventorySnapshot?) -> [Candidate] {
        let others = inventory.map { inv in inv.apps.filter { !isTarget($0, identity) } } ?? []
        let ctx = Context(
            identity: identity,
            inventory: inventory,
            others: others,
            sameVendor: Self.sameVendorApps(others, identity),
            internalRoots: internalRoots(candidates, identity),
            vendorFolders: Set(rules.current().exclusions.vendorFolders.map { $0.lowercased() })
        )
        return candidates.map { evaluate($0, ctx) }
    }

    // MARK: - 후보 1개

    func evaluate(_ candidate: Candidate, _ ctx: Context) -> Candidate {
        var c = candidate
        var forceUnselected = false

        switch sharedJudgement(c, ctx) {
        case .none:
            break
        case .some(let kind):
            if ctx.inventory == nil {
                forceUnselected = true
                add(Notes.inventoryUnknown, to: &c)
            } else {
                judgeShare(&c, kind, ctx)
            }
        }

        c.isSelected = Self.defaultSelection(c) && !forceUnselected
        explain(&c)

        if !c.children.isEmpty {
            c.children = c.children.map { child in
                var ch = child
                ch.share = c.share
                ch.protection = ch.protection ?? c.protection
                ch.confidence = min(ch.confidence, c.confidence)
                ch.isSelected = Self.defaultSelection(ch) && !forceUnselected
                if ch.nature == .userData { add(Notes.userData, to: &ch) }
                return ch
            }
            // 하위 항목이 하나라도 남으면 컨테이너 자체는 옮기지 않는다 (선택된 하위 항목만 옮김).
            c.isSelected = c.isSelected && c.children.allSatisfy(\.isSelected)
        }
        return c
    }

    public static func defaultSelection(_ c: Candidate) -> Bool {
        c.protection == nil && c.confidence >= .medium && !c.share.isShared && c.nature.selectableByDefault
    }

    // MARK: - 공유 판정

    enum SharedKind {
        /// Group Container (`ownGroup`: 이 앱 entitlements에 있는 그룹인지)
        case groupContainer(group: String, ownGroup: Bool)
        /// 벤더 공용 폴더 또는 `<TEAM>.` 접두 항목
        case vendor(name: String)
        /// 실행 파일이 앱 밖에 있는 Launch plist
        case externalLaunch(executable: String)
    }

    func sharedJudgement(_ c: Candidate, _ ctx: Context) -> SharedKind? {
        let name = c.url.lastPathComponent
        // Group Container뿐 아니라 App Group 이름으로 찾은 다른 위치(`Application Scripts/<GROUP>` 등)도 같은 판정을 받는다.
        let matchedByGroupOnly = c.evidence.contains { $0.source == .appGroup }
            && !c.evidence.contains { $0.source == .bundleIdentifier || $0.source == .receipt }
        if c.category == .groupContainer || matchedByGroupOnly {
            let own = ctx.identity.appGroups.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            return .groupContainer(group: name, ownGroup: own)
        }
        if c.category == .launchAgent || c.category == .launchDaemon {
            if let exe = externalExecutable(c, ctx) { return .externalLaunch(executable: exe) }
            return nil
        }
        if c.evidence.contains(where: { $0.source == .teamIdentifier }) { return .vendor(name: name) }
        switch vendorFolderRelation(c.url, ctx) {
        case .folder(let vendor):
            return .vendor(name: vendor)
        case .inside(let vendor):
            // 벤더 폴더 안 항목은 이 앱 고유 근거(BID·이름·영수증)가 없을 때만 벤더 공용으로 본다.
            // 예: Homebrew zap의 `~/Library/Google/GoogleSoftwareUpdate` (Keystone)
            let weakOnly = c.evidence.allSatisfy { [.homebrewZap, .pathRule, .teamIdentifier].contains($0.source) }
            return weakOnly ? .vendor(name: vendor) : nil
        case .none:
            return nil
        }
    }

    func judgeShare(_ c: inout Candidate, _ kind: SharedKind, _ ctx: Context) {
        switch kind {
        case .groupContainer(let group, let own):
            let users = ctx.others.filter { app in app.appGroups.contains { $0.caseInsensitiveCompare(group) == .orderedSame } }
            if !users.isEmpty {
                let names = Self.uniqueNames(users)
                c.share = .shared(usedBy: names, reason: "같은 App Group(\(group))을 다른 앱도 사용")
                add(Self.usageNote(names), to: &c)
            } else if !own {
                // 이 앱 entitlements에 없는 `<TEAM>.` 그룹 — 벤더 공용 규칙
                judgeVendor(&c, ctx)
            }
        case .vendor:
            judgeVendor(&c, ctx)
        case .externalLaunch(let exe):
            if !ctx.sameVendor.isEmpty {
                let names = Self.uniqueNames(ctx.sameVendor)
                c.share = .shared(usedBy: names,
                                  reason: "실행 파일(\(exe))이 앱 밖에 있는 같은 개발사 공용 백그라운드 서비스")
                add(Self.usageNote(names, maybe: true) + " — 같은 개발사 공용 백그라운드 서비스", to: &c)
            }
        }
    }

    func judgeVendor(_ c: inout Candidate, _ ctx: Context) {
        if !ctx.sameVendor.isEmpty {
            let names = Self.uniqueNames(ctx.sameVendor)
            c.share = .shared(usedBy: names, reason: "같은 개발사의 다른 앱이 설치되어 있는 공용 항목")
            add(Self.usageNote(names, maybe: true) + " — 같은 개발사 공용 항목", to: &c)
        } else if c.confidence < .medium {
            // 이 개발사의 마지막 앱 → Medium으로 제시 (plan.md 4.3.2)
            c.confidence = .medium
            add(Notes.lastOfVendor, to: &c)
        }
    }

    enum VendorRelation {
        case folder(String)
        case inside(String)
    }

    /// 벤더 공용 폴더(`~/Library/<Vendor>`, `~/Library/<카테고리>/<Vendor>`, `/Library/…` 동일) 자체인지, 그 안인지
    func vendorFolderRelation(_ url: URL, _ ctx: Context) -> VendorRelation? {
        for lib in [paths.userLibrary, paths.systemLibrary] {
            guard let rel = url.relativePath(from: lib), !rel.isEmpty else { continue }
            let comps = rel.split(separator: "/").map(String.init)
            for i in 0..<min(2, comps.count) where ctx.vendorFolders.contains(comps[i].lowercased()) {
                return comps.count == i + 1 ? .folder(comps[i]) : .inside(comps[i])
            }
        }
        return nil
    }

    /// Launch plist의 실행 파일이 이 앱의 위치 밖이면 그 경로
    func externalExecutable(_ c: Candidate, _ ctx: Context) -> String? {
        guard let plist = LaunchPlist.read(at: c.url), let exe = plist.effectiveExecutable,
              let exeURL = paths.mapExternalPath(exe) else { return nil }
        if plist.points(into: ctx.identity.bundleURL) { return nil }
        if ctx.internalRoots.contains(where: { exeURL.isInside($0) }) { return nil }
        // `/Library/PrivilegedHelperTools/<BID>*` — 이 앱의 권한 헬퍼
        let helperDir = paths.systemLibrary.appendingPathComponent("PrivilegedHelperTools")
        if exeURL.isStrictlyInside(helperDir), let name = exeURL.relativePath(from: helperDir)?.split(separator: "/").first,
           BundleIDMatcher(identity: ctx.identity).match(String(name)) != nil {
            return nil
        }
        return exe
    }

    func internalRoots(_ candidates: [Candidate], _ identity: AppIdentity) -> [URL] {
        var roots = [identity.bundleURL]
        for c in candidates where c.confidence == .high && c.category != .launchAgent && c.category != .launchDaemon
            && c.category != .groupContainer
            && c.evidence.contains(where: { $0.source == .bundleIdentifier || $0.source == .receipt }) {
            roots.append(c.url)
        }
        return roots
    }

    func isTarget(_ app: InventoryApp, _ identity: AppIdentity) -> Bool {
        if app.bundleID.caseInsensitiveCompare(identity.bundleID) == .orderedSame { return true }
        let a = app.url.standardizedFileURL
        let b = identity.bundleURL.standardizedFileURL
        return a.path == b.path || a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    static func sameVendorApps(_ others: [InventoryApp], _ identity: AppIdentity) -> [InventoryApp] {
        let vendor = BundleIDRules.vendorPrefix(identity.bundleID)
        // Team ID가 같거나 BID 벤더 접두사(`com.google.`)가 같으면 같은 개발사로 본다 (보수적으로 합집합).
        return others.filter { app in
            if let team = identity.teamID, let t = app.teamID, t == team { return true }
            if let vendor { return app.bundleID.lowercased().hasPrefix(vendor + ".") }
            return false
        }
    }

    // MARK: - 사람이 읽는 설명 (ui-ux.md 4.3)

    func explain(_ c: inout Candidate) {
        if c.nature == .synced { add(Notes.synced, to: &c) }
        if c.nature == .userData { add(Notes.userData, to: &c) }
        if c.confidence == .low && c.protection == nil && !c.share.isShared {
            let nameOnly = !c.evidence.isEmpty && c.evidence.allSatisfy { $0.source == .name }
            add(nameOnly ? Notes.lowName : Notes.low, to: &c)
        }
    }

    func add(_ note: String, to c: inout Candidate) {
        if !c.notes.contains(note) { c.notes.append(note) }
    }

    static func uniqueNames(_ apps: [InventoryApp]) -> [String] {
        var seen = Set<String>()
        return apps.map(\.name).filter { seen.insert($0).inserted }
    }

    /// "Excel이 함께 사용 중" / "Excel 외 1개 앱이 함께 사용 중"
    static func usageNote(_ names: [String], maybe: Bool = false) -> String {
        let tail = maybe ? "함께 사용 중일 수 있습니다" : "함께 사용 중"
        guard let first = names.first else { return tail }
        if names.count == 1 { return "\(KoreanText.withSubjectParticle(first)) \(tail)" }
        return "\(first) 외 \(names.count - 1)개 앱이 \(tail)"
    }
}

/// 한국어 조사 처리
enum KoreanText {
    /// 받침 유무에 따라 "이"/"가"를 붙인다. 라틴 문자는 흔한 발음 규칙으로 추정한다.
    static func withSubjectParticle(_ word: String) -> String {
        word + (hasFinalConsonant(word) ? "이" : "가")
    }

    static func hasFinalConsonant(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let last = trimmed.unicodeScalars.last else { return false }
        let v = last.value
        if (0xAC00...0xD7A3).contains(v) { return (v - 0xAC00) % 28 != 0 }
        if let digit = Int(String(last)) { return [0, 1, 3, 6, 7, 8].contains(digit) }
        let lower = trimmed.lowercased()
        if lower.hasSuffix("me") || lower.hasSuffix("ne") { return true }
        return ["l", "m", "n"].contains(String(lower.last ?? " "))
    }
}
