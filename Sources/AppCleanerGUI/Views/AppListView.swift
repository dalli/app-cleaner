import CleanerCore
import SwiftUI

/// S1 앱 제거 — 앱 목록
struct AppListView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    private var vm: AppListViewModel { model.appList }

    var body: some View {
        @Bindable var vm = model.appList
        VStack(alignment: .leading, spacing: 14) {
            DropZone()
            sourceFilter
            AppTable(vm: vm) { app in model.openApp(at: app.url) }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .navigationTitle(L("앱 제거"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L("정렬"), selection: $vm.sort) {
                    ForEach(AppSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(L("정렬"))
            }
            ToolbarItem(placement: .primaryAction) {
                SearchField(text: $vm.search, prompt: L("앱 이름 또는 번들 ID"))
                    .focused($searchFocused)
                    .frame(width: 240)
            }
        }
        .task {
            if !vm.hasLoaded { await vm.load() }
        }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onAppear {
            if model.searchFocusRequest > 0 { searchFocused = true }
        }
    }

    private var sourceFilter: some View {
        HStack(spacing: 6) {
            FilterChip(title: L("전체"), count: vm.count(for: nil), isOn: vm.sourceFilter == nil) { vm.sourceFilter = nil }
            ForEach(InstallSource.allCases, id: \.self) { s in
                FilterChip(title: s.title, count: vm.count(for: s), isOn: vm.sourceFilter == s) { vm.sourceFilter = s }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("설치 출처 필터"))
    }

    private var footer: some View {
        HStack {
            Text(L("앱 %lld개 · %@", vm.apps.count, Fmt.total(vm.totalSize, approximate: vm.sizeIsApproximate)))
            Spacer()
            Text(L("Apple 기본 앱(com.apple.*)은 목록에 표시하지 않습니다."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// 검색 칸 (⌘F로 포커스)
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(L("앱 검색"))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("검색어 지우기"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 목록 위 고정 드롭 영역
private struct DropZone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("제거할 앱을 여기에 끌어다 놓으세요")).fontWeight(.semibold)
                Text(L("Finder나 Dock에서 .app을 놓으면 바로 잔여물을 검사합니다. 검사만 하고 아무것도 지우지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.accentColor.opacity(model.isDropTargeted ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .accessibilityElement(children: .combine)
    }
}

/// 앱 목록 표 (아이콘, 이름 + 버전 · 번들 ID, 출처, 크기, 마지막 사용)
private struct AppTable: View {
    @Bindable var vm: AppListViewModel
    var open: (InstalledApp) -> Void

    private let sourceWidth: CGFloat = 110
    private let sizeWidth: CGFloat = 90
    private let lastUsedWidth: CGFloat = 110

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.isLoading && vm.apps.isEmpty {
                ProgressView(L("설치된 앱을 확인하는 중…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredApps.isEmpty {
                Text(vm.search.isEmpty ? L("표시할 앱이 없습니다") : L("검색 결과가 없습니다"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.focusedID) {
                    ForEach(vm.filteredApps) { app in
                        row(app)
                            .tag(app.id)
                            .contentShape(Rectangle())
                            .onTapGesture { open(app) }
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { _ in
                } primaryAction: { ids in
                    if let id = ids.first, let app = vm.apps.first(where: { $0.id == id }) { open(app) }
                }
                .onKeyPress(.return) {
                    guard let app = vm.focusedApp else { return .ignored }
                    open(app)
                    return .handled
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("앱")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("출처")).frame(width: sourceWidth, alignment: .leading)
            Text(L("크기")).frame(width: sizeWidth, alignment: .trailing)
            Text(L("마지막 사용")).frame(width: lastUsedWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func row(_ app: InstalledApp) -> some View {
        let stale = AppListViewModel.isLongUnused(app)
        return HStack(spacing: 12) {
            HStack(spacing: 10) {
                AppIcon(path: app.url.path, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(app.name).fontWeight(.semibold).lineLimit(1)
                        if app.isRunning { RunningBadge() }
                    }
                    Text([app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(app.source.title)
                .foregroundStyle(.secondary)
                .frame(width: sourceWidth, alignment: .leading)
            Group {
                if app.size == nil {
                    Text(L("계산 중…")).foregroundStyle(.secondary)
                } else {
                    Text(Fmt.size(app.size)).monospacedDigit()
                }
            }
            .frame(width: sizeWidth, alignment: .trailing)
            Text(Fmt.relative(app.lastUsed))
                .fontWeight(stale ? .semibold : .regular)
                .foregroundStyle(stale ? Color.staleAccent : Color.secondary)
                .frame(width: lastUsedWidth, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(app, stale: stale))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(L("잔여물 검사"))
    }

    private func accessibility(_ app: InstalledApp, stale: Bool) -> String {
        var parts = [app.name]
        if let v = app.version { parts.append(L("버전 %@", v)) }
        if app.isRunning { parts.append(L("실행 중")) }
        parts.append(app.source.title)
        parts.append(Fmt.spokenSize(app.size))
        parts.append(L("마지막 사용 %@", Fmt.relative(app.lastUsed)))
        if stale { parts.append(L("6개월 이상 사용하지 않음")) }
        return parts.joined(separator: ", ")
    }
}
