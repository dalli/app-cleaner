import CleanerCore
import Foundation

/// 릴리즈 빌드 확인용 (`scripts/package-release.sh`): `AppCleanerGUI --resource-check`
///
/// 창을 띄우지 않고 배포 앱이 리소스 번들(GUI 번역, CleanerCore 규칙 데이터·관리자 스크립트·번역)을 찾는지 확인해
/// 위치를 출력하고 종료한다 — 모두 찾으면 0, 하나라도 없으면 1. 실제 문구 조회까지 해 보므로 `Bundle.module`에 닿는
/// 코드가 남아 있으면 릴리즈 빌드에서는 여기서 바로 종료된다 (v0.1.1~v0.3.2의 배포 앱이 시작하자마자 종료됐던 원인).
enum ResourceCheck {
    static let flag = "--resource-check"

    static func run() -> Int32 {
        let fm = FileManager.default
        var ok = true
        func report(_ name: String, _ url: URL?) {
            print("\(name): \(url?.path ?? "없음")")
            if url == nil { ok = false }
        }
        report("GUI 번역 번들", BundledResources.bundleURL(named: L10n.bundleName))
        report("CleanerCore 규칙 데이터", BundledResources.locate("RuleData", where: { fm.isDirectory($0) }))
        report("CleanerCore 관리자 스크립트",
               BundledResources.locate("Scripts/\(PrivilegedScript.fileName)", where: { fm.fileExists(atPath: $0.path) }))
        report("CleanerCore 번역", BundledResources.locate(Translations.directoryName, where: { fm.isDirectory($0) }))
        // 실제 조회 (GUI 문구 표, 규칙 데이터 버전)
        print("문구: \(L("앱 제거")) · 규칙 데이터 \(BundledRuleData.load().version)")
        return ok ? 0 : 1
    }
}
