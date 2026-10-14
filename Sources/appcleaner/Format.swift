import Foundation
import CleanerCore

/// 사용자 표시 문구 (ui-ux.md 4.3: 신뢰도 높음/보통/낮음, 데이터 성격 재생성 가능/설정/사용자 데이터/보호됨)
struct Format {
    var language: AppLanguage
    private var t: CLIText { CLIText(language: language) }

    /// 크기. 영어·일본어는 출력 언어의 로케일을 따르고("12.3 MB", "512バイト"),
    /// 한국어는 이전 출력과 같게 `ByteCountFormatter`("12.3 MB")를 쓴다.
    func size(_ bytes: Int64?) -> String {
        guard let bytes else { return t("계산 중…") }
        if language == .ko { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return bytes.formatted(.byteCount(style: .file).locale(language.locale()))
    }

    func confidence(_ c: Confidence) -> String {
        switch c {
        case .high: return t("높음")
        case .medium: return t("보통")
        case .low: return t("낮음")
        }
    }

    func nature(_ n: DataNature) -> String {
        switch n {
        case .regenerable: return t("재생성 가능")
        case .settings: return t("설정")
        case .userData: return t("사용자 데이터")
        case .synced: return t("보호됨")
        }
    }

    func badges(_ c: Candidate) -> String {
        var parts = [t("신뢰도 %@", confidence(c.confidence)), nature(c.nature)]
        if case .shared(let apps, _) = c.share {
            parts.append(apps.isEmpty ? t("공유") : "\(sharedLabel(apps))")
        }
        if c.protection != nil { parts.append(t("보호됨")) }
        if c.requiresAdmin { parts.append(t("관리자")) }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    func sharedLabel(_ apps: [String]) -> String {
        guard let first = apps.first else { return t("공유") }
        return apps.count == 1 ? t("%@이(가) 함께 사용 중", first) : t("%@ 외 %lld개 앱이 함께 사용 중", first, apps.count - 1)
    }

    func step(_ s: CleanupStep) -> String {
        switch s {
        case .stopServices: return t("서비스 중지")
        case .terminateApps: return t("앱 종료 요청")
        case .flushPreferences: return t("환경설정 캐시 비우기")
        case .moveItems: return t("이동")
        case .postProcess: return t("마무리")
        }
    }

    func status(_ s: SessionStatus) -> String {
        switch s {
        case .restorable: return t("복원 가능")
        case .partiallyRestorable: return t("일부 복원 불가")
        case .restored: return t("되돌림")
        case .notRestorable: return t("복원 불가")
        }
    }

    func warning(_ w: ScanWarning) -> String {
        switch w {
        case .appRunning: return t("앱이 실행 중입니다. 정리할 때 종료를 요청합니다.")
        case .otherCopies(let urls): return t("같은 번들 ID의 다른 사본이 있습니다: %@", urls.map(\.path).joined(separator: ", "))
        case .noFullDiskAccess: return t("전체 디스크 접근 권한이 없어 일부 항목을 찾지 못했을 수 있습니다.")
        case .unreadable(let urls): return t("확인하지 못한 위치: %@", urls.map(\.path).joined(separator: ", "))
        case .inventoryUnavailable: return t("설치 앱 목록을 아직 만들지 못해 공유 여부를 확인할 항목은 남겨둡니다.")
        }
    }

    func advisory(_ a: Advisory) -> String {
        switch a {
        case .loginItems: return t("시스템 설정 › 일반 › 로그인 항목에 남은 항목이 있는지 확인하세요.")
        case .keychain(let term): return t("키체인 접근 앱에서 '%@'(으)로 검색해 남은 항목을 확인하세요.", term)
        case .systemExtension(let id): return t("System Extension %@은(는) 자동으로 제거하지 않습니다.", id)
        case .kernelExtension(let path): return t("커널 확장 %@은(는) 자동으로 제거하지 않습니다.", path)
        case .homebrewZap(let token): return t("Homebrew로 설치된 앱입니다: brew uninstall --zap --cask %@", token)
        }
    }

    /// 엔진 문구 (판정 근거·메모·실패 사유)
    func engine(_ text: EngineText) -> String { text.localized(language) }

    /// 오류: 엔진 오류는 키 문구, 그 밖에는 시스템 설명
    func error(_ error: any Error) -> String { EngineText.describing(error).localized(language) }
}
