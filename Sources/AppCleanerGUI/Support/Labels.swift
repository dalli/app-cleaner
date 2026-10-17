import CleanerCore
import Foundation

// 엔진 모델의 사용자 표시 이름 (ui-ux.md 4.3 문구 원칙)

extension Confidence {
    var title: String {
        switch self {
        case .high: return L("높음")
        case .medium: return L("보통")
        case .low: return L("낮음")
        }
    }

    /// VoiceOver·배지 전체 이름 ("신뢰도 높음")
    var fullTitle: String {
        switch self {
        case .high: return L("신뢰도 높음")
        case .medium: return L("신뢰도 보통")
        case .low: return L("신뢰도 낮음")
        }
    }
}

extension DataNature {
    var title: String {
        switch self {
        case .regenerable: return L("재생성 가능")
        case .settings: return L("설정")
        case .userData: return L("사용자 데이터")
        case .synced: return L("보호됨")
        }
    }
}

extension InstallSource {
    var title: String {
        switch self {
        case .appStore: return "App Store"
        case .homebrew: return "Homebrew"
        case .package: return L("설치 패키지")
        case .direct: return L("직접 설치")
        }
    }
}

extension HomebrewKind {
    /// Homebrew 용어라 번역하지 않는다
    var title: String {
        switch self {
        case .formula: return "Formula"
        case .cask: return "Cask"
        }
    }
}

extension SessionStatus {
    var title: String {
        switch self {
        case .restorable: return L("복원 가능")
        case .partiallyRestorable: return L("일부 복원 불가")
        case .restored: return L("되돌림")
        case .notRestorable: return L("복원 불가")
        }
    }
}

extension SessionKind {
    var title: String {
        switch self {
        case .appRemoval: return L("앱 제거")
        case .orphanCleanup: return L("고아 정리")
        case .packageRemoval: return L("패키지 정리")
        case .installerCleanup: return L("설치 파일 정리")
        }
    }
}

extension ProtectionReason {
    var explanation: String {
        switch self {
        case .iCloudData: return L("iCloud에 동기화되는 데이터라 여기서 정리할 수 없습니다.")
        case .protectedPath: return L("시스템 보호 위치라 선택할 수 없습니다.")
        case .appleBundle: return L("Apple 기본 구성 요소라 선택할 수 없습니다.")
        case .selfApp: return L("App Cleaner 자신의 파일입니다.")
        case .securityFolder: return L("보안 설정 폴더라 항상 제외합니다.")
        case .deviceBackup: return L("기기 백업이라 선택할 수 없습니다.")
        case .symlinkEscape: return L("다른 위치를 가리키는 링크라 선택할 수 없습니다.")
        case .detectOnly: return L("탐지만 합니다. 정리 후 직접 확인하는 방법을 안내합니다.")
        }
    }
}

extension ShareStatus {
    /// "Excel이 함께 사용 중", "Excel, PowerPoint, Outlook이 함께 사용 중"
    var usageText: String? {
        let apps = usedBy
        guard isShared else { return nil }
        guard !apps.isEmpty else { return L("다른 앱이 함께 사용 중") }
        return L("%@ 함께 사용 중", Josa.iGa(apps.joined(separator: ", ")))
    }

    /// VoiceOver ("공유: Excel 외 2개 앱 사용 중")
    var spokenText: String? {
        guard isShared else { return nil }
        let apps = usedBy
        switch apps.count {
        case 0: return L("공유: 다른 앱이 사용 중")
        case 1: return L("공유: %@ 사용 중", apps[0])
        default: return L("공유: %@ 외 %lld개 앱 사용 중", apps[0], apps.count - 1)
        }
    }
}

extension EngineText {
    /// 현재 UI 언어의 문장 (판정 근거·메모·공유 사유·실패 사유). 번역은 CleanerCore 리소스의 `Engine.strings`.
    var localized: String { localized(L10n.appLanguage) }
}

extension OrphanGroup {
    /// 현재 UI 언어의 그룹 이름 ("개발자 …" 같은 엔진 문구 이름도 번역)
    var title: String { title(L10n.appLanguage) }
}

