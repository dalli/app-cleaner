import Foundation

/// 4단계: 앱 단위 그룹화 (plan.md 4.5.6)
/// 그룹 키: BID → 같은 BID 접두사 → (Homebrew cask·설치 패키지) → Team ID → 이름 순으로 병합한다.
struct OrphanGrouper {
    let casks: [HomebrewCask]
    let caskZap: [(token: String, patterns: [ZapPattern])]

    init(casks: [HomebrewCask], caskRecords: [CaskRecord], paths: SystemPaths) {
        var merged: [String: HomebrewCask] = [:]
        for c in casks { merged[c.token] = c }
        for r in caskRecords {
            var c = merged[r.token] ?? HomebrewCask(token: r.token, names: [], apps: r.appNames, bundleIDs: r.bundleIDs, zap: r.zap)
            for b in r.bundleIDs where !c.bundleIDs.contains(b) { c.bundleIDs.append(b) }
            for z in r.zap where !c.zap.contains(z) { c.zap.append(z) }
            merged[r.token] = c
        }
        self.casks = merged.values.sorted { $0.token < $1.token }
        caskZap = self.casks.map { c in (c.token, c.zap.map { ZapPattern($0, paths: paths) }) }
    }

    struct Group {
        var items: [OrphanItem]
        var key: String
        var bundleID: String?
        var teamID: String?
        var caskToken: String?
        var displayName: String
        var nameIsGuess: Bool
    }

    /// Homebrew cask 데이터로 항목에 cask 토큰을 붙인다 (zap 경로 또는 BID 일치)
    func attachCasks(_ items: inout [OrphanItem]) {
        for i in items.indices where items[i].caskToken == nil {
            if let bid = items[i].bundleID,
               let c = casks.first(where: { $0.bundleIDs.contains { BundleIDHeuristics.isSameOrChild(bid, of: $0) } }) {
                items[i].caskToken = c.token
                continue
            }
            if let hit = caskZap.first(where: { $0.patterns.contains { $0.matches(items[i].url) } }) {
                items[i].caskToken = hit.token
            }
        }
    }

    func group(_ items: [OrphanItem]) -> [Group] {
        // 1) BID 루트: 다른 BID의 점 경계 접두사인 가장 짧은 BID (구성요소 3개 이상)
        let bids = Set(items.compactMap { $0.bundleID?.lowercased() })
        let sortedBIDs = bids.sorted { $0.count < $1.count }
        var rootOf: [String: String] = [:]
        for b in sortedBIDs {
            let root = sortedBIDs.first { r in r.split(separator: ".").count >= 3 && (b == r || b.hasPrefix(r + ".")) && rootOf[r] == r }
            rootOf[b] = root ?? b
        }

        // 2) 강한 키(BID 루트·cask·패키지)로 union-find
        var parent = Array(items.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }
        var firstByKey: [String: Int] = [:]
        var strong = Set<Int>()
        for (i, item) in items.enumerated() {
            var keys: [String] = []
            if let b = item.bundleID?.lowercased(), let r = rootOf[b] {
                keys.append("bid:" + r)
                keys.append("app:" + Self.appPrefix(of: b))
            }
            if let c = item.caskToken {
                keys.append("cask:" + c)
                // cask의 BID도 같은 키로 연결 (zap으로 붙은 이름 기반 항목 ↔ BID 항목)
                if let cask = casks.first(where: { $0.token == c }) {
                    for cb in cask.bundleIDs { keys.append("bid:" + (rootOf[cb.lowercased()] ?? cb.lowercased())) }
                }
            }
            if let p = item.packageID { keys.append("pkg:" + p) }
            if !keys.isEmpty { strong.insert(i) }
            for k in keys {
                if let j = firstByKey[k] { union(i, j) } else { firstByKey[k] = i }
            }
        }

        var clusters: [Int: [Int]] = [:]
        for i in strong { clusters[find(i), default: []].append(i) }
        var groups: [Group] = clusters.values.map { idx in makeGroup(idx.sorted().map { items[$0] }) }

        // 3) 약한 항목: Team ID → 이름 순으로 기존 그룹에 붙이거나 새 그룹
        for (i, item) in items.enumerated() where !strong.contains(i) {
            if let team = item.teamID {
                if let g = groups.firstIndex(where: { $0.teamID == team }) {
                    groups[g].items.append(item)
                } else {
                    groups.append(makeGroup([item]))
                }
                continue
            }
            if let name = item.name ?? item.appNameHint {
                let n = BundleIDHeuristics.normalizedName(name)
                let matches = groups.indices.filter { groupNames(groups[$0]).contains(n) }
                if matches.count == 1 {
                    groups[matches[0]].items.append(item)
                    continue
                }
            }
            groups.append(makeGroup([item]))
        }
        return groups.map { g in var g = g; refresh(&g); return g }
    }

