import CleanerCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
                } detail: {
                    DetailView()
                }
            }
        }
        // .app을 창 어디에 놓아도 S2 (드래그 중에는 창 전체를 강조)
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            loadURLs(from: providers) { urls in model.handleDrop(urls) }
            return true
        }
        .overlay {
            if model.isDropTargeted {
                DropHighlight()
            }
        }
        .sheet(item: $model.cleanupFlow) { flow in
            CleanupSheet(flow: flow)
        }
    }

    private func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(box.urls) }
        }
    }
}

private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(10)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 44, weight: .regular))
                Text(L("놓으면 바로 검사합니다"))
                    .font(.title3.weight(.semibold))
                Text(L("검사만 하고 아무것도 지우지 않습니다"))
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 사이드바

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<SidebarRoute?>(
            get: { model.route == .settings ? nil : model.route },
            set: { if let r = $0 { model.select(r) } }
        )
        List(selection: selection) {
            Label(L("앱 제거"), systemImage: "square.grid.2x2")
                .tag(SidebarRoute.apps)
            Label(L("고아 잔여물"), systemImage: "magnifyingglass")
                .badge(model.orphans.badgeCount ?? 0)
                .tag(SidebarRoute.orphans)
                .accessibilityValue(model.orphans.badgeCount.map { L("그룹 %lld개", $0) } ?? "")
            Label(L("삭제 기록"), systemImage: "clock.arrow.circlepath")
                .tag(SidebarRoute.history)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SidebarSettingsRow(isSelected: model.route == .settings) { model.select(.settings) }
                PermissionCard(permissions: model.permissions) { model.openPermissionSettings() }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

private struct SidebarSettingsRow: View {
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(L("설정"), systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 맨 아래 권한 상태 카드 → 설정의 권한 섹션
struct PermissionCard: View {
    var permissions: PermissionStatus
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("권한 상태")).font(.caption.weight(.semibold))
                statusLine(ok: permissions.fullDiskAccess == .granted,
                           text: permissions.fullDiskAccess == .granted ? L("전체 디스크 접근 허용됨") : L("전체 디스크 접근 필요"))
                statusLine(ok: false, neutral: true, text: L("관리자 헬퍼 미설치"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("설정의 권한 섹션 열기"))
        .accessibilityHint(L("설정의 권한 섹션 열기"))
    }

    private func statusLine(ok: Bool, neutral: Bool = false, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : (neutral ? "minus.circle.fill" : "exclamationmark.circle.fill"))
                .foregroundStyle(ok ? Tone.positive.foreground : (neutral ? Tone.neutral.foreground : Tone.caution.foreground))
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 상세

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.route {
        case .apps:
            if let completion = model.completion, completion.origin == .appRemoval {
                CompletionView(completion: completion)
            } else if let inspector = model.inspector {
                InspectorView(vm: inspector)
                    .id(ObjectIdentifier(inspector))
            } else {
                AppListView()
            }
        case .orphans:
            if let completion = model.completion, completion.origin == .orphans {
                CompletionView(completion: completion)
            } else {
                OrphansView()
            }
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}
