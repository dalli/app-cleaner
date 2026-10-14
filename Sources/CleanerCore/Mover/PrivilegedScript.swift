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
    public static let appleScriptSource: [String] = [
        "on run argv",
        "set cmd to \"/bin/sh -c \" & quoted form of (item 1 of argv) & \" appcleaner-op\"",
        "repeat with i from 2 to (count of argv)",
        "set cmd to cmd & \" \" & quoted form of (item i of argv)",
        "end repeat",
        "return do shell script cmd with administrator privileges without altering line endings",
        "end run",
    ]

    /// 번들 리소스 위치. `.app`에서는 Contents/Resources, SwiftPM 실행 파일에서는 Bundle.module.
    public static func bundledURL() -> URL? {
        let fm = FileManager.default
        let bundleName = "AppCleaner_CleanerCore.bundle"
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent(bundleName).appendingPathComponent("Scripts/\(fileName)"))
            candidates.append(res.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources/Scripts/\(fileName)"))
            candidates.append(res.appendingPathComponent("Scripts/\(fileName)"))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent(bundleName).appendingPathComponent("Scripts/\(fileName)"))
            candidates.append(exeDir.appendingPathComponent(bundleName).appendingPathComponent("Contents/Resources/Scripts/\(fileName)"))
        }
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return found }
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
    public static func localizedReason(_ code: String) -> String {
        switch code {
        case "outside-allowed-root": return "관리자 권한으로 옮길 수 있는 위치가 아닙니다"
        case "dotdot", "bad-path", "not-absolute": return "경로 형식이 올바르지 않습니다"
        case "bad-char": return "지원하지 않는 문자가 포함된 경로입니다"
        case "symlink": return "경로에 심볼릭 링크가 있어 옮기지 않았습니다"
        case "protected": return "보호된 항목이라 옮기지 않았습니다"
        case "missing": return "항목을 찾을 수 없습니다"
        case "exists": return "같은 이름의 항목이 이미 있습니다"
        case "bad-identifier": return "레이블 또는 패키지 ID 형식이 올바르지 않습니다"
        case "bad-session": return "작업 기록 ID가 올바르지 않습니다"
        case "holding-unsafe": return "보류 폴더가 안전하지 않아 중단했습니다"
        case "script-hash-mismatch": return "관리자 작업 스크립트가 변조되어 실행하지 않았습니다"
        case "auth-cancelled": return "관리자 인증이 취소되었습니다"
        case "not-root": return "관리자 권한을 얻지 못했습니다"
        case "launch-failed", "ops-file-failed": return "관리자 작업을 시작하지 못했습니다"
        case "move-failed", "mkdir-failed", "chown-failed", "chmod-failed", "remove-failed": return "파일 작업에 실패했습니다"
        case "no-result": return "관리자 작업 결과를 받지 못했습니다"
        default:
            if code.hasPrefix("launchctl-") { return "launchctl 실행에 실패했습니다 (\(code.dropFirst(10)))" }
            if code.hasPrefix("pkgutil-") { return "pkgutil 실행에 실패했습니다 (\(code.dropFirst(8)))" }
            return "관리자 작업에 실패했습니다 (\(code))"
        }
    }
}
