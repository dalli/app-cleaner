import AppKit
import CleanerCore

// App Cleaner Sentinel — 메뉴 막대 상주 (ui-ux.md S10). 휴지통 감시와 정기 고아 스캔 알림.
// 본 앱 번들의 Contents/Library/LoginItems에 들어가고 본 앱 설정(S7)이 SMAppService.loginItem으로 등록한다.
// 창·SwiftUI 없이 NSStatusItem 메뉴 하나만 둔다 (상주 메모리를 작게 — plan.md 8.3).
let options = SentinelOptions(arguments: CommandLine.arguments)
let app = NSApplication.shared
let controller = SentinelController(options: options)
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
