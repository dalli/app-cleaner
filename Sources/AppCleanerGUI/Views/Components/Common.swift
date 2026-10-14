import AppKit
import CleanerCore
import SwiftUI

/// 상태 배너 (주의: 실행 중·관리자 암호·색인 불완전 / 공유 / 안내)
struct Banner<Trailing: View>: View {
    var tone: Tone
    var systemImage: String
    var text: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    init(tone: Tone, systemImage: String, text: String, detail: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.tone = tone
        self.systemImage = systemImage
        self.text = text
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tone.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fontWeight(.medium)
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            trailing()
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tone.border))
        .accessibilityElement(children: .combine)
    }
}

/// 앱 아이콘 (NSWorkspace). 파일이 없으면 기본 앱 아이콘.
struct AppIcon: View {
    var path: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: IconCache.shared.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for path: String) -> NSImage {
        if let i = cache[path] { return i }
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .applicationBundle)
        cache[path] = icon
        return icon
    }
}

/// 앱이 없음을 나타내는 점선 아이콘 (S5 그룹 행)
struct MissingAppIcon: View {
    var name: String
    var size: CGFloat = 32

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.secondary)
            )
            .accessibilityHidden(true)
    }
}

/// 요약 칸 (S3 3칸, S6)
struct SummaryTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 필터 칩 (S1 출처, S5 신뢰도)
struct FilterChip: View {
    var title: String
    var count: Int
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.callout.weight(isOn ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(
                    Capsule().fill(isOn ? Color.accentColor : Color.clear)
                )
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor : Color(nsColor: .separatorColor)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// 하단 바 (S2, S5)
struct BottomBar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) { content() }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }
}

/// 키-값 한 줄 (정보 패널, 설정)
struct InfoRow: View {
    var title: String
    var value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 3상태 체크박스가 있는 행 헤더의 공통 높이
enum Metrics {
    static let minRowHeight: CGFloat = 34
    static let infoPanelWidth: CGFloat = 300
}
