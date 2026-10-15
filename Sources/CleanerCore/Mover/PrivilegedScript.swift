import Foundation
import CryptoKit

/// 번들에 포함한 고정 스크립트 `Resources/Scripts/privileged-op.sh` (plan.md 5.3 MVP 방식)
public enum PrivilegedScript {
    public static let fileName = "privileged-op.sh"

    /// 스크립트의 SHA-256. 스크립트를 바꾸면 이 값도 바꿔야 한다 (`PrivilegedScriptTests`가 일치 여부를 검사).
    public static let sha256 = "5fdf1cc2aa8145e3c14bbe5562324489d85cc1a2b1081ead910a25cc78c9f52b"

    /// 권한 상승된 쪽에서 실행하는 고정 셸 코드. 인자: $1 = 스크립트 경로, $2 = 기대 해시, $3 = 작업 목록 파일.
    /// root 소유 임시 폴더(`/tmp`의 sticky 비트로 이름 바꾸기 불가)에 사본을 만들고 그 사본의 해시를 확인한 뒤 실행한다.
    /// 결과는 표준 출력의 줄로 전달하고 항상 0으로 끝나 `do shell script`가 출력을 버리지 않게 한다.
    public static let launcherShell = #"""
    set -eu
    d=$(/usr/bin/mktemp -d /tmp/appcleaner-op.XXXXXX)
    trap '/bin/rm -rf "$d"' EXIT
    /bin/cp -- "$1" "$d/op.sh"
    h=$(/usr/bin/shasum -a 256 "$d/op.sh")
    h=${h%% *}
    if [ "$h" != "$2" ]; then printf 'fail\t0\tscript-hash-mismatch\n'; exit 0; fi
    /bin/sh "$d/op.sh" batch "$3" || true
    """#

    /// `osascript -e …` 줄. 사용자 값은 모두 argv로만 들어오고 `quoted form of`로 감싼다 (소스 조립 없음).
    /// argv: 1 = 인증 창 안내 문구(`with prompt`, 현지화), 2 = 고정 셸 코드, 3… = 셸 코드 인자
    public static let appleScriptSource: [String] = [
        "on run argv",
        "set cmd to \"/bin/sh -c \" & quoted form of (item 2 of argv) & \" appcleaner-op\"",
        "repeat with i from 3 to (count of argv)",
        "set cmd to cmd & \" \" & quoted form of (item i of argv)",
        "end repeat",
        "return do shell script cmd with prompt (item 1 of argv) with administrator privileges without altering line endings",
        "end run",
    ]

    /// 관리자 인증 창 안내 문구 ("App Cleaner가 변경하려고 합니다." — macOS가 암호 입력 안내를 덧붙인다)
    public static func authorizationPrompt(_ language: AppLanguage = .current) -> String {
        EngineText(.adminPrompt).localized(language)
    }

    /// 번들 리소스 위치. `.app`에서는 Contents/Resources, SwiftPM 실행 파일에서는 실행 파일 옆 번들(심볼릭 링크 해석 포함),
    /// 둘 다 없으면 Bundle.module.
    public static func bundledURL(resourceURL: URL? = Bundle.main.resourceURL,
                                  executableURL: URL? = Bundle.main.executableURL) -> URL? {
        let fm = FileManager.default
        if let found = BundledResources.locate("Scripts/\(fileName)", resourceURL: resourceURL, executableURL: executableURL,
                                               where: { fm.fileExists(atPath: $0.path) }) { return found }
        return Bundle.module.url(forResource: "Scripts", withExtension: nil)?.appendingPathComponent(fileName)
    }

    public static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ url: URL, expected: String = sha256) -> Bool {
        guard let actual = sha256Hex(of: url) else { return false }
        return actual == expected.lowercased()
    }

    /// 스크립트 사유 코드 → 사용자 문구
    public static func reason(_ code: String) -> EngineText {
        switch code {
        case "outside-allowed-root": return EngineText(.adminOutsideAllowedRoot)
        case "dotdot", "bad-path", "not-absolute", "bad-restore-target": return EngineText(.adminBadPath)
        case "unsafe-parent": return EngineText(.adminUnsafeParent)
        case "bad-char": return EngineText(.adminBadChar)
        case "symlink": return EngineText(.adminSymlink)
        case "protected": return EngineText(.adminProtected)
        case "missing": return EngineText(.itemMissing)
        case "exists": return EngineText(.adminExists)
        case "bad-identifier": return EngineText(.adminBadIdentifier)
        case "bad-session": return EngineText(.adminBadSession)
        case "holding-unsafe": return EngineText(.adminHoldingUnsafe)
        case "script-hash-mismatch": return EngineText(.adminScriptTampered)
        case "auth-cancelled": return EngineText(.adminAuthCancelled)
        case "not-root": return EngineText(.adminNotRoot)
        case "launch-failed", "ops-file-failed", "helper-unavailable", "bad-request", "bad-version": return EngineText(.adminLaunchFailed)
        case "helper-no-reply": return EngineText(.adminNoResult)
        case "move-failed", "mkdir-failed", "chown-failed", "chmod-failed", "remove-failed": return EngineText(.adminFileOperationFailed)
        case "no-result": return EngineText(.adminNoResult)
        default:
            if code.hasPrefix("launchctl-") { return EngineText(.adminLaunchctlFailed, String(code.dropFirst(10))) }
            if code.hasPrefix("pkgutil-") { return EngineText(.adminPkgutilFailed, String(code.dropFirst(8))) }
            return EngineText(.adminFailed, code)
        }
    }

    /// 스크립트 사유 코드 → 한국어 문장
    public static func localizedReason(_ code: String) -> String { reason(code).text }
}
