import Foundation

/// 신뢰도 (plan.md 4.3.1, 4.5.4)
public enum Confidence: Int, Codable, Sendable, CaseIterable, Comparable {
    case low = 0
    case medium = 1
    case high = 2

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public func demoted() -> Confidence { Confidence(rawValue: max(rawValue - 1, 0))! }
    public func promoted() -> Confidence { Confidence(rawValue: min(rawValue + 1, 2))! }
    public func capped(at limit: Confidence) -> Confidence { min(self, limit) }
}

/// 데이터 성격 (plan.md 4.3.3)
public enum DataNature: String, Codable, Sendable, CaseIterable {
    case regenerable
    case settings
    case userData
    /// iCloud 등 동기화 데이터 — 선택 불가
    case synced

    public var selectableByDefault: Bool { self == .regenerable || self == .settings }
}

/// 공유 판정 (plan.md 4.3.2)
public enum ShareStatus: Codable, Sendable, Hashable {
    case exclusive
    /// 다른 설치 앱이 사용 중. `usedBy`는 사용 중인 앱의 표시 이름.
    /// `reason`은 삭제 기록에도 저장된다 (이전 버전 기록은 평문 문자열 → `EngineText.verbatim`).
    case shared(usedBy: [String], reason: EngineText)

    public var isShared: Bool {
        if case .shared = self { return true }
        return false
    }

    public var usedBy: [String] {
        if case .shared(let apps, _) = self { return apps }
        return []
    }
}

/// 선택 자체가 불가능한 이유 (plan.md 5.1)
public enum ProtectionReason: String, Codable, Sendable {
    case iCloudData
    case protectedPath
    case appleBundle
    case selfApp
    case securityFolder
    case deviceBackup
    case symlinkEscape
    case detectOnly   // kext, System Extension: 탐지·안내만
}

public enum Domain: String, Codable, Sendable {
    case user
    case system
}

/// 잔여물 카테고리 (plan.md 3장)
public enum ItemCategory: String, Codable, Sendable, CaseIterable {
    case appBundle
    case container
    case containerItem
    case groupContainer
    case iCloudContainer
    case applicationSupport
    case applicationScripts
    case caches
    case httpStorage
    case webKit
    case cookies
    case preferences
    case byHostPreferences
    case savedState
    case logs
    case diagnosticReports
    case launchAgent
    case launchDaemon
    case privilegedHelper
    case plugin
    case tempFiles
    case dotfile
    case receipt
    case kernelExtension
    case systemExtension
    case other

    /// 카테고리별 기본 데이터 성격. 실제 판정은 SelectionPolicy가 내용을 보고 덮어쓸 수 있다.
    public var defaultNature: DataNature {
        switch self {
        case .caches, .httpStorage, .webKit, .savedState, .logs, .diagnosticReports, .tempFiles:
            return .regenerable
        case .preferences, .byHostPreferences, .cookies, .launchAgent, .launchDaemon,
             .applicationScripts, .privilegedHelper, .plugin, .receipt, .kernelExtension, .systemExtension:
            return .settings
        case .iCloudContainer:
            return .synced
        case .appBundle:
            return .regenerable
        case .container, .containerItem, .groupContainer, .applicationSupport, .dotfile, .other:
            return .settings
        }
    }

    /// S2 검사기의 카테고리 묶음 (ui-ux.md S2)
    public var displayGroup: DisplayGroup {
        switch self {
        case .appBundle: return .appBundle
        case .container, .containerItem: return .container
        case .groupContainer, .iCloudContainer: return .groupContainer
        case .launchAgent, .launchDaemon, .privilegedHelper: return .background
        case .caches, .httpStorage, .webKit, .savedState, .logs, .diagnosticReports, .tempFiles, .cookies:
            return .cachesLogsState
        case .preferences, .byHostPreferences, .applicationScripts: return .preferences
        case .applicationSupport, .plugin, .dotfile, .other: return .support
        case .receipt, .kernelExtension, .systemExtension: return .system
        }
    }

    public enum DisplayGroup: String, Codable, Sendable, CaseIterable {
        case appBundle, container, groupContainer, background, cachesLogsState, preferences, support, system
    }
}

/// 후보를 찾은 정보원 (plan.md 4.2)
public enum EvidenceSource: String, Codable, Sendable {
    case receipt            // pkgutil 영수증
    case homebrewZap        // Homebrew Cask zap
    case bundleIdentifier   // BID 정확 일치 / `<BID>.` 접두사
    case appGroup           // entitlements App Group
    case teamIdentifier     // `<TEAM>.` 접두
    case name               // 이름 정확 일치
    case launchPlist        // Launch plist 내용 분석
    case embeddedLaunchPlist // 번들 내장 SMAppService plist
    case containerMetadata  // .com.apple.containermanagerd.metadata.plist
    case inventory          // 고아 스캔: 인벤토리 대조
    case homebrewRecord     // 고아 스캔: Caskroom 기록
    case pathRule           // 기타 경로 규칙
}

public struct Evidence: Codable, Sendable, Hashable {
    public var source: EvidenceSource
    /// 사람이 읽는 근거 (예: `.executableMissing` → "실행 파일 /Applications/Foo.app/... 없음")
    public var detail: EngineText

    public init(_ source: EvidenceSource, _ detail: EngineText) {
        self.source = source
        self.detail = detail
    }
}
