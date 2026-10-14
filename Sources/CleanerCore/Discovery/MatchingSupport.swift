import Foundation

// 정보원·식별·판정이 함께 쓰는 매칭 규칙 (plan.md 3장 표기 규칙).
// - `<BID>*` = `<BID>` 자체 또는 `<BID>.`로 시작 — 점 경계 없는 접두사 매칭은 하지 않는다.
// - `<NAME>` = 대소문자 무시 **정확 일치**만 — 부분 문자열 매칭은 하지 않는다.

/// 번들 ID 문자열 검사
public enum BundleIDRules {
    /// 경로 구성요소로 써도 안전한지 (`/`, `..`, 제어 문자 금지)
    public static func isSafeComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s != ".", s != "..", !s.contains("/"), !s.contains("\0") else { return false }
        return !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 역도메인 형태 (`com.example.app`) — 영숫자·`-`·`_`로 된 구성요소 2개 이상
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, s.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }
    }

    /// `entry`가 `bid` 자체이거나 `bid.`로 시작하는지 (대소문자 무시)
    public static func matches(_ entry: String, bundleID bid: String) -> Bool {
        let e = entry.lowercased()
        let b = bid.lowercased()
        return e == b || e.hasPrefix(b + ".")
    }

    /// 벤더 접두사 (`com.google.Chrome` → `com.google`)
    public static func vendorPrefix(_ bid: String) -> String? {
        let parts = bid.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        return parts.prefix(2).joined(separator: ".")
    }
}

/// 대상 앱의 BID 목록에 대한 매처
struct BundleIDMatcher: Sendable {
    /// 매칭에 쓰는 BID (경로로 쓸 수 없는 값은 제외)
    let bundleIDs: [String]
    let mainBundleID: String

    init(identity: AppIdentity) {
        mainBundleID = identity.bundleID
        bundleIDs = identity.allBundleIDs.filter(BundleIDRules.isSafeComponent)
    }

    /// 매칭된 BID (가장 긴 것 — 내장 BID가 본체 BID의 하위일 때 더 구체적인 근거를 남긴다)
    func match(_ entryName: String) -> String? {
        bundleIDs.filter { BundleIDRules.matches(entryName, bundleID: $0) }.max { $0.count < $1.count }
    }

    /// 내장 번들 BID가 본체와 같은 벤더가 아니면(서드파티 프레임워크 등) 한 단계 낮춘다.
    func confidence(forMatched bid: String) -> Confidence {
        if bid.lowercased() == mainBundleID.lowercased() || BundleIDRules.matches(bid, bundleID: mainBundleID) { return .high }
        if let v = BundleIDRules.vendorPrefix(mainBundleID), bid.lowercased().hasPrefix(v + ".") { return .high }
        return .medium
    }
}

/// `<NAME>` 대소문자 무시 정확 일치
struct NameMatcher: Sendable {
    let names: [String]
    let rules: RuleData

    init(identity: AppIdentity, rules: RuleData) {
        self.names = identity.candidateNames.filter { BundleIDRules.isSafeComponent($0) && !$0.hasPrefix(".") }
        self.rules = rules
    }

    func match(_ entryName: String) -> String? {
        names.first { $0.caseInsensitiveCompare(entryName) == .orderedSame }
    }

    /// 이름 매칭의 신뢰도 — 짧거나 흔한 이름이면 Low (plan.md 4.3.1)
    func confidence(for name: String) -> Confidence { rules.isWeakName(name) ? .low : .medium }

    /// 진단 리포트 `<NAME>[-_]*`
    func matchDiagnostic(_ entryName: String) -> String? {
        let e = entryName.lowercased()
        return names.first { n in
            let l = n.lowercased()
            return e.hasPrefix(l + "-") || e.hasPrefix(l + "_")
        }
    }
}

extension SystemPaths {
    /// 외부 데이터(launchd plist, pkgutil, Homebrew zap)에 적힌 절대 경로를 이 환경의 URL로 바꾼다.
    /// `~` → `home`, `/` → `root`. 실제 환경(`root == /`)에서는 그대로다.
    func mapExternalPath(_ path: String) -> URL? {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        guard path.hasPrefix("/") else { return nil }
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" { return URL(fileURLWithPath: path) }
        // 이미 픽스처 트리 안을 가리키는 경로면 그대로 둔다.
        for base in [home, root, userCacheDir, userTempDir] {
            let b = base.standardizedFileURL.path
            if path == b || path.hasPrefix(b + "/") { return URL(fileURLWithPath: path) }
        }
        return system(path)
    }

    /// 이 환경의 URL을 외부 명령(pkgutil 등)에 넘길 절대 경로로 바꾼다 (`root` 기준).
    func logicalPath(of url: URL) -> String {
        let p = url.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        if r == "/" { return p }
        if p == r { return "/" }
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count)) }
        return p
    }
}

extension URL {
    /// `self`가 `ancestor` 자신이거나 그 하위인지 (표준화된 경로 기준)
    func isInside(_ ancestor: URL) -> Bool {
        let p = standardizedFileURL.path
        let a = ancestor.standardizedFileURL.path
        return p == a || p.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    /// `ancestor`의 엄격한 하위인지
    func isStrictlyInside(_ ancestor: URL) -> Bool {
        let p = standardizedFileURL.path
        let a = ancestor.standardizedFileURL.path
        return p != a && p.hasPrefix(a.hasSuffix("/") ? a : a + "/")
    }

    /// `ancestor` 기준 상대 경로 (하위가 아니면 nil)
    func relativePath(from ancestor: URL) -> String? {
        let p = standardizedFileURL.path
        let a = ancestor.standardizedFileURL.path
        if p == a { return "" }
        let prefix = a.hasSuffix("/") ? a : a + "/"
        guard p.hasPrefix(prefix) else { return nil }
        return String(p.dropFirst(prefix.count))
    }
}

extension FileManager {
    /// 심볼릭 링크인지 (링크를 따라가지 않음)
    func isSymlink(_ url: URL) -> Bool {
        (try? attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
