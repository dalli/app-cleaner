import Foundation
import Security

/// 권한 헬퍼(LaunchDaemon)의 이름들 (plan.md 5.3). 모두 앱 BID에서 만든다.
///
/// | 항목 | 값 (기본 BID `com.dallisoft.AppCleaner`) |
/// |---|---|
/// | launchd 레이블 = Mach 서비스 = 헬퍼 서명 식별자 | `com.dallisoft.AppCleaner.Helper` |
/// | 번들 안 plist (`SMAppService.daemon(plistName:)`) | `Contents/Library/LaunchDaemons/com.dallisoft.AppCleaner.Helper.plist` |
/// | 헬퍼 실행 파일 | `Contents/MacOS/AppCleanerHelper` |
/// | 허용 클라이언트 서명 식별자 | `com.dallisoft.AppCleaner`(GUI), `com.dallisoft.AppCleaner.cli`(번들 CLI) |
///
/// BID는 `scripts/build-app.sh`의 `BUNDLE_ID`로 바꿀 수 있고, 헬퍼는 자기 서명 식별자에서 앱 BID를 되찾는다.
public struct PrivilegedHelperIdentity: Sendable, Hashable {
    public static let helperSuffix = ".Helper"
    public static let cliSuffix = ".cli"
    public static let executableName = "AppCleanerHelper"

    /// 앱 BID
    public var appBundleID: String

    public init(appBundleID: String) {
        self.appBundleID = appBundleID
    }

    public static let `default` = PrivilegedHelperIdentity(appBundleID: SystemPaths.defaultSelfBundleID)

    /// 헬퍼 서명 식별자(`<BID>.Helper`)에서. 접미사가 없거나 BID 형식이 아니면 nil.
    public init?(helperIdentifier: String) {
        guard helperIdentifier.hasSuffix(Self.helperSuffix) else { return nil }
        let bid = String(helperIdentifier.dropLast(Self.helperSuffix.count))
        guard SafeIdentifier.isValid(bid) else { return nil }
        self.appBundleID = bid
    }

    /// launchd 레이블 = Mach 서비스 이름 = 헬퍼 서명 식별자
    public var helperLabel: String { appBundleID + Self.helperSuffix }
    public var machServiceName: String { helperLabel }
    public var plistName: String { helperLabel + ".plist" }
    public var cliIdentifier: String { appBundleID + Self.cliSuffix }
    /// 헬퍼에 연결할 수 있는 클라이언트 서명 식별자
    public var clientIdentifiers: [String] { [appBundleID, cliIdentifier] }

    /// 현재 프로세스 기준: `.app`이면 그 BID, 번들 CLI(`X.app/Contents/Helpers/appcleaner`)면 바깥 앱의 BID, 그 밖에는 기본값.
    public static func forCurrentProcess(bundle: Bundle = .main) -> PrivilegedHelperIdentity {
        if bundle.bundleURL.pathExtension == "app", let bid = bundle.bundleIdentifier, SafeIdentifier.isValid(bid) {
            return PrivilegedHelperIdentity(appBundleID: bid)
        }
        if let exe = bundle.executableURL?.resolvingSymlinksInPath() {
            let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
            if contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app",
               let bid = BundleInfo.read(bundleAt: contents.deletingLastPathComponent())?.bundleID, SafeIdentifier.isValid(bid) {
                return PrivilegedHelperIdentity(appBundleID: bid)
            }
        }
        return .default
    }
}

/// 코드 서명 요구사항 문자열 (`NSXPCConnection.setCodeSigningRequirement(_:)`, plan.md 5.3).
///
/// Team ID·식별자는 요구사항 언어에 그대로 들어가므로 형식을 먼저 검사한다 (따옴표 등으로 조건을 바꾸는 주입 방지).
public enum CodeSigningRequirement {
    /// Apple이 발급한 Team ID: 영문 대문자·숫자 10자
    public static func isValidTeamID(_ s: String) -> Bool {
        s.count == 10 && s.unicodeScalars.allSatisfy { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") }
    }

    /// `anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and identifier "<ID>"`
    /// (식별자가 여럿이면 `(identifier "A" or identifier "B")`). 형식이 잘못되면 nil.
    public static func make(teamID: String, identifiers: [String]) -> String? {
        guard isValidTeamID(teamID), let ids = identifierClause(identifiers) else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and \(ids)"
    }

    /// 개발 모드(Team ID 없는 ad-hoc 서명) — 식별자만 본다. **서명 검증이 아니므로 배포 빌드에 쓰지 않는다.**
    /// 헬퍼는 `APPCLEANER_HELPER_DEV` 컴파일 조건으로 빌드했을 때만 이 요구사항을 쓴다 (docs/development.md).
    public static func development(identifiers: [String]) -> String? {
        identifierClause(identifiers)
    }

    /// 요구사항 언어로 컴파일되는지 (`SecRequirementCreateWithString`)
    public static func compiles(_ requirement: String) -> Bool {
        var req: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess && req != nil
    }

    private static func identifierClause(_ identifiers: [String]) -> String? {
        guard !identifiers.isEmpty, identifiers.allSatisfy(SafeIdentifier.isValid) else { return nil }
        let parts = identifiers.map { "identifier \"\($0)\"" }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " or ") + ")"
    }
}

/// 현재 프로세스의 코드 서명 (`SecCodeCopySelf`). 헬퍼는 자기 Team ID로 클라이언트 요구사항을 만들고,
/// 앱은 자기 Team ID로 헬퍼 요구사항을 만든다 — 같은 Team으로 서명된 짝끼리만 통신한다.
public enum SelfCodeSignature {
    public static func current() -> SigningInfo? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return nil }
        return SigningInfo(teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                           identifier: info[kSecCodeInfoIdentifier as String] as? String)
    }
}
