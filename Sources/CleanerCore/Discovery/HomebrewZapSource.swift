import Foundation

/// Homebrew Cask `zap` 규칙 (plan.md 4.2 #2).
///
/// zap은 다른 앱과 공유하는 파일까지 지울 수 있는 규칙이므로 **최대 Medium**, 와일드카드로 찾은 경로는 **Low**.
/// 다른 정보원이 같은 경로를 독립적으로 찾으면 병합 시 그 정보원의 등급을 따른다 (`mergedByPath`).
/// 경로는 `~` → `paths.home`, `/` → `paths.root`로 바꾸고, 와일드카드는 부모 디렉토리를 나열해 `fnmatch`로 대조한다 (셸 미사용).
public struct HomebrewZapSource: CandidateSource {
    public let paths: SystemPaths
    public let rules: any RuleDataProviding

    public var sourceName: String { "homebrewZap" }

    /// 와일드카드 1개가 펼칠 수 있는 최대 항목 수
    static let maxExpansion = 200

    public init(paths: SystemPaths, rules: any RuleDataProviding) {
        self.paths = paths
        self.rules = rules
    }

    public func candidates(for identity: AppIdentity) throws -> [Candidate] {
        let data = rules.current()
        let bids = BundleIDMatcher(identity: identity)
        let categorizer = PathCategorizer(paths: paths)
        let fm = FileManager.default
        var out: [Candidate] = []
        for cask in matchingCasks(identity, data) {
            for zap in cask.zap {
                for (url, wildcard) in expand(zap, bundleIDs: bids.bundleIDs) where !url.isInside(identity.bundleURL) {
                    var c = categorizer.candidate(url, confidence: wildcard ? .low : .medium,
                                                  evidence: [Evidence(.homebrewZap, "Homebrew cask '\(cask.token)' zap 규칙: \(zap)")])
                    if !isLibraryOrDotfile(url) {
                        // `~/Documents/<App>` 같은 Library 밖 경로는 사용자 파일일 수 있다.
                        c.confidence = .low
                    }
                    out.append(c)
                }
            }
            // uninstall/zap `launchctl` Label → Launch plist
            for label in cask.bundleIDs where BundleIDRules.isSafeComponent(label) && bids.match(label) == nil {
                for dir in [paths.userLibrary.appendingPathComponent("LaunchAgents"),
                            paths.systemLibrary.appendingPathComponent("LaunchAgents"),
                            paths.systemLibrary.appendingPathComponent("LaunchDaemons")] {
                    let url = dir.appendingPathComponent("\(label).plist")
                    guard fm.itemExists(url) else { continue }
                    out.append(categorizer.candidate(url, confidence: .medium,
                                                     evidence: [Evidence(.homebrewZap, "Homebrew cask '\(cask.token)'의 launchctl 항목 \(label)")]))
                }
            }
        }
        return out.mergedByPath()
    }

    /// 설치 기록 토큰 → BID → 앱 파일명 순으로 cask를 찾는다.
    /// 앱 파일명만 같고 cask의 BID가 이 앱과 다르면 다른 앱이므로 쓰지 않는다.
    func matchingCasks(_ identity: AppIdentity, _ data: RuleData) -> [HomebrewCask] {
        if let token = identity.homebrewCask, let c = data.casks.first(where: { $0.token == token }) { return [c] }
        var seen = Set<String>()
        var found: [HomebrewCask] = []
        for bid in identity.allBundleIDs {
            for c in data.casks(matchingBundleID: bid) where seen.insert(c.token).inserted { found.append(c) }
        }
        if !found.isEmpty { return found }
        let bids = BundleIDMatcher(identity: identity)
        return data.casks(matchingAppName: identity.bundleURL.lastPathComponent).filter { c in
            c.bundleIDs.isEmpty || c.bundleIDs.contains { bids.match($0) != nil }
        }
    }

    // MARK: - 경로 펼치기

    /// zap 경로를 실제 존재하는 URL로 펼친다. (URL, 와일드카드로 찾았는지)
    /// `bundleIDs`: `<BID>*` 형태 와일드카드를 점 경계(`<BID>`/`<BID>.`)로 좁히는 데 쓴다.
    func expand(_ pattern: String, bundleIDs: [String] = []) -> [(URL, Bool)] {
        var results: [(URL, Bool)] = []
        var seen = Set<String>()
        for p in Self.expandBraces(pattern) {
            for r in expandGlob(p, bundleIDs: bundleIDs) where seen.insert(r.0.standardizedFileURL.path).inserted { results.append(r) }
        }
        return results
    }

