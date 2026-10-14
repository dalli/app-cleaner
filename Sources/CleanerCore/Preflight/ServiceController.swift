import Foundation

/// launchd 서비스 1개에 대한 작업 결과
public struct ServiceActionResult: Sendable, Hashable {
    public var service: LaunchServiceRef
    /// nil이면 성공
    public var error: EngineText?

    public init(service: LaunchServiceRef, error: EngineText? = nil) {
        self.service = service
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

/// 백그라운드 서비스 중지·재등록 (plan.md 4.4 1단계, 6.2 복원).
/// 시스템 도메인 작업은 관리자 실행기로 한 번의 인증에 묶어 보낸다.
public protocol ServiceControlling: Sendable {
    func bootout(_ services: [LaunchServiceRef]) async -> [ServiceActionResult]
    func bootstrap(_ services: [LaunchServiceRef]) async -> [ServiceActionResult]
}

/// `launchctl` 기반 구현.
/// - 사용자 도메인: `/bin/launchctl bootout gui/<uid>/<label>`, `bootstrap gui/<uid> <plist>`
/// - 시스템 도메인: `privileged-op.sh bootout-system <label>` / `bootstrap-system <plist>` (관리자)
public struct LaunchctlServiceController: ServiceControlling {
    public let paths: SystemPaths
    public let runner: CommandRunning
    public let admin: AdminExecuting

    public static let launchctl = "/bin/launchctl"
    /// bootout: 이미 내려가 있으면 3(ESRCH) / 113(서비스 없음)을 돌려준다 → 목표 상태이므로 성공으로 본다.
    static let bootoutOK: Set<Int32> = [0, 3, 113]

    public init(paths: SystemPaths, runner: CommandRunning, admin: AdminExecuting) {
        self.paths = paths
        self.runner = runner
        self.admin = admin
    }

    public func bootout(_ services: [LaunchServiceRef]) async -> [ServiceActionResult] {
        var results: [ServiceActionResult] = []
        var systemOps: [(LaunchServiceRef, AdminOperation)] = []
        for s in services {
            guard SafeIdentifier.isValid(s.label), !SafeIdentifier.isApple(s.label) else {
                results.append(.init(service: s, error: EngineText(.serviceLabelInvalid, s.label)))
                continue
            }
            switch s.domain {
            case .user:
                do {
                    let out = try runner.run(Self.launchctl, ["bootout", "gui/\(paths.uid)/\(s.label)"])
                    if Self.bootoutOK.contains(out.status) {
                        results.append(.init(service: s))
                    } else {
                        results.append(.init(service: s, error: EngineText(.serviceStopFailedCode, s.label, String(out.status))))
                    }
                } catch {
                    results.append(.init(service: s, error: EngineText(.serviceStopFailedError, s.label, parts: [.describing(error)])))
                }
            case .system:
                systemOps.append((s, .bootoutSystem(label: s.label)))
            }
        }
        if !systemOps.isEmpty {
            let adminResults = await admin.run(systemOps.map(\.1))
            for (i, (s, _)) in systemOps.enumerated() {
                let r = i < adminResults.count ? adminResults[i] : nil
                results.append(.init(service: s, error: r?.succeeded == true ? nil
                    : EngineText(.systemServiceStopFailed, s.label, parts: [r?.reason ?? EngineText(.noResult)])))
            }
        }
        return order(results, like: services)
    }

    public func bootstrap(_ services: [LaunchServiceRef]) async -> [ServiceActionResult] {
        var results: [ServiceActionResult] = []
        var systemOps: [(LaunchServiceRef, AdminOperation)] = []
        for s in services {
            guard let plist = s.plistURL else {
                results.append(.init(service: s, error: EngineText(.plistLocationUnknown, s.label)))
                continue
            }
            switch s.domain {
            case .user:
                do {
                    let out = try runner.run(Self.launchctl, ["bootstrap", "gui/\(paths.uid)", plist.path])
                    results.append(.init(service: s, error: out.succeeded ? nil
                        : EngineText(.serviceReregisterFailedCode, s.label, String(out.status))))
                } catch {
                    results.append(.init(service: s, error: EngineText(.serviceReregisterFailedError, s.label, parts: [.describing(error)])))
                }
            case .system:
                guard let logical = AdminPaths.logicalPath(of: plist, root: paths.root) else {
                    results.append(.init(service: s, error: EngineText(.plistOutsideSystemRoot, plist.path)))
                    continue
                }
                systemOps.append((s, .bootstrapSystem(plistPath: logical)))
            }
        }
        if !systemOps.isEmpty {
            let adminResults = await admin.run(systemOps.map(\.1))
            for (i, (s, _)) in systemOps.enumerated() {
                let r = i < adminResults.count ? adminResults[i] : nil
                results.append(.init(service: s, error: r?.succeeded == true ? nil
                    : EngineText(.systemServiceReregisterFailed, s.label, parts: [r?.reason ?? EngineText(.noResult)])))
            }
        }
        return order(results, like: services)
    }

    private func order(_ results: [ServiceActionResult], like services: [LaunchServiceRef]) -> [ServiceActionResult] {
        var remaining = results
        var out: [ServiceActionResult] = []
        for s in services {
            if let i = remaining.firstIndex(where: { $0.service == s }) { out.append(remaining.remove(at: i)) }
        }
        return out + remaining
    }
}
