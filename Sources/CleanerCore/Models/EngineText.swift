import Foundation

/// 엔진이 만드는 사람이 읽는 문구 (판정 근거·메모·공유 사유).
///
/// 문장 대신 안정된 키와 인자로 들고 다닌다. `text`는 한국어 기본 문장(저장·JSON용)이고,
/// GUI·CLI는 `localized(_:)`로 선택한 언어의 문장을 만든다 — 번역은 CleanerCore 리소스
/// `Localization/<언어>.lproj/Engine.strings`에 키(`key.rawValue`)로 있다.
/// 키가 없는 문구(예전 삭제 기록의 공유 사유, 시스템 오류 설명)는 `verbatim`으로 감싼다.
///
/// JSON: 키 문구는 `{"key", "args", "text"}` (+ 안에 든 문구가 있으면 `parts`), `verbatim`은 평문 문자열.
/// 평문 문자열도 읽을 수 있어 이전 버전 기록(`reason: "…"`)이 그대로 열린다. `text`는 언어와 무관하게 항상 한국어다.
public struct EngineText: Sendable, Hashable, CustomStringConvertible {
    public var key: Key
    /// 형식 문자열의 `%@`를 차례로 채우는 값 (번들 ID, 경로, 앱 이름 등 — 번역하지 않는다)
    public var args: [String]
    /// 문장 안에 들어가는 다른 엔진 문구. `args` 다음 `%@` 자리에 같은 언어로 만든 문장이 차례로 들어간다.
    /// 예: `.holdingMoveFailed` + `.adminAuthCancelled` → "보류 폴더로 옮기지 못했습니다: 관리자 인증이 취소되었습니다"
    public var parts: [EngineText]

    public init(_ key: Key, _ args: String..., parts: [EngineText] = []) {
        self.init(key, args: args, parts: parts)
    }

    public init(_ key: Key, args: [String], parts: [EngineText] = []) {
        self.key = key
        self.args = args
        self.parts = parts
    }

    /// 오류를 문구로: 엔진 오류는 키 문구, 그 밖의 오류는 시스템이 현지화한 설명(`localizedDescription`)
    public static func describing(_ error: any Error) -> EngineText {
        if let e = error as? any EngineTextError { return e.text }
        return .verbatim(error.localizedDescription)
    }

    /// 키 없이 문장 그대로 (번역되지 않는다)
    public static func verbatim(_ text: String) -> EngineText {
        EngineText(.verbatim, text)
    }

    public var isVerbatim: Bool { key == .verbatim }

    /// 한국어 문장
    public var text: String {
        var values = args
        // "Excel이 함께 사용 중" — 앱 이름 뒤 조사는 받침에 따라 고른다
        if key.subjectParticleOnFirstArg, let first = values.first, !first.isEmpty {
            values[0] = KoreanText.withSubjectParticle(first)
        }
        return Self.format(key.koreanFormat, values + parts.map(\.text))
    }

    public var description: String { text }

    /// `language`의 문장. 한국어는 `text`(조사 처리 포함), 그 밖의 언어는 `Engine.strings`의 형식 문자열을 쓴다.
    /// 번역이 없는 키는 영어, 영어도 없으면 한국어 문장. `verbatim`은 그대로.
    public func localized(_ language: AppLanguage) -> String {
        guard language != .ko, !isVerbatim else { return text }
        guard let format = Translations.string(key.rawValue, table: "Engine", language: language)
                ?? Translations.string(key.rawValue, table: "Engine", language: .en) else { return text }
        return Self.format(format, args + parts.map { $0.localized(language) })
    }

    /// `%@`·`%1$@`·`%%`만 해석하는 안전한 치환. 인자가 모자라면 빈 문자열로 채운다 (저장된 값이 깨져도 멈추지 않도록).
    public static func format(_ format: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let ch = format[i]
            guard ch == "%" else {
                out.append(ch)
                i = format.index(after: i)
                continue
            }
            var j = format.index(after: i)
            if j < format.endIndex, format[j] == "%" {
                out.append("%")
                i = format.index(after: j)
                continue
            }
            var digits = ""
            while j < format.endIndex, let d = format[j].wholeNumberValue, d >= 0, d <= 9 {
                digits.append(format[j])
                j = format.index(after: j)
            }
            var position: Int?
            if !digits.isEmpty, j < format.endIndex, format[j] == "$" {
                position = Int(digits).map { $0 - 1 }
                j = format.index(after: j)
            } else if !digits.isEmpty {
                // `$` 없는 숫자는 지정자가 아니다
                out.append(ch)
                i = format.index(after: i)
                continue
            }
            guard j < format.endIndex, format[j] == "@" else {
                out.append(ch)
                i = format.index(after: i)
                continue
            }
            let index = position ?? next
            if position == nil { next += 1 }
            out += index >= 0 && index < args.count ? args[index] : ""
            i = format.index(after: j)
        }
        return out
    }
}

