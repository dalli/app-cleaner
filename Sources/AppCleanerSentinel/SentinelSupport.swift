import AppKit
import CleanerCore
import Foundation

/// 실행 인자 (개발·측정용 — 로그인 항목으로 실행될 때는 인자가 없다)
///
///   --log-only        알림 대신 표준 출력에 기록. 알림 권한을 묻지 않고 본 앱 설정에 상태를 쓰지 않는다
///   --watch-trash     설정과 관계없이 휴지통 감시
///   --trash <폴더>     감시할 폴더 (기본 ~/.Trash)
///   --scan-now        시작하자마자 정기 스캔 한 번
struct SentinelOptions {
    var logOnly = false
    var watchTrash = false
    var trashURL: URL?
    var scanNow = false

    init(arguments: [String]) {
        logOnly = arguments.contains("--log-only")
        watchTrash = arguments.contains("--watch-trash")
        scanNow = arguments.contains("--scan-now")
        if let i = arguments.firstIndex(of: "--trash"), i + 1 < arguments.count {
            trashURL = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
    }
}

/// UI 언어 (본 앱과 같은 규칙: 선호 언어 중 처음 지원하는 언어, 없으면 영어)
let sentinelLanguage: AppLanguage = .preferred(from: Locale.preferredLanguages)

/// 한국어 원문 키로 현재 언어의 문구 (`Localization/<언어>.lproj/Sentinel.strings`)
func S(_ key: String, _ args: any CVarArg...) -> String {
    SentinelStrings.format(key, args, language: sentinelLanguage)
}

enum SentinelFormat {
    static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// "11월 14일" / "Nov 14" / "11月14日"
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = sentinelLanguage.locale()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}

/// 시스템 설정 열기
enum SentinelSettingsURL {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
}

func sentinelLog(_ message: String) {
    FileHandle.standardOutput.write(Data("[Sentinel] \(message)\n".utf8))
}
