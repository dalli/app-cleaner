import CoreServices
import Foundation

/// 폴더 변경 감시 (FSEvents). 무엇이 바뀌었는지는 보지 않고 "바뀌었다"는 신호만 넘긴다 —
/// 새로 들어온 앱 판단은 `TrashSnapshot` 비교가 맡는다 (이름 변경·중복 이벤트에 영향받지 않도록).
@MainActor
final class TrashMonitor {
    private final class Box {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }

    let directory: URL
    private let latency: CFTimeInterval
    private let box: Box
    private var stream: FSEventStreamRef?

    init(directory: URL, latency: CFTimeInterval = 1.0, onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.latency = latency
        self.box = Box(onChange)
    }

    /// 감시 시작. 스트림을 만들지 못하면 false
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            // 스트림을 메인 큐에 붙였으므로 메인 스레드에서 불린다
            MainActor.assumeIsolated { box.handler() }
        }
        // 폴더 단위 이벤트로 충분하다 (파일 단위 이벤트는 휴지통이 클 때 콜백만 늘린다). NoDefer: 첫 변경은 바로 알린다.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    var isRunning: Bool { stream != nil }
}