extension JournalSession {
    /// 대상 이름. 엔진이 고아 정리에 붙이는 고정 이름("고아 잔여물")은 UI 언어로 바꾼다 (이전 기록 포함).
    var targetTitle: String { CleanupPlan.title(kind: kind, targetName: targetName) }
}

extension CleanupPlan {
    var targetTitle: String { Self.title(kind: kind, targetName: targetName) }

    static func title(kind: SessionKind, targetName: String) -> String {
        if kind == .orphanCleanup && targetName == CleanupPlanner.orphanTargetName { return L("고아 잔여물") }
        if kind == .packageRemoval && targetName == CleanupPlanner.packageCacheTargetName { return L("패키지 매니저 캐시") }
        if kind == .installerCleanup && targetName == CleanupPlanner.installerTargetName { return L("App Cleaner 설치 파일") }
        return targetName
    }
}

extension EvidenceSource {
    /// 정보원 이름. 내부 용어는 이 칸에만 쓴다 (ui-ux.md 4.3).
    var title: String {
        switch self {
        case .receipt: return L("설치 영수증 (pkgutil)")
        case .homebrewZap: return L("Homebrew zap")
        case .bundleIdentifier: return L("번들 ID")
        case .appGroup: return L("App Group (entitlements)")
        case .teamIdentifier: return L("Team ID")
        case .name: return L("이름 일치")
        case .launchPlist: return L("Launch plist")
        case .embeddedLaunchPlist: return L("번들 내장 Launch plist (SMAppService)")
        case .containerMetadata: return L("컨테이너 메타데이터 (containermanagerd)")
        case .inventory: return L("설치 앱 인벤토리")
        case .homebrewRecord: return L("Homebrew Caskroom 기록")
        case .pathRule: return L("경로 규칙")
        case .packageManager: return L("패키지 매니저 설치 기록")
        }
    }
}

extension CleanupStep {
    var progressTitle: String {
        switch self {
        case .stopServices: return L("백그라운드 서비스 중지")
        case .terminateApps: return L("앱 종료 요청")
        case .flushPreferences: return L("환경설정 캐시 비우기")
        case .moveItems: return L("휴지통으로 이동")
        case .postProcess: return L("마무리")
        }
    }
}

extension Advisory {
    var stableID: String {
        switch self {
        case .loginItems: return "login"
        case .keychain(let t): return "keychain:\(t)"
        case .systemExtension(let id): return "sysext:\(id)"
        case .kernelExtension(let p): return "kext:\(p)"
        case .homebrewZap(let t): return "brew:\(t)"
        }
    }
}

extension ScanWarning {
    var stableID: String {
        switch self {
        case .appRunning: return "running"
        case .otherCopies: return "copies"
        case .noFullDiskAccess: return "fda"
        case .unreadable: return "unreadable"
        case .inventoryUnavailable: return "inventory"
        }
    }
}

extension Candidate {
    /// 행 제목: 앱 본체·컨테이너 하위는 마지막 경로 요소, 그 외는 파일 이름
    var displayName: String {
        if category == .containerItem {
            // ".../Containers/<bid>/Data/Library/Caches" → "Data/Library/Caches"
            let comps = url.pathComponents
            if let i = comps.lastIndex(where: { $0 == "Data" }) {
                return comps[i...].joined(separator: "/")
            }
        }
        return url.lastPathComponent
    }

    /// 보조 설명 줄 (남겨두는 이유 등)
    var secondaryText: String? {
        // 보호 항목의 SafetyGuard 판정 문구는 진단용이라 보호 사유 설명을 대신 쓴다
        if let protection {
            return notes.first(where: { !$0.isVerbatim && !$0.key.isProtectionDetail })?.localized ?? protection.explanation
        }
        if !notes.isEmpty { return notes.map(\.localized).joined(separator: " · ") }
        if let usage = share.usageText { return usage }
        return nil
    }

    var isRisky: Bool { nature == .userData || share.isShared }
}
