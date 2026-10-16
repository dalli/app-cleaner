import Foundation
import Testing

/// 배포 코드가 SwiftPM의 `Bundle.module`에 직접 기대지 않는지 (소스 검사).
///
/// 릴리즈 러너(Xcode 툴체인)가 만드는 `Bundle.module`은 `Bundle.main.bundleURL`(앱이면 `.app` 최상위)과 빌드 머신의
/// .build 경로만 찾는다. 리소스 번들은 `Contents/Resources`에 있으므로 배포한 앱·번들 CLI가 시작하자마자 종료됐다
/// (v0.1.1~v0.3.2). 로컬 Command Line Tools의 `Bundle.module`은 다른 위치도 찾아 로컬 빌드·테스트로는 드러나지 않는다.
/// 그래서 리소스는 `BundledResources`로 먼저 찾고, `.module`은 `swift test`·`swift run`용 대체 경로로만 둔다.
@Suite("Resource lookup guard")
struct ResourceLookupGuardTests {
    /// `.module`을 써도 되는 곳과 그 줄이 갖춰야 할 대체 경로 형태 — `BundledResources`로 못 찾았을 때만 쓴다
    static let allowed: [String: String] = [
        "Sources/AppCleanerGUI/Support/L10n.swift": "?? .module",
        "Sources/CleanerCore/Contracts/RuleData.swift": "return Bundle.module",
        "Sources/CleanerCore/Localization/Translations.swift": "return Bundle.module",
        "Sources/CleanerCore/Mover/PrivilegedScript.swift": "return Bundle.module",
    ]

    @Test func moduleBundleIsOnlyUsedAsFallback() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var violations: [String] = []
        var seen = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                guard code.range(of: #"\.module\b"#, options: .regularExpression) != nil else { continue }
                seen += 1
                if let form = Self.allowed[rel], code.contains(form) { continue }
                violations.append("\(rel):\(n + 1): \(code.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(violations.isEmpty, "Bundle.module 직접 사용 — BundledResources로 먼저 찾고 .module은 대체 경로로만: \(violations)")
        #expect(seen == Self.allowed.count)
    }
}
