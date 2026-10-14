import Foundation
import CleanerCore

/// 엔진 선택 — 통합 단계에서 LiveCleanerEngine을 연결한다.
enum EngineFactory {
    static func make(demo: Bool) -> (any CleanerEngine)? {
        nil
    }
}
