import Foundation

public enum SessionKind: String, Codable, Sendable {
    case appRemoval
    case orphanCleanup
}

/// 정리 실행 계획 = S3 미리보기의 내용. CLI `--dry-run`은 이것을 JSON으로 출력한다.
public struct CleanupPlan: Codable, Sendable {
    public var kind: SessionKind
    /// 앱 이름 또는 "고아 잔여물"
    public var targetName: String
    public var targetBundleID: String?
    /// 이동할 항목 (선택된 것만, 펼친 상태)
    public var items: [Candidate]
    /// 남겨두는 항목 (S3 "남겨두는 항목 n개 보기")
    public var keptItems: [Candidate]
    /// 1단계: 중지할 서비스
    public var servicesToStop: [LaunchServiceRef]
    /// 2단계: 종료할 앱 번들 (본체·헬퍼 BID 및 번들 경로)
    public var bundleIDsToTerminate: [String]
    public var bundlePathsToTerminate: [URL]
    /// 3단계: 지울 cfprefs 도메인
    public var preferencesDomains: [String]
    /// 6단계: pkgutil --forget
    public var receiptsToForget: [String]
    /// 6단계: tccutil reset All <BID>
    public var resetPrivacy: Bool
    public var advisories: [Advisory]
    public var ruleDataVersion: String

    public init(kind: SessionKind, targetName: String, targetBundleID: String? = nil, items: [Candidate],
                keptItems: [Candidate] = [], servicesToStop: [LaunchServiceRef] = [], bundleIDsToTerminate: [String] = [],
                bundlePathsToTerminate: [URL] = [], preferencesDomains: [String] = [], receiptsToForget: [String] = [],
                resetPrivacy: Bool = false, advisories: [Advisory] = [], ruleDataVersion: String) {
        self.kind = kind
        self.targetName = targetName
        self.targetBundleID = targetBundleID
        self.items = items
        self.keptItems = keptItems
        self.servicesToStop = servicesToStop
        self.bundleIDsToTerminate = bundleIDsToTerminate
        self.bundlePathsToTerminate = bundlePathsToTerminate
        self.preferencesDomains = preferencesDomains
        self.receiptsToForget = receiptsToForget
        self.resetPrivacy = resetPrivacy
        self.advisories = advisories
        self.ruleDataVersion = ruleDataVersion
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    public var requiresAdmin: Bool {
        items.contains(where: \.requiresAdmin) || servicesToStop.contains { $0.domain == .system } || !receiptsToForget.isEmpty
    }
    /// 관리자 권한이 필요한 이유가 되는 항목 (S3 관리자 암호 안내)
    public var adminItems: [Candidate] { items.filter(\.requiresAdmin) }
    /// 사용자가 직접 고른 사용자 데이터·공유 항목 (S3 별도 경고 묶음)
    public var riskyItems: [Candidate] { items.filter { $0.nature == .userData || $0.share.isShared } }

    /// 해당 없는 단계는 표시하지 않는다 (ui-ux.md S3)
    public var steps: [CleanupStep] {
        var s: [CleanupStep] = []
        if !servicesToStop.isEmpty { s.append(.stopServices) }
        if !bundleIDsToTerminate.isEmpty || !bundlePathsToTerminate.isEmpty { s.append(.terminateApps) }
        if !preferencesDomains.isEmpty { s.append(.flushPreferences) }
        s.append(.moveItems)
        if !receiptsToForget.isEmpty || resetPrivacy { s.append(.postProcess) }
        return s
    }
}

/// Pre-flight 순서 (plan.md 4.4)
public enum CleanupStep: String, Codable, Sendable, CaseIterable {
    case stopServices
    case terminateApps
    case flushPreferences
    case moveItems
    case postProcess
}

public enum CleanupProgress: Sendable {
    case stepStarted(CleanupStep)
    case stepFinished(CleanupStep)
    case itemMoved(path: String, completed: Int, total: Int)
    case itemFailed(path: String, reason: EngineText)
}

/// 종료 요청에 응답하지 않는 앱 (ui-ux.md "진행 중")
public struct UnresponsiveApp: Sendable, Hashable {
    public var bundleID: String?
    public var name: String
    public var pid: Int32

    public init(bundleID: String?, name: String, pid: Int32) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

public enum UnresponsiveDecision: String, Sendable {
    case forceQuit
    case skip
    case cancel
}

public struct CleanupFailure: Sendable, Hashable {
    public var path: String
    public var reason: EngineText

    public init(path: String, reason: EngineText) {
        self.path = path
        self.reason = reason
    }
}

/// JSON: `reason`은 예전처럼 한국어 문장(문자열)이고, 키 문구이면 `reasonText`에 `EngineText`를 함께 저장한다.
/// 이전 버전 기록(`reason`만 있음)은 `verbatim`으로 읽고, 이전 버전은 `reasonText`를 무시하고 `reason`을 읽는다.
extension CleanupFailure: Codable {
    private enum CodingKeys: String, CodingKey {
        case path, reason, reasonText
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        let plain = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        if let keyed = try? c.decodeIfPresent(EngineText.self, forKey: .reasonText), !keyed.isVerbatim {
            reason = keyed
        } else {
            reason = .verbatim(plain)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(reason.text, forKey: .reason)
        if !reason.isVerbatim { try c.encode(reason, forKey: .reasonText) }
    }
}

public struct CleanupResult: Codable, Sendable {
    public var sessionID: UUID
    public var movedCount: Int
    public var movedSize: Int64
    public var movedToTrash: Int
    public var movedToHolding: Int
    public var failures: [CleanupFailure]
    public var cancelled: Bool
    public var advisories: [Advisory]

    public init(sessionID: UUID, movedCount: Int, movedSize: Int64, movedToTrash: Int, movedToHolding: Int,
                failures: [CleanupFailure], cancelled: Bool = false, advisories: [Advisory] = []) {
        self.sessionID = sessionID
        self.movedCount = movedCount
        self.movedSize = movedSize
        self.movedToTrash = movedToTrash
        self.movedToHolding = movedToHolding
        self.failures = failures
        self.cancelled = cancelled
        self.advisories = advisories
    }
}
