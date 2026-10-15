import CleanerCore
import Foundation

/// 정기 고아 스캔 (ui-ux.md S10 "백그라운드 실행 방식").
///
/// - 1시간마다(`NSBackgroundActivityScheduler` — 시스템이 전력 상황에 맞춰 미룰 수 있음) 예정이 지났는지 확인한다.
/// - 스캔은 번들의 CLI를 자식 프로세스로 실행한다 (`appcleaner orphans --min-confidence high --json`).
///   스캔에 쓴 메모리는 자식이 끝나면 돌아오므로 Sentinel 상주 메모리가 늘지 않고,
///   엔진이 같으므로 인벤토리 캐시·유지 목록을 본 앱과 그대로 공유한다.
@MainActor
final class PeriodicScanRunner {
    enum RunError: Error {
        case cliNotFound
        case failed(status: Int32)
    }

    static let checkInterval: TimeInterval = 3600
    static let activityID = SentinelIdentity.bundleID + ".periodicScan"

    private var scheduler: NSBackgroundActivityScheduler?
    private(set) var isScanning = false

    /// 확인 주기마다 `tick`을 부른다 (이미 예약돼 있으면 그대로)
    func start(tick: @escaping @MainActor () async -> Void) {
        guard scheduler == nil else { return }
        let s = NSBackgroundActivityScheduler(identifier: Self.activityID)
        s.repeats = true
        s.interval = Self.checkInterval
        s.tolerance = Self.checkInterval / 4
        s.qualityOfService = .utility
        s.schedule { completion in
            Task { @MainActor in
                await tick()
                completion(.finished)
            }
        }
        scheduler = s
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    /// CLI로 고아 스캔 (높음만). 이미 스캔 중이면 nil
    func scan(cli: URL) async throws -> OrphanScanReport? {
        guard !isScanning else { return nil }
        isScanning = true
        defer { isScanning = false }
        let data = try await Task.detached(priority: .utility) { () throws -> Data in
            let process = Process()
            process.executableURL = cli
            process.arguments = ["orphans", "--min-confidence", "high", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RunError.failed(status: process.terminationStatus) }
            return data
        }.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OrphanScanReport.self, from: data)
    }

    /// 본 앱 번들의 CLI, 개발 빌드(`swift build`)에서는 Sentinel 실행 파일 옆의 `appcleaner`
    static func locateCLI(mainApp: URL?) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let mainApp { candidates.append(SentinelIdentity.cliURL(inApp: mainApp)) }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("appcleaner"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
