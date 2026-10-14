import Foundation
import CleanerCore

/// 사용자 표시 문구 (ui-ux.md 4.3: 신뢰도 높음/보통/낮음, 데이터 성격 재생성 가능/설정/사용자 데이터/보호됨)
enum Format {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "계산 중…" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func confidence(_ c: Confidence) -> String {
        switch c {
        case .high: return "높음"
        case .medium: return "보통"
        case .low: return "낮음"
        }
    }

    static func nature(_ n: DataNature) -> String {
        switch n {
        case .regenerable: return "재생성 가능"
        case .settings: return "설정"
        case .userData: return "사용자 데이터"
        case .synced: return "보호됨"
        }
    }

    static func badges(_ c: Candidate) -> String {
        var parts = ["신뢰도 \(confidence(c.confidence))", nature(c.nature)]
        if case .shared(let apps, _) = c.share {
            parts.append(apps.isEmpty ? "공유" : "\(sharedLabel(apps))")
        }
        if c.protection != nil { parts.append("보호됨") }
        if c.requiresAdmin { parts.append("관리자") }
        return "[" + parts.joined(separator: " · ") + "]"
    }

    static func sharedLabel(_ apps: [String]) -> String {
        guard let first = apps.first else { return "공유" }
        return apps.count == 1 ? "\(first)이(가) 함께 사용 중" : "\(first) 외 \(apps.count - 1)개 앱이 함께 사용 중"
    }

    static func step(_ s: CleanupStep) -> String {
        switch s {
        case .stopServices: return "서비스 중지"
        case .terminateApps: return "앱 종료 요청"
        case .flushPreferences: return "환경설정 캐시 비우기"
        case .moveItems: return "이동"
        case .postProcess: return "마무리"
        }
    }

    static func status(_ s: SessionStatus) -> String {
        switch s {
        case .restorable: return "복원 가능"
        case .partiallyRestorable: return "일부 복원 불가"
        case .restored: return "되돌림"
        case .notRestorable: return "복원 불가"
        }
    }

    static func warning(_ w: ScanWarning) -> String {
        switch w {
        case .appRunning: return "앱이 실행 중입니다. 정리할 때 종료를 요청합니다."
        case .otherCopies(let urls): return "같은 번들 ID의 다른 사본이 있습니다: " + urls.map(\.path).joined(separator: ", ")
        case .noFullDiskAccess: return "전체 디스크 접근 권한이 없어 일부 항목을 찾지 못했을 수 있습니다."
        case .unreadable(let urls): return "확인하지 못한 위치: " + urls.map(\.path).joined(separator: ", ")
        case .inventoryUnavailable: return "설치 앱 목록을 아직 만들지 못해 공유 여부를 확인할 항목은 남겨둡니다."
        }
    }

    static func advisory(_ a: Advisory) -> String {
        switch a {
        case .loginItems: return "시스템 설정 › 일반 › 로그인 항목에 남은 항목이 있는지 확인하세요."
        case .keychain(let term): return "키체인 접근 앱에서 '\(term)'(으)로 검색해 남은 항목을 확인하세요."
        case .systemExtension(let id): return "System Extension \(id)은(는) 자동으로 제거하지 않습니다."
        case .kernelExtension(let path): return "커널 확장 \(path)은(는) 자동으로 제거하지 않습니다."
        case .homebrewZap(let token): return "Homebrew로 설치된 앱입니다: brew uninstall --zap --cask \(token)"
        }
    }
}
