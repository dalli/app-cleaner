import Foundation

/// 복원에 필요한 파일 메타데이터 (plan.md 6.2)
public struct FileMetadata: Codable, Sendable, Hashable {
    public var ownerID: UInt32
    public var groupID: UInt32
    public var mode: UInt16
    /// 확장 속성 이름 → 값
    public var xattrs: [String: Data]
    /// `ls -le` 형식의 ACL 텍스트 (없으면 nil)
    public var acl: String?

    public init(ownerID: UInt32, groupID: UInt32, mode: UInt16, xattrs: [String: Data] = [:], acl: String? = nil) {
        self.ownerID = ownerID
        self.groupID = groupID
        self.mode = mode
        self.xattrs = xattrs
        self.acl = acl
    }
}

public enum MoveDestination: String, Codable, Sendable {
    case trash
    case holding
}

public struct JournalItem: Codable, Sendable, Hashable, Identifiable {
    public var originalPath: String
    public var movedTo: String
    public var destination: MoveDestination
    public var size: Int64?
    public var category: ItemCategory
    public var confidence: Confidence
    public var share: ShareStatus
    public var nature: DataNature
    public var sources: [EvidenceSource]
    public var metadata: FileMetadata?
    public var restoredAt: Date?

    public var id: String { originalPath }

    public init(originalPath: String, movedTo: String, destination: MoveDestination, size: Int64?, category: ItemCategory,
                confidence: Confidence, share: ShareStatus, nature: DataNature, sources: [EvidenceSource],
                metadata: FileMetadata? = nil, restoredAt: Date? = nil) {
        self.originalPath = originalPath
        self.movedTo = movedTo
        self.destination = destination
        self.size = size
        self.category = category
        self.confidence = confidence
        self.share = share
        self.nature = nature
        self.sources = sources
        self.metadata = metadata
        self.restoredAt = restoredAt
    }
}

/// cfprefs 도메인을 지우기 전 보관한 plist 사본
public struct PreferencesBackup: Codable, Sendable, Hashable {
    public var domain: String
    public var backupPath: String

    public init(domain: String, backupPath: String) {
        self.domain = domain
        self.backupPath = backupPath
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case restorable
    case partiallyRestorable
    case restored
    case notRestorable
}

/// 작업 단위(세션) 기록 (plan.md 6.2)
public struct JournalSession: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var kind: SessionKind
    public var targetName: String
    public var targetBundleID: String?
    public var startedAt: Date
    public var finishedAt: Date?
    public var ruleDataVersion: String
    public var steps: [String]
    public var items: [JournalItem]
    public var stoppedServices: [LaunchServiceRef]
    public var preferencesBackups: [PreferencesBackup]
    public var failures: [CleanupFailure]
    /// 화면을 열 때 이동 위치 존재 여부로 갱신
    public var status: SessionStatus
    /// 이동 위치가 사라진 항목 (휴지통 비움 등)
    public var missingItems: [String]

    public init(id: UUID = UUID(), kind: SessionKind, targetName: String, targetBundleID: String? = nil,
                startedAt: Date = Date(), finishedAt: Date? = nil, ruleDataVersion: String, steps: [String] = [],
                items: [JournalItem] = [], stoppedServices: [LaunchServiceRef] = [],
                preferencesBackups: [PreferencesBackup] = [], failures: [CleanupFailure] = [],
                status: SessionStatus = .restorable, missingItems: [String] = []) {
        self.id = id
        self.kind = kind
        self.targetName = targetName
        self.targetBundleID = targetBundleID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.ruleDataVersion = ruleDataVersion
        self.steps = steps
        self.items = items
        self.stoppedServices = stoppedServices
        self.preferencesBackups = preferencesBackups
        self.failures = failures
        self.status = status
        self.missingItems = missingItems
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
}

public struct RestoreOptions: Sendable, Hashable {
    public enum ConflictPolicy: String, Sendable {
        /// 이름을 바꿔 복원 ("Foo (복원됨)")
        case renameRestored
        case skip
    }

    public var conflictPolicy: ConflictPolicy
    /// 중지했던 서비스를 `launchctl bootstrap`으로 다시 등록
    public var reregisterServices: Bool
    /// 항목별 충돌 처리 (원래 경로 → 정책). 없는 항목은 `conflictPolicy`를 따른다.
    /// 한 번의 복원 호출로 항목마다 다른 선택을 지킨다 (관리자 인증 1회, 기록 역순 유지).
    public var itemPolicies: [String: ConflictPolicy]

    public init(conflictPolicy: ConflictPolicy = .renameRestored, reregisterServices: Bool = true,
                itemPolicies: [String: ConflictPolicy] = [:]) {
        self.conflictPolicy = conflictPolicy
        self.reregisterServices = reregisterServices
        self.itemPolicies = itemPolicies
    }

    public func conflictPolicy(for originalPath: String) -> ConflictPolicy {
        itemPolicies[originalPath] ?? conflictPolicy
    }
}

/// 되돌리기 전에 항목별로 예상한 결과 (ui-ux.md S6 되돌리기 확인).
/// 실제 `restore`와 같은 판정을 쓰며, 조회 시점의 파일 시스템 기준이다.
public struct RestorePreview: Codable, Sendable, Hashable {
    /// 원래 위치로 그대로 되돌릴 수 있는 항목
    public var ready: [String]
    /// 원래 위치에 같은 이름이 이미 있는 항목 (충돌 처리 정책을 따른다)
    public var conflicts: [String]
    /// 이동 위치가 사라져 복원할 수 없는 항목 (휴지통 비움, 보류 폴더 영구 삭제)
    public var missing: [String]
    /// 이미 되돌린 항목
    public var alreadyRestored: [String]

    public init(ready: [String] = [], conflicts: [String] = [], missing: [String] = [], alreadyRestored: [String] = []) {
        self.ready = ready
        self.conflicts = conflicts
        self.missing = missing
        self.alreadyRestored = alreadyRestored
    }

    /// 되돌리기를 시도할 항목 (충돌 포함)
    public var restorable: [String] { ready + conflicts }
}

public struct RestoreResult: Codable, Sendable {
    public var restored: [String]
    public var skipped: [String]
    /// 복원 불가 (이동 위치가 사라짐)
    public var missing: [String]
    public var failures: [CleanupFailure]

    public init(restored: [String] = [], skipped: [String] = [], missing: [String] = [], failures: [CleanupFailure] = []) {
        self.restored = restored
        self.skipped = skipped
        self.missing = missing
        self.failures = failures
    }
}

/// 보류 폴더 사용량 (ui-ux.md S6 툴바)
public struct HoldingUsage: Codable, Sendable, Hashable {
    public var totalSize: Int64
    public var oldestItemDate: Date?
    public var expiredSessionIDs: [UUID]

    public init(totalSize: Int64 = 0, oldestItemDate: Date? = nil, expiredSessionIDs: [UUID] = []) {
        self.totalSize = totalSize
        self.oldestItemDate = oldestItemDate
        self.expiredSessionIDs = expiredSessionIDs
    }
}