extension EngineText {
    /// 문구 키. `rawValue`는 저장·번역 키라 바꾸지 않는다.
    public enum Key: String, Codable, Sendable, CaseIterable {
        /// 키 없는 문구 (`args[0]`이 문장)
        case verbatim

        // MARK: 판정 근거 — 앱 제거 정보원

        case appBundle
        case bundleIDMatch
        case nameMatch
        case vendorFolder
        case bundleIDMatchInVendorFolder
        case nameMatchInVendorFolder
        case appGroupEntitlement
        case appGroup
        case groupNameContainsBundleID
        case teamIDPrefix
        case iCloudContainer
        case diagnosticReportPrefix
        case hiddenSettingsByName
        case settingsByName
        case pluginBundleIDMatch
        case kernelExtensionBundleID
        case installReceipt
        case installReceiptSoleOwner
        case homebrewZapRule
        case homebrewLaunchctl
        case helperNameMatchesBundleID
        case launchFileNameMatchesBundleID
        case launchExecutableInsideApp
        case launchRunsAppHelper
        case launchLabelMatchesBundleID
        case embeddedServiceLabel
        case associatedBundleIdentifiers
        case helperRunByDaemon

        // MARK: 판정 근거 — 고아 스캔

        case promotedBySibling
        case bundleIDAppOffline
        case bundleIDAppNotInstalled
        case bundleIDAppNotInstalledNoMetadata
        case containerOwnerOffline
        case containerOwnerNotInstalled
        case appGroupAppOffline
        case appGroupNoInstalledApp
        case vendorFolderNoInstalledApp
        case noInstalledAppNamed
        case noInstalledAppNamedDotfile
        case serviceAppOffline
        case launchTargetUnknown
        case executableLocationUnknown
        case serviceExecutableUnknown
        case executableOnOfflineVolume
        case executableMissing
        case homebrewRecordWithoutApp
        case packageAppMissing
        case packageInstalledFile

        // MARK: 메모 — 앱 제거

        case launchViaShell
        case syncedData
        case kernelExtensionNotRemoved
        case movedWithParent
        case inventoryUnknown
        case lowConfidenceNameOnly
        case lowConfidence
        case userData
        case lastAppOfVendor
        /// 앱 1개: "Excel이 함께 사용 중"
        case usedBy
        /// 앱 여러 개: "Excel 외 1개 앱이 함께 사용 중" (`args[1]`은 나머지 앱 수)
        case usedByMore
        case mayBeUsedByVendorService
        case mayBeUsedByMoreVendorService
        case mayBeUsedByVendorItem
        case mayBeUsedByMoreVendorItem

        // MARK: 메모 — 고아 스캔

        case spotlightDemoted
        case spotlightDemotedSome
        case recentlyModified
        /// 같은 개발사 앱 (`args[0]`은 쉼표로 이은 앱 이름 1~2개)
        case vendorAppsInstalled
        /// 같은 개발사 앱 3개 이상 (`args[1]`은 나머지 앱 수)
        case vendorAppsInstalledMore
        case maybeOnExternalVolume
        case vendorFolderMaybeShared
        case commonName
        case maybeCLIData
        case brewZapRecommended
        case homebrewRecordOnly
        case serviceExecutableRemains

        // MARK: 공유 사유

        case sharedAppGroup
        case sharedExternalLaunchService
        case sharedVendorItem
        case sharedVendorAppInstalled
        case sharedTeamAppInstalled

        // MARK: 고아 그룹 이름

        /// 앱 이름을 알 수 없고 Team ID만 있는 그룹
        case developerGroup
        case unknownName

