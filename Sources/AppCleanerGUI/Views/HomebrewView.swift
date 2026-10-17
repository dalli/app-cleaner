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
                   detail: L("의존성·링크·Homebrew 기록이 함께 정리되도록 터미널에서 brew uninstall로 제거하세요. 항목을 우클릭하면 제거 명령을 복사할 수 있습니다."))
            kindFilter
            HomebrewTable(vm: vm, system: model.system)
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
                Text(([item.version] + item.apps.map(Optional.some)).compactMap { $0 }.joined(separator: " · "))
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
