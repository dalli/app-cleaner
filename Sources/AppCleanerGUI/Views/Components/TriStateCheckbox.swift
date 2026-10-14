import AppKit
import SwiftUI

/// macOS 기본 체크박스(NSButton)의 3상태 버전.
/// VoiceOver는 레이블과 함께 "선택됨 / 선택 안 됨 / 일부 선택됨"을 읽는다.
struct TriStateCheckbox: NSViewRepresentable {
    var state: CheckState
    var label: String
    var isEnabled: Bool = true
    var action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked))
        button.allowsMixedState = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.refusesFirstResponder = true
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        switch state {
        case .on: button.state = .on
        case .off: button.state = .off
        case .mixed: button.state = .mixed
        }
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityValueDescription(state.spokenValue)
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}