        // MARK: 보호 판정 (SafetyGuard 진단 — GUI는 보호 사유 설명을 대신 보여 준다)

        case protectedBundleID
        case rootDirectory
        /// `args[0]`은 링크를 따라간 실제 경로, `parts[0]`은 그 경로의 보호 판정
        case symlinkToProtected
        case protectedApp
        case appleData
        case selfAppData
        case protectedFolder
        case protectedLocation
        case containsProtectedLocation

        // MARK: 검사 오류 (ScanError)

        case notAnApp
        case missingBundleID
        case appleApp
        case cannotRemoveSelf

        // MARK: 정리 실패 사유

        case serviceStopFailed
        case unresponsiveSkipped
        /// `parts[0]`은 보호 판정
        case protectedNotMoved
        /// `parts[0]`은 오류 설명
        case prefsCopyTrashFailed
        case itemMissing
        case trashFailed
        case trashLocationUnknown
        /// `parts[0]`은 관리자 작업 사유
        case holdingMoveFailed
        case noResult
        case cancelledNotMoved
        case receiptForgetFailed
        case privacyResetFailed
        case outsideSystemRootItem

        // MARK: 환경설정 캐시

        case prefsDomainInvalid
        case prefsDomainInvalidNoName
        case prefsDomainProtected
        case prefsFlushFailed
        case prefsBackupMissing
        case prefsRestoreFailed

        // MARK: 복원

        case sessionNotFound
        case restoreFailed
        case outsideSystemRootPath
        case holdingRestoreFailed
        case noAdminForHoldingRestore
        case serviceReregisterFailed
        case noAdminExecutor
        case resultNotReceived
        /// 이름을 바꿔 복원할 때 붙이는 표시 ("Foo (복원됨).plist")
        case restoredSuffix

        // MARK: 백그라운드 서비스

        case serviceLabelInvalid
        case serviceStopFailedCode
        case serviceStopFailedError
        case systemServiceStopFailed
        case plistLocationUnknown
        case serviceReregisterFailedCode
        case serviceReregisterFailedError
        case plistOutsideSystemRoot
        case systemServiceReregisterFailed

        // MARK: 명령 실행 (CommandError)

        case commandLaunchFailed
        case commandNonZeroExit

        // MARK: 관리자 작업 (privileged-op.sh 사유 코드 — `PrivilegedScript.reason(_:)`)

        case adminDone
        case adminOutsideAllowedRoot
        case adminBadPath
        case adminBadChar
        case adminSymlink
        case adminProtected
        case adminExists
        case adminBadIdentifier
        case adminBadSession
        case adminHoldingUnsafe
        /// 권한 헬퍼: 허용 루트까지의 상위 폴더 소유자·쓰기 권한이 안전하지 않음
        case adminUnsafeParent
        case adminScriptTampered
        case adminAuthCancelled
        case adminNotRoot
        case adminLaunchFailed
        case adminFileOperationFailed
        case adminNoResult
        case adminLaunchctlFailed
        case adminPkgutilFailed
        case adminFailed
        /// 관리자 인증 창(osascript `with prompt`)의 안내 문구
        case adminPrompt
        /// 권한 헬퍼 설치 (S7) — 번들에 헬퍼가 없는 실행 방식
        case helperNotBundled

