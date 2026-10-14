import SwiftUI

/// 3상태 체크박스 (전체 / 일부 / 없음).
/// VoiceOver는 레이블과 함께 "선택됨 / 선택 안 됨 / 일부 선택됨"을 읽는다.
///
/// List(NSOutlineView) 행 안에서 NSButton을 쓰면 행 높이 계산이 어긋나므로 SwiftUI로 그린다.
struct TriStateCheckbox: View {
    var state: CheckState
    var label: String
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(filled ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(filled ? Color.accentColor : Color(nsColor: .tertiaryLabelColor), lineWidth: filled ? 0 : 1)
                switch state {
                case .on:
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                case .mixed:
                    Capsule().fill(.white).frame(width: 8, height: 2)
                case .off:
                    EmptyView()
                }
            }
            .frame(width: 14, height: 14)
            .opacity(isEnabled ? 1 : 0.4)
            .padding(3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityValue(state.spokenValue)
        .accessibilityAddTraits(.isButton)
    }

    private var filled: Bool { state != .off }
}
