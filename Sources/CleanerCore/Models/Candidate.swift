import Foundation

/// launchd 서비스 참조 (bootout 대상)
public struct LaunchServiceRef: Codable, Sendable, Hashable {
    public enum LaunchDomain: String, Codable, Sendable {
        /// `gui/<uid>/<label>`
        case user
        /// `system/<label>` (관리자 권한)
        case system
    }

    public var label: String
    public var domain: LaunchDomain
    /// 디스크의 plist 위치 (번들 내장 SMAppService plist면 번들 내부 경로)
    public var plistURL: URL?

    public init(label: String, domain: LaunchDomain, plistURL: URL? = nil) {
        self.label = label
        self.domain = domain
        self.plistURL = plistURL
    }
}

/// 잔여물 후보 1개. 앱 제거와 고아 스캔이 같은 모델을 쓴다.
public struct Candidate: Codable, Sendable, Hashable, Identifiable {
    public var url: URL
    public var category: ItemCategory
    public var domain: Domain
    public var confidence: Confidence
    public var nature: DataNature
    public var share: ShareStatus
    public var evidence: [Evidence]
    /// 값이 있으면 선택 불가 (자물쇠 배지)
    public var protection: ProtectionReason?
    /// 기본 선택 여부 (SelectionPolicy가 결정)
    public var isSelected: Bool
    public var size: Int64?
    public var fileCount: Int?
    public var lastModified: Date?
    /// Launch plist / 헬퍼면 중지할 서비스
    public var launchService: LaunchServiceRef?
    /// cfprefs 도메인 (Preferences plist인 경우)
    public var preferencesDomain: String?
    /// Container 하위 항목 (4.3.3: 컨테이너는 펼쳐서 보여준다)
    public var children: [Candidate]
    /// 남겨두는 이유 등 사람이 읽는 설명 ("Excel이 함께 사용 중")
    public var notes: [String]

    public var id: String { url.path }
    public var path: String { url.path }
    public var isSelectable: Bool { protection == nil && nature != .synced }
    public var requiresAdmin: Bool { domain == .system }

    public init(
        url: URL,
        category: ItemCategory,
        domain: Domain = .user,
        confidence: Confidence,
        nature: DataNature? = nil,
        share: ShareStatus = .exclusive,
        evidence: [Evidence] = [],
        protection: ProtectionReason? = nil,
        isSelected: Bool = false,
        size: Int64? = nil,
        fileCount: Int? = nil,
        lastModified: Date? = nil,
        launchService: LaunchServiceRef? = nil,
        preferencesDomain: String? = nil,
        children: [Candidate] = [],
        notes: [String] = []
    ) {
        self.url = url
        self.category = category
        self.domain = domain
        self.confidence = confidence
        self.nature = nature ?? category.defaultNature
        self.share = share
        self.evidence = evidence
        self.protection = protection
        self.isSelected = isSelected
        self.size = size
        self.fileCount = fileCount
        self.lastModified = lastModified
        self.launchService = launchService
        self.preferencesDomain = preferencesDomain
        self.children = children
        self.notes = notes
    }

    /// 같은 경로를 여러 정보원이 찾았을 때 병합: 가장 강한 신뢰도, 근거 합집합.
    public mutating func merge(_ other: Candidate) {
        precondition(other.url.standardizedFileURL == url.standardizedFileURL)
        confidence = max(confidence, other.confidence)
        for e in other.evidence where !evidence.contains(e) { evidence.append(e) }
        launchService = launchService ?? other.launchService
        preferencesDomain = preferencesDomain ?? other.preferencesDomain
        protection = protection ?? other.protection
        for n in other.notes where !notes.contains(n) { notes.append(n) }
    }

    /// 자신과 하위 항목을 모두 펼친 목록
    public var flattened: [Candidate] { [self] + children.flatMap(\.flattened) }
}

extension Array where Element == Candidate {
    /// 경로 기준으로 중복을 병합한다 (순서 유지).
    public func mergedByPath() -> [Candidate] {
        var order: [String] = []
        var byPath: [String: Candidate] = [:]
        for c in self {
            let key = c.url.standardizedFileURL.path
            if var existing = byPath[key] {
                existing.merge(c)
                byPath[key] = existing
            } else {
                order.append(key)
                byPath[key] = c
            }
        }
        return order.compactMap { byPath[$0] }
    }

    public var selectedItems: [Candidate] { flatMap(\.flattened).filter { $0.isSelected && $0.isSelectable } }
}