        /// 한국어 형식 문자열 (`%@` 자리에 `args`가 들어간다)
        public var koreanFormat: String {
            switch self {
            case .verbatim: return "%@"

            case .appBundle: return "앱 본체 (%@)"
            case .bundleIDMatch: return "번들 ID %@ 일치"
            case .nameMatch: return "이름 '%@' 일치 (대소문자 무시)"
            case .vendorFolder: return "벤더 공용 폴더 '%@' — 같은 개발사의 다른 앱도 쓸 수 있음"
            case .bundleIDMatchInVendorFolder: return "번들 ID %@ 일치 (%@ 폴더 안)"
            case .nameMatchInVendorFolder: return "%@ 폴더 안 이름 '%@' 일치"
            case .appGroupEntitlement: return "App Group %@ (코드 서명 entitlements)"
            case .appGroup: return "App Group %@"
            case .groupNameContainsBundleID: return "그룹 이름에 번들 ID %@ 포함"
            case .teamIDPrefix: return "Team ID %@ 접두사 — 같은 개발사 공용일 수 있음"
            case .iCloudContainer: return "iCloud 컨테이너 (번들 ID %@)"
            case .diagnosticReportPrefix: return "진단 리포트 파일명이 '%@'(으)로 시작"
            case .hiddenSettingsByName: return "이름 '%@' 기반 숨김 설정 '~/%@'"
            case .settingsByName: return "이름 기반 설정 '~/%@/%@'"
            case .pluginBundleIDMatch: return "플러그인 번들 ID %@ 일치"
            case .kernelExtensionBundleID: return "커널 확장 번들 ID %@"
            case .installReceipt: return "설치 영수증 %@"
            case .installReceiptSoleOwner: return "설치 영수증 %@이(가) 단독 소유"
            case .homebrewZapRule: return "Homebrew cask '%@' zap 규칙: %@"
            case .homebrewLaunchctl: return "Homebrew cask '%@'의 launchctl 항목 %@"
            case .helperNameMatchesBundleID: return "권한 헬퍼 이름이 번들 ID %@와 일치"
            case .launchFileNameMatchesBundleID: return "파일명이 번들 ID %@와 일치 (plist를 읽지 못함)"
            case .launchExecutableInsideApp: return "실행 파일이 앱 번들 안을 가리킴: %@"
            case .launchRunsAppHelper: return "이 앱의 권한 헬퍼 %@를 실행"
            case .launchLabelMatchesBundleID: return "파일명/Label이 번들 ID %@와 일치"
            case .embeddedServiceLabel: return "앱 번들에 내장된 서비스 Label %@"
            case .associatedBundleIdentifiers: return "AssociatedBundleIdentifiers에 이 앱이 등록됨"
            case .helperRunByDaemon: return "LaunchDaemon %@이 실행하는 권한 헬퍼"

            case .promotedBySibling: return "같은 앱의 다른 항목에서 높은 근거 발견"
            case .bundleIDAppOffline: return "번들 ID %@인 앱이 연결 해제된 외장 볼륨에 있을 수 있음"
            case .bundleIDAppNotInstalled: return "번들 ID %@인 앱이 설치 목록에 없음"
            case .bundleIDAppNotInstalledNoMetadata: return "번들 ID %@인 앱이 설치 목록에 없음 (컨테이너 메타데이터 없음)"
            case .containerOwnerOffline: return "컨테이너 소유 앱 %@이(가) 연결 해제된 외장 볼륨에 있을 수 있음"
            case .containerOwnerNotInstalled: return "컨테이너 소유 앱 %@이(가) 설치되어 있지 않음 (확장·헬퍼 포함)"
            case .appGroupAppOffline: return "그룹 %@의 앱이 연결 해제된 외장 볼륨에 있을 수 있음"
            case .appGroupNoInstalledApp: return "그룹 %@을(를) 쓰는 설치 앱이 없음"
            case .vendorFolderNoInstalledApp: return "개발사 공용 폴더 '%@' — 같은 개발사의 설치 앱이 없음"
            case .noInstalledAppNamed: return "이름이 '%@'인 설치 앱이 없음"
            case .noInstalledAppNamedDotfile: return "이름이 '%@'인 설치 앱이 없음 (숨김 설정 폴더)"
            case .serviceAppOffline: return "서비스 %@의 앱이 연결 해제된 외장 볼륨에 있을 수 있음"
            case .launchTargetUnknown: return "셸·인터프리터로 실행되어 실행 대상을 확인할 수 없음"
            case .executableLocationUnknown: return "실행 파일 '%@'의 위치를 확인할 수 없음"
            case .serviceExecutableUnknown: return "서비스 %@의 실행 파일 정보가 없고 소유 앱이 설치 목록에 없음"
            case .executableOnOfflineVolume: return "실행 파일 %@이(가) 연결 해제된 외장 볼륨에 있음"
            case .executableMissing: return "실행 파일 %@ 없음"
            case .homebrewRecordWithoutApp: return "Homebrew cask '%@' 기록은 있으나 %@ 없음"
            case .packageAppMissing: return "설치 패키지 %@의 앱 %@ 없음"
            case .packageInstalledFile: return "설치 패키지 %@가 설치한 파일 (앱 번들은 삭제됨)"

            case .launchViaShell: return "셸·스크립트를 거쳐 실행돼 실제 실행 대상을 확인하지 못했습니다"
            case .syncedData: return "iCloud에 동기화되는 데이터라 옮기지 않습니다 — 지우면 다른 기기에서도 사라집니다"
            case .kernelExtensionNotRemoved: return "커널 확장은 자동으로 제거하지 않습니다 — 정리 후 안내를 확인하세요"
            case .movedWithParent: return "상위 폴더 %@와 함께 옮겨집니다"
            case .inventoryUnknown: return "설치된 앱 목록을 확인하기 전이라 다른 앱과 함께 쓰는지 판단하지 못해 기본 선택하지 않았습니다"
            case .lowConfidenceNameOnly: return "이름만 일치해 확실하지 않아 기본 선택하지 않았습니다"
            case .lowConfidence: return "신뢰도가 낮아 기본 선택하지 않았습니다"
            case .userData: return "사용자 데이터가 들어 있어 기본 선택하지 않았습니다"
            case .lastAppOfVendor: return "이 개발사의 마지막 앱이라 함께 정리합니다"
            case .usedBy: return "%@ 함께 사용 중"
            case .usedByMore: return "%@ 외 %@개 앱이 함께 사용 중"
            case .mayBeUsedByVendorService: return "%@ 함께 사용 중일 수 있습니다 — 같은 개발사 공용 백그라운드 서비스"
            case .mayBeUsedByMoreVendorService: return "%@ 외 %@개 앱이 함께 사용 중일 수 있습니다 — 같은 개발사 공용 백그라운드 서비스"
            case .mayBeUsedByVendorItem: return "%@ 함께 사용 중일 수 있습니다 — 같은 개발사 공용 항목"
            case .mayBeUsedByMoreVendorItem: return "%@ 외 %@개 앱이 함께 사용 중일 수 있습니다 — 같은 개발사 공용 항목"

            case .spotlightDemoted: return "Spotlight 색인이 불완전해 신뢰도를 낮춤"
            case .spotlightDemotedSome: return "Spotlight 색인이 불완전해 일부 항목의 신뢰도를 낮춤"
            case .recentlyModified: return "최근에 수정됨 — 아직 사용 중일 수 있음"
            case .vendorAppsInstalled: return "같은 개발사의 앱(%@)이 설치되어 있음"
            case .vendorAppsInstalledMore: return "같은 개발사의 앱(%@ 외 %@개)이 설치되어 있음"
            case .maybeOnExternalVolume: return "앱이 외장 볼륨에 있을 수 있음"
            case .vendorFolderMaybeShared: return "여러 앱이 함께 쓰는 개발사 폴더일 수 있음"
            case .commonName: return "흔한 이름이라 다른 프로그램의 데이터일 수 있음"
            case .maybeCLIData: return "CLI 도구·런타임 데이터일 수 있음"
            case .brewZapRecommended: return "brew uninstall --zap --cask %@ 로 정리하는 것을 권장"
            case .homebrewRecordOnly: return "Homebrew 기록만 남아 있음 — brew uninstall --zap --cask %@ 권장"
            case .serviceExecutableRemains: return "서비스 실행 파일이 아직 남아 있음 — 다른 프로그램이 쓰고 있을 수 있음"

            case .sharedAppGroup: return "같은 App Group(%@)을 다른 앱도 사용"
            case .sharedExternalLaunchService: return "실행 파일(%@)이 앱 밖에 있는 같은 개발사 공용 백그라운드 서비스"
            case .sharedVendorItem: return "같은 개발사의 다른 앱이 설치되어 있는 공용 항목"
            case .sharedVendorAppInstalled: return "같은 개발사의 앱이 설치되어 있음"
            case .sharedTeamAppInstalled: return "같은 개발자(Team ID %@)의 앱이 설치되어 있음"

            case .developerGroup: return "개발자 %@"
            case .unknownName: return "알 수 없음"

            case .protectedBundleID: return "보호된 번들 ID: %@"
            case .rootDirectory: return "루트 디렉토리"
            case .symlinkToProtected: return "심볼릭 링크를 따라가면 보호된 위치입니다: %@ (%@)"
            case .protectedApp: return "보호된 앱: %@"
            case .appleData: return "Apple 데이터는 정리하지 않습니다: %@"
            case .selfAppData: return "App Cleaner 자신의 데이터: %@"
            case .protectedFolder: return "보호된 폴더: %@"
            case .protectedLocation: return "보호된 위치: %@"
            case .containsProtectedLocation: return "보호된 위치를 포함하는 폴더: %@"

            case .notAnApp: return "%@은(는) 앱 번들(.app)이 아니거나 찾을 수 없습니다."
            case .missingBundleID: return "%@의 번들 ID를 읽을 수 없어 검사할 수 없습니다."
            case .appleApp: return "Apple 앱(%@)은 제거 대상에서 제외됩니다."
            case .cannotRemoveSelf: return "App Cleaner 자신은 제거할 수 없습니다."

            case .serviceStopFailed: return "서비스를 중지하지 못했습니다"
            case .unresponsiveSkipped: return "응답하지 않는 프로세스를 종료하지 않고 계속했습니다 (pid %@)"
            case .protectedNotMoved: return "보호된 항목이라 옮기지 않았습니다 (%@)"
            case .prefsCopyTrashFailed: return "환경설정 사본을 휴지통에 넣지 못했습니다: %@"
            case .itemMissing: return "항목을 찾을 수 없습니다"
            case .trashFailed: return "휴지통으로 옮기지 못했습니다: %@"
            case .trashLocationUnknown: return "휴지통 위치를 확인하지 못했습니다"
            case .holdingMoveFailed: return "보류 폴더로 옮기지 못했습니다: %@"
            case .noResult: return "결과 없음"
            case .cancelledNotMoved: return "취소되어 옮기지 않았습니다"
            case .receiptForgetFailed: return "설치 기록(pkgutil)을 지우지 못했습니다: %@"
            case .privacyResetFailed: return "개인정보 보호 권한 기록을 초기화하지 못했습니다"
            case .outsideSystemRootItem: return "시스템 루트 밖의 항목이라 관리자 권한으로 옮길 수 없습니다"

            case .prefsDomainInvalid: return "환경설정 도메인 이름이 올바르지 않습니다: %@"
            case .prefsDomainInvalidNoName: return "환경설정 도메인 이름이 올바르지 않습니다"
            case .prefsDomainProtected: return "보호된 환경설정 도메인입니다: %@"
            case .prefsFlushFailed: return "환경설정 캐시를 비우지 못했습니다 (%@, 코드 %@)"
            case .prefsBackupMissing: return "보관한 환경설정 사본이 없습니다: %@"
            case .prefsRestoreFailed: return "환경설정을 되살리지 못했습니다 (%@, 코드 %@)"

            case .sessionNotFound: return "작업 기록을 찾을 수 없습니다"
            case .restoreFailed: return "되돌리지 못했습니다: %@"
            case .outsideSystemRootPath: return "시스템 루트 밖의 경로입니다"
            case .holdingRestoreFailed: return "보류 폴더에서 되돌리지 못했습니다: %@"
            case .noAdminForHoldingRestore: return "관리자 권한 실행기가 없어 보류 폴더 항목을 되돌리지 못했습니다"
            case .serviceReregisterFailed: return "서비스를 다시 등록하지 못했습니다"
            case .noAdminExecutor: return "관리자 권한 실행기가 없습니다"
            case .resultNotReceived: return "결과를 받지 못했습니다"
            case .restoredSuffix: return "복원됨"

            case .serviceLabelInvalid: return "서비스 레이블이 올바르지 않아 중지하지 않았습니다: %@"
            case .serviceStopFailedCode: return "서비스를 중지하지 못했습니다 (%@, 코드 %@)"
            case .serviceStopFailedError: return "서비스를 중지하지 못했습니다 (%@): %@"
            case .systemServiceStopFailed: return "시스템 서비스를 중지하지 못했습니다 (%@): %@"
            case .plistLocationUnknown: return "plist 위치를 몰라 다시 등록하지 못했습니다 (%@)"
            case .serviceReregisterFailedCode: return "서비스를 다시 등록하지 못했습니다 (%@, 코드 %@)"
            case .serviceReregisterFailedError: return "서비스를 다시 등록하지 못했습니다 (%@): %@"
            case .plistOutsideSystemRoot: return "시스템 루트 밖의 plist입니다 (%@)"
            case .systemServiceReregisterFailed: return "시스템 서비스를 다시 등록하지 못했습니다 (%@): %@"

            case .commandLaunchFailed: return "%@ 실행 실패: %@"
            case .commandNonZeroExit: return "%@ 종료 코드 %@: %@"

            case .adminDone: return "완료"
            case .adminOutsideAllowedRoot: return "관리자 권한으로 옮길 수 있는 위치가 아닙니다"
            case .adminBadPath: return "경로 형식이 올바르지 않습니다"
            case .adminBadChar: return "지원하지 않는 문자가 포함된 경로입니다"
            case .adminSymlink: return "경로에 심볼릭 링크가 있어 옮기지 않았습니다"
            case .adminProtected: return "보호된 항목이라 옮기지 않았습니다"
            case .adminExists: return "같은 이름의 항목이 이미 있습니다"
            case .adminBadIdentifier: return "레이블 또는 패키지 ID 형식이 올바르지 않습니다"
            case .adminBadSession: return "작업 기록 ID가 올바르지 않습니다"
            case .adminHoldingUnsafe: return "보류 폴더가 안전하지 않아 중단했습니다"
            case .adminUnsafeParent: return "상위 폴더의 소유자나 권한이 안전하지 않아 옮기지 않았습니다"
            case .adminScriptTampered: return "관리자 작업 스크립트가 변조되어 실행하지 않았습니다"
            case .adminAuthCancelled: return "관리자 인증이 취소되었습니다"
            case .adminNotRoot: return "관리자 권한을 얻지 못했습니다"
            case .adminLaunchFailed: return "관리자 작업을 시작하지 못했습니다"
            case .adminFileOperationFailed: return "파일 작업에 실패했습니다"
            case .adminNoResult: return "관리자 작업 결과를 받지 못했습니다"
            case .adminLaunchctlFailed: return "launchctl 실행에 실패했습니다 (%@)"
            case .adminPkgutilFailed: return "pkgutil 실행에 실패했습니다 (%@)"
            case .adminFailed: return "관리자 작업에 실패했습니다 (%@)"
            case .adminPrompt: return "App Cleaner가 변경하려고 합니다."
            case .helperNotBundled: return "이 실행 방식에는 관리자 헬퍼가 포함되어 있지 않습니다"
            }
        }