    func expandGlob(_ pattern: String, bundleIDs: [String] = []) -> [(URL, Bool)] {
        let base: URL
        let rest: Substring
        if pattern.hasPrefix("~/") { base = paths.home; rest = pattern.dropFirst(2) }
        else if pattern.hasPrefix("/") { base = paths.root; rest = pattern.dropFirst(1) }
        else { return [] }
        let comps = rest.split(separator: "/").map(String.init)
        guard !comps.isEmpty, !comps.contains(".."), !comps.contains(".") else { return [] }

        let fm = FileManager.default
        var current = [base]
        var wildcard = false
        for (i, comp) in comps.enumerated() {
            if Self.isGlob(comp) {
                // `~/Library/Caches/*`처럼 카테고리 루트 전체를 덮는 패턴은 쓰지 않는다.
                if comp.allSatisfy({ $0 == "*" || $0 == "?" }) && i <= 2 { return [] }
                wildcard = true
                var next: [URL] = []
                for dir in current {
                    for child in fm.children(of: dir) where Self.fnmatch(comp, child.lastPathComponent)
                        && Self.respectsBundleIDBoundary(comp, child.lastPathComponent, bundleIDs) {
                        next.append(child)
                    }
                }
                guard next.count <= Self.maxExpansion else { return [] }
                current = next
            } else {
                current = current.map { $0.appendingPathComponent(comp) }
            }
            if current.isEmpty { return [] }
        }
        return current.filter { fm.itemExists($0) && isReasonableTarget($0) }.map { ($0, wildcard) }
    }

    /// 홈·루트·카테고리 루트 자체 같은 너무 넓은 경로는 후보로 만들지 않는다.
    func isReasonableTarget(_ url: URL) -> Bool {
        if let rel = url.relativePath(from: paths.home) {
            let c = rel.split(separator: "/")
            guard let first = c.first else { return false }
            if first == "Library" { return c.count >= 3 }
            return first.hasPrefix(".") ? !(c.count == 1 && (first == ".config" || first == ".local" || first == ".cache"))
                                        : c.count >= 2
        }
        if let rel = url.relativePath(from: paths.root) {
            let c = rel.split(separator: "/")
            guard let first = c.first else { return false }
            if first == "Applications" { return c.count >= 2 }
            return c.count >= 3 && !ReceiptSource.sharedDirectories.contains(rel)
        }
        return false
    }

    func isLibraryOrDotfile(_ url: URL) -> Bool {
        if let rel = url.relativePath(from: paths.home) {
            return rel.hasPrefix("Library/") || rel.hasPrefix(".")
        }
        return true
    }

    /// zap의 `com.foo.app*`는 `com.foo.appx`까지 잡는다. 접두사가 이 앱의 BID면 점 경계를 지키는 항목만 남긴다 (plan.md 3장).
    static func respectsBundleIDBoundary(_ pattern: String, _ name: String, _ bundleIDs: [String]) -> Bool {
        guard let star = pattern.firstIndex(of: "*") else { return true }
        let prefix = String(pattern[..<star])
        guard let bid = bundleIDs.first(where: { $0.caseInsensitiveCompare(prefix) == .orderedSame }) else { return true }
        return BundleIDRules.matches(name, bundleID: bid)
    }

    static func isGlob(_ s: String) -> Bool { s.contains("*") || s.contains("?") || s.contains("[") }

    static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        // FNM_PERIOD: `*`가 `.`으로 시작하는 숨김 항목을 잡지 않게 한다.
        Darwin.fnmatch(pattern, name, FNM_PERIOD) == 0
    }

    /// `{a,b}` 펼치기 (중첩 허용, 최대 64개)
    static func expandBraces(_ s: String) -> [String] {
        let chars = Array(s)
        guard let open = chars.firstIndex(of: "{") else { return [s] }
        var depth = 0
        var close: Int?
        var commas: [Int] = []
        for i in open..<chars.count {
            switch chars[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { close = i }
            case "," where depth == 1: commas.append(i)
            default: break
            }
            if close != nil { break }
        }
        guard let close, !commas.isEmpty else { return [s] }
        let prefix = String(chars[..<open])
        let suffix = String(chars[(close + 1)...])
        let bounds = [open] + commas + [close]
        var alternatives: [String] = []
        for k in 0..<(bounds.count - 1) { alternatives.append(String(chars[(bounds[k] + 1)..<bounds[k + 1]])) }
        var out: [String] = []
        for alt in alternatives {
            for e in expandBraces(prefix + alt + suffix) {
                out.append(e)
                if out.count >= 64 { return out }
            }
        }
        return out
    }
}
