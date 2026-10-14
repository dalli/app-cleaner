import Foundation
import Security

/// 코드 서명에서 얻는 정보 (plan.md 4.1)
public struct SigningInfo: Codable, Sendable, Hashable {
    public var teamID: String?
    public var appGroups: [String]
    /// 서명 식별자 (보통 BID)
    public var identifier: String?

    public init(teamID: String? = nil, appGroups: [String] = [], identifier: String? = nil) {
        self.teamID = teamID
        self.appGroups = appGroups
        self.identifier = identifier
    }
}

public protocol CodeSignatureReading: Sendable {
    func signingInfo(for bundleURL: URL) -> SigningInfo?
}

/// Security.framework 기반 실제 구현
public struct SecCodeSignatureReader: CodeSignatureReading {
    public init() {}

    public func signingInfo(for bundleURL: URL) -> SigningInfo? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        var groups: [String] = []
        if let ent = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            groups = ent["com.apple.security.application-groups"] as? [String] ?? []
        }
        return SigningInfo(teamID: team, appGroups: groups, identifier: identifier)
    }
}