        /// SafetyGuard 보호 판정 문구 (진단용 — GUI는 보호 사유 설명을 대신 보여 준다)
        public var isProtectionDetail: Bool {
            switch self {
            case .protectedBundleID, .rootDirectory, .symlinkToProtected, .protectedApp, .appleData, .selfAppData,
                 .protectedFolder, .protectedLocation, .containsProtectedLocation:
                return true
            default:
                return false
            }
        }

        /// 한국어 문장에서 첫 인자(앱 이름) 뒤에 주격 조사 "이/가"를 붙이는지
        var subjectParticleOnFirstArg: Bool {
            switch self {
            case .usedBy, .mayBeUsedByVendorService, .mayBeUsedByVendorItem: return true
            default: return false
            }
        }
    }
}

// MARK: - Codable

extension EngineText: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, args, parts, text
    }

    public init(from decoder: any Decoder) throws {
        // 이전 버전 기록: 평문 문자열
        if let single = try? decoder.singleValueContainer(), let plain = try? single.decode(String.self) {
            self = .verbatim(plain)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        let parts = try c.decodeIfPresent([EngineText].self, forKey: .parts) ?? []
        if let raw = try c.decodeIfPresent(String.self, forKey: .key), let key = Key(rawValue: raw) {
            self.init(key, args: args, parts: parts)
        } else {
            // 모르는 키 (새 버전이 쓴 기록) → 함께 저장된 한국어 문장
            self = .verbatim(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if isVerbatim {
            var single = encoder.singleValueContainer()
            try single.encode(text)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key.rawValue, forKey: .key)
        try c.encode(args, forKey: .args)
        if !parts.isEmpty { try c.encode(parts, forKey: .parts) }
        try c.encode(text, forKey: .text)
    }
}

/// 사용자에게 보여 줄 문구를 키 문구로 가진 엔진 오류 (`ScanError`, `CleanupError`, `CommandError`)
public protocol EngineTextError: Error {
    var text: EngineText { get }
}
