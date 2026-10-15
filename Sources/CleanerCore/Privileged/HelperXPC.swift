import Foundation

/// 앱 ↔ 권한 헬퍼 XPC 인터페이스 (plan.md 5.3). 요청·응답은 JSON(`HelperWireRequest`·`HelperWireReply`)으로 주고받아
/// 헬퍼가 형식을 엄격하게 다시 검증한다. 메서드는 이 두 개뿐이다.
@objc(AppCleanerPrivilegedHelperXPC)
public protocol PrivilegedHelperXPC {
    /// 프로토콜 버전 (`HelperWireRequest.currentVersion`). 연결 가능 여부 확인용 — 파일 시스템을 건드리지 않는다.
    func ping(withReply reply: @escaping @Sendable (Int) -> Void)
    /// `HelperWireRequest` JSON → `HelperWireReply` JSON
    func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public enum PrivilegedHelperInterface {
    public static func make() -> NSXPCInterface { NSXPCInterface(with: PrivilegedHelperXPC.self) }
}

// MARK: 전송 형식

/// 작업 1개. 앱 쪽 enum을 그대로 직렬화하지 않고 평평한 필드로 보내 헬퍼가 필드마다 검증한다.
public struct HelperWireOperation: Codable, Sendable, Hashable {
    public var op: String
    public var session: String?
    public var path: String?
    public var restoreTo: String?
    public var identifier: String?

    public init(op: String, session: String? = nil, path: String? = nil, restoreTo: String? = nil, identifier: String? = nil) {
        self.op = op
        self.session = session
        self.path = path
        self.restoreTo = restoreTo
        self.identifier = identifier
    }

    public init(_ operation: AdminOperation) {
        switch operation {
        case .moveToHolding(let s, let p): self.init(op: "moveToHolding", session: s.uuidString, path: p)
        case .restoreFromHolding(let s, let p, let to): self.init(op: "restoreFromHolding", session: s.uuidString, path: p, restoreTo: to)
        case .purgeHolding(let s): self.init(op: "purgeHolding", session: s.uuidString)
        case .bootoutSystem(let l): self.init(op: "bootout", identifier: l)
        case .bootstrapSystem(let p): self.init(op: "bootstrap", path: p)
        case .pkgForget(let id): self.init(op: "pkgForget", identifier: id)
        }
    }

    /// 헬퍼 쪽 해석. 실패하면 사유 코드.
    public func operation() -> Result<AdminOperation, SecureFileOperations.Failure> {
        typealias F = SecureFileOperations.Failure
        func uuid() -> UUID? { session.flatMap(UUID.init(uuidString:)) }
        switch op {
        case "moveToHolding":
            guard let s = uuid() else { return .failure(F("bad-session")) }
            guard let path else { return .failure(F("bad-path")) }
            return .success(.moveToHolding(session: s, path: path))
        case "restoreFromHolding":
            guard let s = uuid() else { return .failure(F("bad-session")) }
            guard let path else { return .failure(F("bad-path")) }
            return .success(.restoreFromHolding(session: s, originalPath: path, restoreTo: restoreTo))
        case "purgeHolding":
            guard let s = uuid() else { return .failure(F("bad-session")) }
            return .success(.purgeHolding(session: s))
        case "bootout":
            guard let identifier else { return .failure(F("bad-identifier")) }
            return .success(.bootoutSystem(label: identifier))
        case "bootstrap":
            guard let path else { return .failure(F("bad-path")) }
            return .success(.bootstrapSystem(plistPath: path))
        case "pkgForget":
            guard let identifier else { return .failure(F("bad-identifier")) }
            return .success(.pkgForget(id: identifier))
        default:
            return .failure(F("unknown-op"))
        }
    }
}

public struct HelperWireRequest: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    /// 한 요청의 최대 작업 수·크기 (비정상 요청으로 헬퍼를 묶어 두지 못하게)
    public static let maxOperations = 10_000
    public static let maxBytes = 16 << 20

    public var version: Int
    public var operations: [HelperWireOperation]

    public init(operations: [HelperWireOperation], version: Int = HelperWireRequest.currentVersion) {
        self.version = version
        self.operations = operations
    }
}

public struct HelperWireResult: Codable, Sendable, Hashable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

public struct HelperWireReply: Codable, Sendable, Hashable {
    /// 요청 전체를 거부한 사유 (형식 오류 등). 있으면 `results`는 비어 있다.
    public var error: String?
    public var results: [HelperWireResult]

    public init(results: [HelperWireResult], error: String? = nil) {
        self.results = results
        self.error = error
    }
}

// MARK: 헬퍼 쪽

/// 헬퍼가 내보내는 객체. 요청을 한 번에 하나씩 처리한다.
public final class PrivilegedHelperService: NSObject, PrivilegedHelperXPC, @unchecked Sendable {
    public let processor: PrivilegedCommandProcessor
    private let lock = NSLock()

    public init(processor: PrivilegedCommandProcessor) {
        self.processor = processor
    }

    public func ping(withReply reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperWireRequest.currentVersion)
    }

    public func perform(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        reply(handle(request))
    }

    /// JSON 요청 → JSON 응답 (XPC 없이 테스트할 수 있게 분리)
    public func handle(_ request: Data) -> Data {
        let reply = lock.withLock { process(request) }
        return (try? JSONEncoder().encode(reply)) ?? Data()
    }

    private func process(_ data: Data) -> HelperWireReply {
        guard data.count <= HelperWireRequest.maxBytes,
              let request = try? JSONDecoder().decode(HelperWireRequest.self, from: data) else {
            return HelperWireReply(results: [], error: "bad-request")
        }
        guard request.version == HelperWireRequest.currentVersion else { return HelperWireReply(results: [], error: "bad-version") }
        guard request.operations.count <= HelperWireRequest.maxOperations else { return HelperWireReply(results: [], error: "bad-request") }
        let results = request.operations.map { wire -> HelperWireResult in
            switch wire.operation() {
            case .failure(let f):
                return HelperWireResult(ok: false, message: f.code)
            case .success(let op):
                let r = processor.perform(op)
                return HelperWireResult(ok: r.succeeded, message: r.message)
            }
        }
        return HelperWireReply(results: results)
    }
}

/// 헬퍼 리스너 위임. 새 연결마다 클라이언트 코드 서명 요구사항을 건다 —
/// `setCodeSigningRequirement`는 메시지마다 보낸 프로세스의 audit token으로 검사하므로 PID 재사용 공격에 안전하고,
/// 요구사항을 만족하지 않는 클라이언트의 메시지는 처리되지 않고 연결이 무효화된다 (PID 기반 검증 금지 — plan.md 5.3).
public final class PrivilegedHelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public let clientRequirement: String
    public let service: PrivilegedHelperService

    public init(clientRequirement: String, service: PrivilegedHelperService) {
        self.clientRequirement = clientRequirement
        self.service = service
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = PrivilegedHelperInterface.make()
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
