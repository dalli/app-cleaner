import CleanerCore
import Foundation
@testable import AppCleanerGUI

/// 지연 없는 데모 엔진 (파일을 건드리지 않는다)
func fastEngine(unresponsive: Bool = false) -> DemoCleanerEngine {
    var o = DemoCleanerEngine.Options()
    o.delayScale = 0
    o.simulateUnresponsiveApp = unresponsive
    return DemoCleanerEngine(options: o)
}

let wordURL = URL(filePath: "/Applications/Microsoft Word.app")
let slackURL = URL(filePath: "/Applications/Slack.app")

func candidate(_ path: String, _ confidence: Confidence = .high, nature: DataNature = .settings,
               share: ShareStatus = .exclusive, protection: ProtectionReason? = nil, selected: Bool = true,
               size: Int64 = 100, children: [Candidate] = []) -> Candidate {
    Candidate(url: URL(filePath: path), category: children.isEmpty ? .preferences : .container,
              confidence: confidence, nature: nature, share: share, protection: protection,
              isSelected: selected, size: size, children: children)
}

/// 조건이 참이 될 때까지 기다린다 (MainActor 작업이 돌 수 있게 양보)
@MainActor
/// CI 러너는 병렬 테스트 부하로 느릴 수 있어 넉넉히 기다린다.
func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}
