import AppKit
import CleanerCore
import SwiftUI

/// 배지·배너 색 (ui-ux.md S9). 라이트는 캔버스 값, 다크는 밝은 글자 + 반투명 배경.
/// 글자 대비 4.5:1 이상을 위해 글자색은 시스템 강조색보다 짙게(라이트)·밝게(다크) 쓴다.
enum Tone: Sendable {
    case accent      // 신뢰도 높음, 안내
    case caution     // 신뢰도 보통, 실행 중, 주의
    case neutral     // 신뢰도 낮음, 보호됨
    case positive    // 재생성 가능, 복원 가능
    case settings    // 설정
    case userData    // 사용자 데이터
    case shared      // 공유

    private var hex: (lightFG: UInt32, lightBG: UInt32, darkFG: UInt32) {
        switch self {
        case .accent: return (0x1E40AF, 0xE3ECFD, 0x9DBBF7)
        case .caution: return (0x8A4B00, 0xFDF0D9, 0xF5C37A)
        case .neutral: return (0x4A4A4F, 0xEDEDEB, 0xC7C7CC)
        case .positive: return (0x166534, 0xE6F4EA, 0x8BD9A4)
        case .settings: return (0x115E59, 0xDDF1EF, 0x7FD4CB)
        case .userData: return (0x9A3412, 0xFDE7DC, 0xF6A57E)
        case .shared: return (0x5B2C9E, 0xEFE7FB, 0xC6A8F2)
        }
    }

    var foreground: Color {
        let h = hex
        return Color(nsColor: .dynamic(light: h.lightFG, dark: h.darkFG))
    }

    var background: Color {
        let h = hex
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: h.darkFG).withAlphaComponent(0.18) : NSColor(hex: h.lightBG)
        })
    }

    var border: Color {
        let h = hex
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(hex: h.darkFG).withAlphaComponent(0.35) : NSColor(hex: h.lightFG).withAlphaComponent(0.22)
        })
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]).map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua } ?? false }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) }
    }
}

extension Confidence {
    var tone: Tone {
        switch self {
        case .high: return .accent
        case .medium: return .caution
        case .low: return .neutral
        }
    }
}

extension DataNature {
    var tone: Tone {
        switch self {
        case .regenerable: return .positive
        case .settings: return .settings
        case .userData: return .userData
        case .synced: return .neutral
        }
    }
}

extension SessionStatus {
    var tone: Tone {
        switch self {
        case .restorable: return .positive
        case .partiallyRestorable: return .caution
        case .restored: return .accent
        case .notRestorable: return .neutral
        }
    }
}

extension Color {
    /// 6개월 이상 사용하지 않은 앱 강조 (S1)
    static let staleAccent = Color(nsColor: .dynamic(light: 0x9A3412, dark: 0xF6A57E))
}
