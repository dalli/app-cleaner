import Foundation

/// 번들 ID 모양·벤더 접두사 판정 (인벤토리·고아 스캔 공용, 모듈 내부)
enum BundleIDHeuristics {
    /// 첫 구성요소가 이 목록이면 점이 1개뿐이어도 BID로 본다 (예: `org.videolan`)
    static let reverseDNSRoots: Set<String> = [
        "com", "org", "net", "io", "de", "uk", "co", "me", "app", "dev", "jp", "fr", "ru", "cn", "kr", "ch", "nl", "se",
        "it", "eu", "us", "ca", "au", "info", "edu", "gov", "tv", "cc", "ai", "in", "at", "be", "dk", "no", "fi", "pl",
        "cz", "es", "br", "so", "sh", "ly", "to", "is", "xyz", "pro", "biz", "tech", "cloud", "group", "systemgroup",
    ]

    /// BID의 두 번째 구성요소가 이 목록이면 벤더가 아니라 호스팅·프레임워크이므로 세 번째까지 벤더로 본다.
    /// (plan.md 2.1 #4: `com.todesktop.*`은 ToDesktop 기반 모든 앱이 공유)
    static let genericHosts: Set<String> = [
        "github", "gitlab", "sourceforge", "googlecode", "bitbucket", "todesktop", "electron", "electronjs", "example",
    ]

    /// 파일 확장자로 흔한 것 — `foo.log` 같은 이름을 BID로 오인하지 않도록
    static let fileExtensions: Set<String> = [
        "log", "txt", "json", "plist", "db", "sqlite", "sqlite3", "lock", "pid", "tmp", "bak", "old", "cache", "dat", "xml",
        "app", "savedstate", "binarycookies", "zip", "gz", "dmg", "pkg",
    ]

    /// 역DNS 형태의 번들 ID처럼 보이는지
    static func isBundleIDShaped(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), !s.hasPrefix("."), !s.hasSuffix("."), !s.contains("..") else { return false }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        for p in parts where p.isEmpty || p.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        if fileExtensions.contains(parts.last!.lowercased()) { return false }
        // 숫자로만 된 구성요소가 많으면 버전 문자열 (예: 1.2.3)
        if parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        if parts.count >= 3 { return true }
        return reverseDNSRoots.contains(parts[0].lowercased())
    }

    /// 벤더 접두사 (소문자). `com.google.Chrome` → `com.google`, `com.github.foo.Bar` → `com.github.foo`
    static func vendorPrefix(_ bid: String) -> String? {
        let parts = bid.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        if genericHosts.contains(parts[1]) {
            return parts.count >= 4 ? parts.prefix(3).joined(separator: ".") : nil
        }
        return parts.prefix(2).joined(separator: ".")
    }

    /// 벤더 이름 (소문자). `com.google.Chrome` → `google`
    static func vendorName(_ bid: String) -> String? {
        vendorPrefix(bid).flatMap { $0.split(separator: ".").last.map(String.init) }
    }

    /// `a`가 `b` 자신이거나 `b.`로 시작하는지 (점 경계 — plan.md 3장)
    static func isSameOrChild(_ a: String, of b: String) -> Bool {
        let la = a.lowercased(), lb = b.lowercased()
        return la == lb || la.hasPrefix(lb + ".")
    }

    /// Team ID 접두 (`UBF8T346G9.Office` → `UBF8T346G9`)
    static func teamPrefix(_ s: String) -> String? {
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let head = s[..<dot]
        guard head.count == 10, head.allSatisfy({ ($0.isUppercase && $0.isASCII) || $0.isNumber }) else { return nil }
        return String(head)
    }

    /// 이름 비교용 정규화 (소문자, 공백·`-`·`_`·`.` 제거)
    static func normalizedName(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// UUID·호스트 ID처럼 보이는 구성요소 (ByHost 파일명의 마지막 부분)
    static func isHostIdentifier(_ s: String) -> Bool {
        s.count >= 12 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// `<BID>` 또는 `<BID>.`로 시작하는 BID를 소문자 집합에서 찾는다 (양방향).
    static func matchesAny(_ bid: String, in set: Set<String>) -> Bool {
        let lower = bid.lowercased()
        if set.contains(lower) { return true }
        // 항목이 설치 BID의 하위(`com.foo.app.ShipIt`)이거나 설치 BID가 항목의 하위(`com.foo.app` ← `com.foo.app.helper`)
        var parts = lower.split(separator: ".").map(String.init)
        while parts.count > 3 {
            parts.removeLast()
            if set.contains(parts.joined(separator: ".")) { return true }
        }
        return set.contains { $0.hasPrefix(lower + ".") }
    }
}

/// 외장 볼륨 경로 판정 (`/Volumes/<X>/…`)
public enum VolumePaths {
    /// `url`이 `<root>/Volumes/<X>/…` 아래면 볼륨 루트 `<root>/Volumes/<X>`
    public static func volumeRoot(of url: URL, paths: SystemPaths) -> URL? {
        let volumes = paths.system("Volumes").standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(volumes + "/") else { return nil }
        let rest = p.dropFirst(volumes.count + 1)
        guard let name = rest.split(separator: "/").first else { return nil }
        return paths.system("Volumes").appendingPathComponent(String(name), isDirectory: true)
    }

    /// 마운트 지점 디렉토리가 있으면 연결된 것으로 본다 (연결 해제 시 macOS가 마운트 지점을 지운다)
    public static let defaultIsMounted: @Sendable (URL) -> Bool = { FileManager.default.isDirectory($0) }
}

extension SystemPaths {
    /// plist 등에 기록된 절대 경로 문자열을 주입된 루트 기준 URL로 바꾼다.
    /// 실제 환경(root == "/")에서는 그대로이고, 픽스처에서는 `/Applications/…`를 가짜 루트 아래로 옮긴다.
    /// 이미 가짜 홈·루트 아래를 가리키는 경로는 그대로 둔다.
    func resolveRecorded(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        let rootPath = root.standardizedFileURL.path
        if rootPath == "/" { return url }
        let std = url.standardizedFileURL.path
        for base in [rootPath, home.standardizedFileURL.path, userCacheDir.standardizedFileURL.path,
                     userTempDir.standardizedFileURL.path] where std == base || std.hasPrefix(base + "/") {
            return url
        }
        return system(path)
    }
}

/// 수정일 조회 (심볼릭 링크를 따라가지 않는다)
enum FileDates {
    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 항목과 하위 항목(깊이·개수 제한)의 가장 최근 수정일. 최근 수정 강등(plan.md 4.5.4)용 — 크기 계산보다 훨씬 가볍다.
    static func latestModified(_ url: URL, maxDepth: Int = 3, maxEntries: Int = 2000) -> Date? {
        var latest = modified(url)
        let fm = FileManager.default
        guard fm.isDirectory(url), !isSymlink(url) else { return latest }
        var queue: [(URL, Int)] = [(url, 0)]
        var visited = 0
        while !queue.isEmpty && visited < maxEntries {
            let (dir, depth) = queue.removeFirst()
            for child in fm.children(of: dir) {
                visited += 1
                if let m = modified(child), latest.map({ m > $0 }) ?? true { latest = m }
                if depth + 1 < maxDepth, !isSymlink(child), fm.isDirectory(child) { queue.append((child, depth + 1)) }
                if visited >= maxEntries { break }
            }
        }
        return latest
    }

    static func isSymlink(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
