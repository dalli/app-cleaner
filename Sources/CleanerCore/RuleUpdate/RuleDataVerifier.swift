import CryptoKit
import Foundation

/// 규칙 데이터 매니페스트: `{version, updatedAt?, files: {파일명: sha256hex}}` (plan.md 4.6)
public struct RuleManifest: Codable, Sendable, Hashable {
    public var version: String
    public var files: [String: String]
    /// ISO 8601
    public var updatedAt: String?

    public init(version: String, files: [String: String], updatedAt: String? = nil) {
        self.version = version
        self.files = files
        self.updatedAt = updatedAt
    }

    public var updatedDate: Date? { updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

public enum RuleDataError: Error, Sendable, Equatable, CustomStringConvertible {
    case insecureURL(String)
    case missingManifest
    case missingSignature
    case invalidSignatureEncoding
    case signatureMismatch
    case invalidManifest(String)
    case invalidFileName(String)
    case missingFile(String)
    case hashMismatch(String)
    case invalidContent(String)
    case downgrade(current: String, offered: String)
    case download(String)
    case install(String)

    public var description: String {
        switch self {
        case .insecureURL(let u): return "HTTPS가 아닌 주소는 허용하지 않음: \(u)"
        case .missingManifest: return "manifest.json 없음"
        case .missingSignature: return "manifest.sig 없음"
        case .invalidSignatureEncoding: return "서명 형식 오류"
        case .signatureMismatch: return "서명 검증 실패"
        case .invalidManifest(let why): return "매니페스트 형식 오류: \(why)"
        case .invalidFileName(let n): return "허용되지 않는 파일 이름: \(n)"
        case .missingFile(let n): return "파일 없음: \(n)"
        case .hashMismatch(let n): return "해시 불일치: \(n)"
        case .invalidContent(let n): return "내용 형식 오류: \(n)"
        case .downgrade(let cur, let new): return "더 오래된 버전(\(new))으로 바꿀 수 없음 (현재 \(cur))"
        case .download(let why): return "내려받기 실패: \(why)"
        case .install(let why): return "설치 실패: \(why)"
        }
    }
}

/// 규칙 데이터 서명 검증: 내장 Ed25519 공개키로 `manifest.json` 바이트 그대로에 대한 서명(`manifest.sig`, base64)을 확인하고,
/// 매니페스트에 적힌 모든 파일의 SHA-256을 확인한다.
public struct RuleDataVerifier: Sendable {
    /// 앱에 내장한 공개키 (`scripts/sign-rule-data.swift keygen`으로 생성).
    /// 현재 값은 개발용 키이며 개인키는 보관하지 않았다 — 배포(Phase 4) 전에 프로젝트 키로 교체한다.
    public static let embeddedPublicKeyBase64 = "VXr+Xg4CFgQJA088q0vAjfRbDx57i6aG2CS1Xi65L0s="

    public static let manifestName = "manifest.json"
    public static let signatureName = "manifest.sig"

    public let publicKey: Curve25519.Signing.PublicKey

    public init(publicKey: Curve25519.Signing.PublicKey) {
        self.publicKey = publicKey
    }

    public init(publicKeyBase64: String) throws {
        guard let raw = Data(base64Encoded: publicKeyBase64) else { throw RuleDataError.invalidSignatureEncoding }
        publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    /// 내장 공개키 검증기
    public static var embedded: RuleDataVerifier {
        // 상수 키이므로 실패하지 않는다 (테스트로 확인)
        try! RuleDataVerifier(publicKeyBase64: embeddedPublicKeyBase64)
    }

    /// 매니페스트 바이트와 서명(base64 텍스트)을 확인하고 해석한다.
    public func verifyManifest(_ manifestData: Data, signature signatureText: Data) throws -> RuleManifest {
        let text = String(decoding: signatureText, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text) else { throw RuleDataError.invalidSignatureEncoding }
        guard publicKey.isValidSignature(signature, for: manifestData) else { throw RuleDataError.signatureMismatch }
        let manifest: RuleManifest
        do {
            manifest = try JSONDecoder().decode(RuleManifest.self, from: manifestData)
        } catch {
            throw RuleDataError.invalidManifest(String(describing: error))
        }
        guard !manifest.version.isEmpty else { throw RuleDataError.invalidManifest("version 비어 있음") }
        for (name, hash) in manifest.files {
            guard Self.isAllowedFileName(name) else { throw RuleDataError.invalidFileName(name) }
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw RuleDataError.invalidManifest("해시 형식: \(name)") }
        }
        return manifest
    }

    /// 디렉토리의 `manifest.json`·`manifest.sig`와 모든 파일 해시를 확인한다.
    @discardableResult
    public func verify(directory: URL) throws -> RuleManifest {
        guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent(Self.manifestName)) else {
            throw RuleDataError.missingManifest
        }
        guard let signature = try? Data(contentsOf: directory.appendingPathComponent(Self.signatureName)) else {
            throw RuleDataError.missingSignature
        }
        let manifest = try verifyManifest(manifestData, signature: signature)
        for (name, hash) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(name)
            // 심볼릭 링크로 다른 파일을 가리키게 하는 변조 방지
            guard !FileDates.isSymlink(url), let data = try? Data(contentsOf: url) else { throw RuleDataError.missingFile(name) }
            guard Self.sha256Hex(data) == hash.lowercased() else { throw RuleDataError.hashMismatch(name) }
        }
        return manifest
    }

    /// 경로 구분자·숨김·매니페스트 자신을 허용하지 않는다.
    public static func isAllowedFileName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name != manifestName, name != signatureName else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
