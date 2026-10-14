import CleanerCore
import SwiftUI

/// 배지: 항상 글자를 포함한다 (색만으로 구분하지 않음, ui-ux.md 1장)
struct Badge: View {
    var text: String
    var tone: Tone
    var systemImage: String?

    init(_ text: String, tone: Tone, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct ConfidenceBadge: View {
    var confidence: Confidence
    var body: some View {
        Badge(confidence.title, tone: confidence.tone)
            .accessibilityLabel(confidence.fullTitle)
            .help(confidence.fullTitle)
    }
}

struct NatureBadge: View {
    var nature: DataNature
    var body: some View {
        Badge(nature.title, tone: nature.tone, systemImage: nature == .synced ? "lock.fill" : nil)
    }
}

struct SharedBadge: View {
    var share: ShareStatus
    var body: some View {
        if share.isShared {
            Badge(L("공유"), tone: .shared, systemImage: "person.2.fill")
                .help(share.usageText ?? "")
        }
    }
}

struct ProtectedBadge: View {
    var body: some View {
        Badge(L("보호됨"), tone: .neutral, systemImage: "lock.fill")
    }
}

struct RunningBadge: View {
    var body: some View {
        Badge(L("실행 중"), tone: .caution)
    }
}

struct StatusBadge: View {
    var status: SessionStatus
    var body: some View {
        Badge(status.title, tone: status.tone)
    }
}

/// 후보 행의 배지 묶음: 데이터 성격·공유 → 신뢰도 (S9 항목 행 순서)
struct CandidateBadges: View {
    var candidate: Candidate

    var body: some View {
        HStack(spacing: 4) {
            if candidate.protection != nil || candidate.nature == .synced {
                ProtectedBadge()
            } else {
                NatureBadge(nature: candidate.nature)
            }
            SharedBadge(share: candidate.share)
            ConfidenceBadge(confidence: candidate.confidence)
        }
    }
}

/// VoiceOver 레이블 (ui-ux.md 4.4)
/// "UBF8T346G9.Office, 3.1 기가바이트, 신뢰도 높음, 설정, 공유: Excel 외 2개 앱 사용 중, 선택 안 됨"
enum AccessibilityText {
    static func candidate(_ c: Candidate, name: String? = nil, state: CheckState?) -> String {
        var parts = [name ?? c.displayName, Fmt.spokenSize(c.size), c.confidence.fullTitle]
        if c.protection != nil || c.nature == .synced {
            parts.append(L("보호됨, 선택할 수 없음"))
        } else {
            parts.append(c.nature.title)
        }
        if let shared = c.share.spokenText { parts.append(shared) }
        if let state, c.isSelectable { parts.append(state.spokenValue) }
        return parts.joined(separator: ", ")
    }
}
