import Foundation

/// CleanerCore 리소스 번들(`AppCleaner_CleanerCore.bundle`) 안의 항목 찾기.
/// `.app`에서는 Contents/Resources, SwiftPM 실행 파일에서는 실행 파일 옆 번들을 본다.
/// Homebrew처럼 `bin/appcleaner -> libexec/appcleaner` 심볼릭 링크로 실행되면 링크가 있는 폴더가 아니라
/// 실제 실행 파일 폴더에 번들이 있으므로, 실행 파일 경로의 심볼릭 링크를 해석한 위치도 후보에 넣는다.
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
        if let exe = executableURL {
            addBundle(in: exe.deletingLastPathComponent())
            let real = resolvingSymlinks(exe)
            if real.path != exe.path { addBundle(in: real.deletingLastPathComponent()) }
        }
        return out
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
