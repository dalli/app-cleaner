import CleanerCore
import SwiftUI

/// Homebrew로 설치한 formula·cask 목록. 파일 이동으로는 의존성·링크·Homebrew 기록을 함께 정리할 수 없어
/// 지우지 않고 `brew uninstall` 명령을 복사하게 한다 (docs/packages.md).
struct HomebrewView: View {
    @Environment(AppModel.self) private var model

    private var vm: HomebrewViewModel { model.homebrew }

    var body: some View {
        @Bindable var vm = model.homebrew
        VStack(alignment: .leading, spacing: 14) {
            Banner(tone: .neutral, systemImage: "info.circle", text: L("Homebrew 항목은 App Cleaner가 직접 지우지 않습니다"),
                   detail: L("의존성·링크·Homebrew 기록이 함께 정리되도록 터미널에서 brew uninstall로 제거하세요. 항목을 고르면 제거 뒤에도 남는 설정·데이터·캐시 위치와 제거 명령을 볼 수 있습니다."))
            kindFilter
            HStack(alignment: .top, spacing: 14) {
                HomebrewTable(vm: vm, system: model.system)
                if let item = vm.focusedItem {
                    HomebrewDetailPanel(item: item, vm: vm, system: model.system)
                        .frame(width: Metrics.infoPanelWidth)
                }
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .navigationTitle(HomebrewViewModel.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L("정렬"), selection: $vm.sort) {
                        ForEach(HomebrewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(L("정렬: %@", vm.sort.title), systemImage: "arrow.up.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .fixedSize()
                .help(L("정렬"))
            }
            ToolbarItem(placement: .primaryAction) {
                SearchField(text: $vm.search, prompt: L("이름 검색"))
                    .frame(width: 240)
            }
        }
        .task {
            if !vm.hasLoaded { await vm.load() }
        }
    }

    private var kindFilter: some View {
        HStack(spacing: 6) {
            FilterChip(title: L("전체"), count: vm.count(for: nil), isOn: vm.kindFilter == nil) { vm.kindFilter = nil }
            ForEach(HomebrewKind.allCases, id: \.self) { k in
                FilterChip(title: k.title, count: vm.count(for: k), isOn: vm.kindFilter == k) { vm.kindFilter = k }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Homebrew 항목 종류 필터"))
    }

    private var footer: some View {
        HStack {
            Text(L("Formula %lld개 · Cask %lld개 · %@", vm.count(for: .formula), vm.count(for: .cask),
                   Fmt.total(vm.totalSize, approximate: vm.sizeIsApproximate)))
            Spacer()
            Text(L("의존성으로 설치됨 %lld개", vm.dependencyCount))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct HomebrewTable: View {
    @Bindable var vm: HomebrewViewModel
    var system: SystemActions

    private let kindWidth: CGFloat = 80
    private let reasonWidth: CGFloat = 110
    private let sizeWidth: CGFloat = 90

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.isLoading && vm.items.isEmpty {
                ProgressView(L("Homebrew 설치 항목을 확인하는 중…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredItems.isEmpty {
                Text(vm.items.isEmpty ? L("Homebrew로 설치한 항목이 없습니다") : L("검색 결과가 없습니다"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $vm.focusedID) {
                    ForEach(vm.filteredItems) { item in
                        row(item).tag(item.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let item = vm.items.first(where: { $0.id == id }) {
                        Button(L("제거 명령 복사")) { system.copyToPasteboard(item.uninstallCommand) }
                        Button(L("Finder에서 보기")) { system.reveal(path: item.location.path) }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("이름")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("종류")).frame(width: kindWidth, alignment: .leading)
            Text(L("설치 방식")).frame(width: reasonWidth, alignment: .leading)
            Text(L("크기")).frame(width: sizeWidth, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func row(_ item: HomebrewItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.semibold).lineLimit(1)
                Text(([item.version] + item.apps.map(Optional.some)
                      + [vm.extraRelatedCount(item) > 0 ? L("관련 항목 %lld", vm.extraRelatedCount(item)) : nil])
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.kind.title)
                .foregroundStyle(.secondary)
                .frame(width: kindWidth, alignment: .leading)
            Text(item.installedOnRequest ? L("사용자 설치") : L("의존성"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: reasonWidth, alignment: .leading)
            Group {
                if let size = vm.size(of: item) {
                    Text(Fmt.bytes(size)).monospacedDigit()
                } else if vm.isCalculating(item) {
                    Text(L("계산 중…")).foregroundStyle(.secondary)
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                }
            }
            .frame(width: sizeWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .help(L("제거 명령: %@", item.uninstallCommand))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(item))
    }

    private func accessibility(_ item: HomebrewItem) -> String {
        var parts = [item.name, item.kind.title]
        if let v = item.version { parts.append(L("버전 %@", v)) }
        parts.append(item.installedOnRequest ? L("사용자 설치") : L("의존성"))
        if let size = vm.size(of: item) { parts.append(Fmt.spokenSize(size)) }
        return parts.joined(separator: ", ")
    }
}

/// 선택한 항목의 관련 경로 (설치 위치·링크·남는 설정과 데이터·캐시). 지우지 않고 보여 주기만 한다.
private struct HomebrewDetailPanel: View {
    let item: HomebrewItem
    @Bindable var vm: HomebrewViewModel
    var system: SystemActions

    /// 링크가 많은 formula(coreutils 등)는 앞부분만 보여 준다
    private let linkLimit = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold))
                    Text([item.kind.title, item.version, item.installedOnRequest ? L("사용자 설치") : L("의존성")]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                command(L("제거 명령"), item.uninstallCommand)
                if let zap = item.zapCommand { command(L("zap 규칙 파일까지 제거"), zap) }
                ForEach(vm.relatedGroups(item), id: \.kind) { group in
                    section(group.kind, group.paths)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        .task(id: item.id) { await vm.loadRelatedSizes(for: item) }
    }

    private func command(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button { system.copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("복사"))
                    .accessibilityLabel(L("복사"))
            }
        }
    }

    private func section(_ kind: HomebrewRelatedPath.Kind, _ paths: [HomebrewRelatedPath]) -> some View {
        let shown = kind == .link ? Array(paths.prefix(linkLimit)) : paths
        return VStack(alignment: .leading, spacing: 6) {
            Text(kind.title).font(.subheadline.weight(.semibold))
            if let note = kind.note(item) {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shown) { path in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.path(path.url.path))
                        .font(.caption)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if kind != .link {
                        Group {
                            if let size = vm.relatedSize(path) {
                                Text(Fmt.bytes(size))
                            } else if vm.isCalculatingRelated(path) {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Button { system.reveal(path: path.url.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless)
                        .help(L("Finder에서 보기"))
                        .accessibilityLabel(L("Finder에서 보기"))
                }
            }
            if paths.count > shown.count {
                Text(L("외 %lld개", paths.count - shown.count)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