    /// 그룹에 이름 기반 항목을 붙일 때 비교하는 이름들
    private func groupNames(_ g: Group) -> Set<String> {
        var names = Set<String>()
        names.insert(BundleIDHeuristics.normalizedName(g.displayName))
        for item in g.items {
            for n in [item.name, item.appNameHint].compactMap({ $0 }) { names.insert(BundleIDHeuristics.normalizedName(n)) }
        }
        if let c = g.caskToken, let cask = casks.first(where: { $0.token == c }) {
            for n in cask.names { names.insert(BundleIDHeuristics.normalizedName(n)) }
            for a in cask.apps { names.insert(BundleIDHeuristics.normalizedName(String(a.dropLast(a.hasSuffix(".app") ? 4 : 0)))) }
        }
        if let b = g.bundleID, let last = Self.meaningfulComponent(of: b) { names.insert(BundleIDHeuristics.normalizedName(last)) }
        names.remove("")
        return names
    }

    private func makeGroup(_ items: [OrphanItem]) -> Group {
        var g = Group(items: items, key: "", displayName: "", nameIsGuess: true)
        refresh(&g)
        return g
    }

    /// 그룹 키·BID·표시 이름 재계산
    private func refresh(_ g: inout Group) {
        let bids = g.items.compactMap(\.bundleID)
        let shortest = bids.min { $0.count < $1.count || ($0.count == $1.count && $0 < $1) }
        g.caskToken = g.items.compactMap(\.caskToken).sorted().first
        let cask = g.caskToken.flatMap { t in casks.first { $0.token == t } }
        g.bundleID = shortest ?? cask?.bundleIDs.first
        g.teamID = g.items.compactMap(\.teamID).sorted().first
        if let b = g.bundleID {
            g.key = "bid:" + b.lowercased()
        } else if let c = g.caskToken {
            g.key = "cask:" + c
        } else if let p = g.items.compactMap(\.packageID).sorted().first {
            g.key = "pkg:" + p
        } else if let t = g.teamID {
            g.key = "team:" + t
        } else {
            let n = g.items.compactMap { $0.name ?? $0.appNameHint }.first ?? g.items.first?.url.lastPathComponent ?? "?"
            g.key = "name:" + BundleIDHeuristics.normalizedName(n)
        }

        // 표시 이름: Homebrew cask 데이터 → 기록된 앱 경로 → 이름 기반 폴더명 → BID 추정 → Team ID
        if let name = cask?.names.first ?? cask?.apps.first.map({ String($0.dropLast($0.hasSuffix(".app") ? 4 : 0)) }) {
            g.displayName = name
            g.nameIsGuess = false
        } else if let hint = g.items.compactMap(\.appNameHint).first {
            g.displayName = hint
            g.nameIsGuess = false
        } else if let folder = g.items.compactMap(\.name).first {
            g.displayName = folder
            g.nameIsGuess = true
        } else if let b = g.bundleID, let comp = Self.meaningfulComponent(of: b) {
            g.displayName = comp.prefix(1).uppercased() + comp.dropFirst()
            g.nameIsGuess = true
        } else if let t = g.teamID {
            g.displayName = "개발자 \(t)"
            g.nameIsGuess = true
        } else {
            g.displayName = g.items.first?.url.lastPathComponent ?? "알 수 없음"
            g.nameIsGuess = true
        }
    }

    /// 같은 앱으로 볼 BID 접두사: 벤더 접두사 + 1 구성요소
    /// (`com.example.gone.agent`·`com.example.gone.helper` → `com.example.gone`, `com.google.Chrome`·`com.google.drivefs`는 다름)
    static func appPrefix(of bid: String) -> String {
        let parts = bid.lowercased().split(separator: ".").map(String.init)
        guard let vendor = BundleIDHeuristics.vendorPrefix(bid) else { return parts.joined(separator: ".") }
        let k = vendor.split(separator: ".").count + 1
        return parts.prefix(k).joined(separator: ".")
    }

    static let genericComponents: Set<String> = [
        "mac", "macos", "osx", "app", "desktop", "client", "agent", "helper", "daemon", "main", "release", "beta", "shipit",
    ]

    /// BID에서 앱 이름으로 쓸 만한 구성요소 (`com.tinyspeck.slackmacgap` → `slackmacgap`, `com.foo.Bar.mac` → `Bar`)
    static func meaningfulComponent(of bid: String) -> String? {
        let parts = bid.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        for p in parts.dropFirst(2).reversed() where !genericComponents.contains(p.lowercased()) && !p.allSatisfy(\.isNumber) {
            return p
        }
        return parts.count >= 2 ? parts[1] : nil
    }
}
