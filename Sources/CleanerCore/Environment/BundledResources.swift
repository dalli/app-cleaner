import Foundation

/// CleanerCore 리소스 번들(`AppCleaner_CleanerCore.bundle`) 안의 항목 찾기.
/// `.app`에서는 Contents/Resources, SwiftPM 실행 파일에서는 실행 파일 옆 번들을 본다.
/// Homebrew처럼 `bin/appcleaner -> libexec/appcleaner` 심볼릭 링크로 실행되면 링크가 있는 폴더가 아니라
/// 실제 실행 파일 폴더에 번들이 있으므로, 실행 파일 경로의 심볼릭 링크를 해석한 위치도 후보에 넣는다.
/// 앱 번들 안의 보조 실행 파일(`X.app/Contents/Helpers/appcleaner` — 번들 CLI, Sentinel 정기 스캔이 실행)은
/// 번들이 `X.app/Contents/Resources`에 있으므로 그 위치도 본다.
public enum BundledResources {
    public static let bundleName = "AppCleaner_CleanerCore.bundle"

    /// `relativePath`(예: "RuleData", "Scripts/privileged-op.sh") 후보 경로를 우선순위 순으로 나열한다.
    public static func candidates(_ relativePath: String, resourceURL: URL?, executableURL: URL?) -> [URL] {
        var out: [URL] = []
        func addBundle(in dir: URL) {
            let bundle = dir.appendingPathComponent(bundleName)
            out.append(bundle.appendingPathComponent(relativePath))
            out.append(bundle.appendingPathComponent("Contents/Resources").appendingPathComponent(relativePath))
        }
        if let res = resourceURL {
            addBundle(in: res)
            out.append(res.appendingPathComponent(relativePath))
        }
        func addAppResources(of exe: URL) {
            guard let resources = appResourcesDirectory(of: exe), resources.path != resourceURL?.path else { return }
            addBundle(in: resources)
        }
        if let exe = executableURL {
            addBundle(in: exe.deletingLastPathComponent())
            addAppResources(of: exe)
            let real = resolvingSymlinks(exe)
            if real.path != exe.path {
                addBundle(in: real.deletingLastPathComponent())
                addAppResources(of: real)
            }
        }
        return out
    }

    /// `X.app/Contents/<폴더>/실행 파일`이면 `X.app/Contents/Resources` (앱 본체·번들 CLI 모두)
    public static func appResourcesDirectory(of executable: URL) -> URL? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app" else { return nil }
        return contents.appendingPathComponent("Resources")
    }

    /// 이름으로 SwiftPM 리소스 번들(`AppCleaner_AppCleanerGUI.bundle` 등) 찾기 — resourceURL, 실행 파일 폴더,
    /// 앱의 Contents/Resources, 심볼릭 링크를 해석한 실행 파일 기준 순.
    ///
    /// 배포 코드는 SwiftPM의 `Bundle.module`보다 이것을 먼저 쓴다. 릴리즈 러너(Xcode 툴체인)가 만드는 `Bundle.module`은
    /// `Bundle.main.bundleURL`(앱이면 `.app` 최상위)과 빌드 머신의 .build만 찾아서, 배포한 앱·번들 CLI가
    /// 시작하자마자 종료됐다 (v0.1.1~v0.3.2). 로컬 Command Line Tools의 `Bundle.module`은 다른 위치도 찾아 드러나지 않았다.
    public static func bundleURL(named name: String, resourceURL: URL? = Bundle.main.resourceURL,
                                 executableURL: URL? = Bundle.main.executableURL,
                                 where exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        var dirs: [URL] = []
        if let res = resourceURL { dirs.append(res) }
        if let exe = executableURL {
            dirs.append(exe.deletingLastPathComponent())
            if let app = appResourcesDirectory(of: exe) { dirs.append(app) }
            let real = resolvingSymlinks(exe)
            if real.path != exe.path {
                dirs.append(real.deletingLastPathComponent())
                if let app = appResourcesDirectory(of: real) { dirs.append(app) }
            }
        }
        return dirs.map { $0.appendingPathComponent(name) }.first(where: exists)
    }

    /// 후보 중 `exists`를 만족하는 첫 경로
    public static func locate(_ relativePath: String, resourceURL: URL? = Bundle.main.resourceURL,
                              executableURL: URL? = Bundle.main.executableURL,
                              where exists: (URL) -> Bool) -> URL? {
        candidates(relativePath, resourceURL: resourceURL, executableURL: executableURL).first(where: exists)
    }

    /// realpath(3)로 모든 심볼릭 링크를 해석한 경로. 실패하면(파일 없음 등) 원래 경로.
    /// `URL.resolvingSymlinksInPath()`는 `/private` 접두를 임의로 떼는 등 실제 경로와 다를 수 있어 쓰지 않는다.
    public static func resolvingSymlinks(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
