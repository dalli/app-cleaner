import Foundation

/// S2 상태 배너 (ui-ux.md S2)
public enum ScanWarning: Codable, Sendable, Hashable {
    case appRunning
    /// 같은 BID의 다른 사본 경로
    case otherCopies([URL])
    case noFullDiskAccess
    /// 권한 부족으로 읽지 못한 위치
    case unreadable([URL])
    case inventoryUnavailable
}

/// 앱 제거 흐름의 검사 결과
public struct ScanReport: Codable, Sendable {
    public var identity: AppIdentity
    public var candidates: [Candidate]
    public var warnings: [ScanWarning]
    /// 키체인·로그인 항목·System Extension 등 정리 후 안내 (ui-ux.md S4)
    public var advisories: [Advisory]
    public var ruleDataVersion: String
    public var scannedAt: Date

    public init(identity: AppIdentity, candidates: [Candidate], warnings: [ScanWarning] = [], advisories: [Advisory] = [],
                ruleDataVersion: String, scannedAt: Date = Date()) {
        self.identity = identity
        self.candidates = candidates
        self.warnings = warnings
        self.advisories = advisories
        self.ruleDataVersion = ruleDataVersion
        self.scannedAt = scannedAt
    }
}

public enum Advisory: Codable, Sendable, Hashable {
    case loginItems
    case keychain(searchTerm: String)
    case systemExtension(identifier: String)
    case kernelExtension(path: String)
    case homebrewZap(token: String)
}

// MARK: - 고아 스캔

public struct OrphanScanOptions: Codable, Sendable, Hashable {
    public var includeDotfiles: Bool
    public var minimumConfidence: Confidence
    /// 인벤토리 캐시 사용 허용
    public var useCachedInventory: Bool
    /// 이 기간 안에 수정된 항목은 한 단계 강등 (기본 7일)
    public var recentModificationWindow: TimeInterval

    public init(includeDotfiles: Bool = false, minimumConfidence: Confidence = .low, useCachedInventory: Bool = true,
                recentModificationWindow: TimeInterval = 7 * 24 * 3600) {
        self.includeDotfiles = includeDotfiles
        self.minimumConfidence = minimumConfidence
        self.useCachedInventory = useCachedInventory
        self.recentModificationWindow = recentModificationWindow
    }
}

public struct OrphanGroup: Codable, Sendable, Hashable, Identifiable {
    /// 그룹 키 (BID / BID 접두사 / Team ID / 이름)
    public var id: String
    public var displayName: String
    /// 이름이 추정인지 (ui-ux.md: "(추정)")
    public var nameIsGuess: Bool
    public var bundleID: String?
    public var teamID: String?
    public var items: [Candidate]
    /// 그룹 내 가장 강한 근거
    public var confidence: Confidence
    public var share: ShareStatus
    /// 그룹 메모 (예: "앱이 외장 볼륨에 있을 수 있음")
    public var notes: [String]

    public init(id: String, displayName: String, nameIsGuess: Bool, bundleID: String? = nil, teamID: String? = nil,
                items: [Candidate], confidence: Confidence, share: ShareStatus = .exclusive, notes: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.nameIsGuess = nameIsGuess
        self.bundleID = bundleID
        self.teamID = teamID
        self.items = items
        self.confidence = confidence
        self.share = share
        self.notes = notes
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var lastModified: Date? { items.compactMap(\.lastModified).max() }
}

public struct OrphanScanReport: Codable, Sendable {
    public var groups: [OrphanGroup]
    public var spotlight: SpotlightStatus
    public var inventoryAppCount: Int
    public var duration: TimeInterval
    /// 유지 목록 때문에 숨긴 그룹·항목 수
    public var hiddenByKeepList: Int
    public var warnings: [ScanWarning]
    public var ruleDataVersion: String
    public var scannedAt: Date

    public init(groups: [OrphanGroup], spotlight: SpotlightStatus, inventoryAppCount: Int, duration: TimeInterval,
                hiddenByKeepList: Int = 0, warnings: [ScanWarning] = [], ruleDataVersion: String, scannedAt: Date = Date()) {
        self.groups = groups
        self.spotlight = spotlight
        self.inventoryAppCount = inventoryAppCount
        self.duration = duration
        self.hiddenByKeepList = hiddenByKeepList
        self.warnings = warnings
        self.ruleDataVersion = ruleDataVersion
        self.scannedAt = scannedAt
    }
}

public enum OrphanScanEvent: Sendable {
    case phase(OrphanScanPhase)
    /// 스캔 중 점진적으로 추가되는 그룹
    case groupFound(OrphanGroup)
}

public enum OrphanScanPhase: String, Codable, Sendable, CaseIterable {
    case buildingInventory
    case collectingCandidates
    case judging
    case finished
}

/// 유지(무시) 목록 항목 (plan.md 4.5.7)
public struct KeepEntry: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case group, item }
    public var kind: Kind
    /// group이면 그룹 키, item이면 경로
    public var key: String
    public var displayName: String
    public var addedAt: Date

    public var id: String { "\(kind.rawValue):\(key)" }

    public init(kind: Kind, key: String, displayName: String, addedAt: Date = Date()) {
        self.kind = kind
        self.key = key
        self.displayName = displayName
        self.addedAt = addedAt
    }
}
