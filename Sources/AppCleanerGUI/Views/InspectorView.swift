import CleanerCore
import SwiftUI

/// S2 잔여물 검사기
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: InspectorViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch vm.phase {
            case .scanning:
                scanning
            case .failed(let message):
                failed(message)
            case .loaded:
                loaded
            }
        }
        .navigationTitle(vm.identity?.title ?? Fmt.lastComponent(vm.appURL.path))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.closeInspector() } label: {
                    Label(L("앱 목록"), systemImage: "chevron.left")
                }
                .help(L("앱 목록으로 돌아가기 (Esc)"))
            }
        }
        .onExitCommand { model.closeInspector() }
    }

    private var scanning: some View {
        VStack(spacing: 12) {
            AppIcon(path: vm.appURL.path, size: 64)
            ProgressView()
            Text(L("%@의 잔여물을 찾는 중…", Fmt.lastComponent(vm.appURL.deletingPathExtension().path)))
                .font(.headline)
            Text(L("검사만 하고 아무것도 지우지 않습니다")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Tone.caution.foreground)
            Text(L("검사하지 못했습니다")).font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button(L("앱 목록")) { model.closeInspector() }
                Button(L("다시 검사")) { Task { await vm.load() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var loaded: some View {
        InspectorHeader(vm: vm)
        Divider()
        let banners = vm.banners(permissions: model.permissions)
        if !banners.isEmpty || vm.isInTrash {
            VStack(spacing: 8) {
                // Sentinel "잔여물도 정리"로 연 앱 (ui-ux.md S10)
                if vm.isInTrash {
                    Banner(tone: .accent, systemImage: "trash",
                           text: L("이 앱은 이미 휴지통에 있습니다."),
                           detail: L("앱 본체는 휴지통에 그대로 두고 남은 잔여물만 정리합니다."))
                }
                ForEach(banners, id: \.stableID) { WarningBanner(warning: $0, appName: vm.identity?.title ?? "") }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        filterBar
        HStack(spacing: 0) {
            InspectorList(vm: vm)
            Divider()
            InfoPanel(vm: vm)
                .frame(width: Metrics.infoPanelWidth)
        }
        bottomBar
    }

    private var filterBar: some View {
        HStack(spacing: 14) {
            Picker(L("보기"), selection: $vm.viewFilter) {
                ForEach(InspectorViewFilter.allCases, id: \.self) { f in
                    Text("\(f.title) \(vm.count(for: f))").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(L("보기 필터"))
            Toggle(L("낮은 신뢰도 항목 표시 (%lld)", vm.lowConfidenceCount), isOn: $vm.showLowConfidence)
                .toggleStyle(.checkbox)
                .disabled(vm.lowConfidenceCount == 0)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var bottomBar: some View {
        BottomBar {
            let kept = vm.keptSummary
            Group {
                if kept.total > 0 {
                    Text(L("선택하지 않은 %lld개 항목(%@)은 그대로 남습니다.", kept.total, kept.breakdown))
                } else {
                    Text(L("찾은 항목을 모두 선택했습니다."))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            Spacer()
            Button(L("취소")) { model.closeInspector() }
            Button {
                model.openPreview()
            } label: {
                Text(L("정리 미리보기 · %lld개, %@", vm.selectedCount, Fmt.bytes(vm.selectedSize)))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!vm.canPreview)
            .help(L("아직 아무것도 옮기지 않습니다. 옮길 항목을 한 번 더 보여 줍니다. (⌘⌫)"))
        }
    }
}

// MARK: - 헤더

private struct InspectorHeader: View {
    @Bindable var vm: InspectorViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AppIcon(path: vm.appURL.path, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.identity?.title ?? "").font(.title2.weight(.bold))
                Text(meta).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(L("%@ 선택 · %lld개", Fmt.bytes(vm.selectedSize), vm.selectedCount))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(L("찾은 항목 %lld개 · %@", vm.allLeaves.count, Fmt.total(vm.totalSize, approximate: vm.sizeIsApproximate)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var meta: String {
        guard let id = vm.identity else { return "" }
        var parts: [String] = []
        if let v = id.version { parts.append(v) }
        parts.append(id.bundleID)
        if let team = id.teamID { parts.append("Team \(team)") }
        parts.append(id.source.title)
        return parts.joined(separator: " · ")
    }
}

/// S2 상태 배너
struct WarningBanner: View {
    @Environment(AppModel.self) private var model
    var warning: ScanWarning
    var appName: String

    var body: some View {
        switch warning {
        case .appRunning:
            Banner(tone: .caution, systemImage: "play.circle",
                   text: L("%@ 실행 중입니다.", Josa.iGa(appName)),
                   detail: L("정리를 시작하면 백그라운드 서비스를 먼저 멈춘 뒤 앱 종료를 요청합니다."))
        case .otherCopies(let urls):
            Banner(tone: .caution, systemImage: "doc.on.doc",
                   text: L("같은 번들 ID의 다른 사본이 있습니다."),
                   detail: urls.map { Fmt.path($0.path) }.joined(separator: ", ")) {
                if let first = urls.first {
                    Button(L("Finder에서 보기")) { model.system.reveal(path: first.path) }
                }
            }
        case .noFullDiskAccess:
            Banner(tone: .caution, systemImage: "lock.shield",
                   text: L("일부 항목을 찾지 못했을 수 있음"),
                   detail: L("전체 디스크 접근 권한이 없어 다른 앱의 컨테이너 등 보호된 폴더를 확인하지 못했습니다.")) {
                Button(L("시스템 설정 열기")) { model.system.openFullDiskAccessSettings() }
            }
        case .unreadable(let urls):
            Banner(tone: .caution, systemImage: "eye.slash",
                   text: L("권한 부족으로 읽지 못한 위치 %lld곳", urls.count),
                   detail: urls.prefix(3).map { Fmt.path($0.path) }.joined(separator: ", "))
        case .inventoryUnavailable:
            Banner(tone: .accent, systemImage: "info.circle",
                   text: L("설치 앱 목록을 아직 만들지 못했습니다."),
                   detail: L("다른 앱과 함께 쓰는지 확인할 수 없는 항목은 선택하지 않았습니다."))
        }
    }
}

// MARK: - 목록

private struct InspectorList: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: InspectorViewModel

    var body: some View {
        List(selection: $vm.focusedID) {
            ForEach(vm.rows) { row in
                OutlineRow(depth: depth(row), expandable: expandable(row), expanded: vm.isExpanded(row),
                           toggleExpanded: { vm.setExpanded(row, !vm.isExpanded(row)) }) {
                    switch row {
                    case .category(let section):
                        CategoryHeader(vm: vm, section: section)
                    case .item(let c, _):
                        CandidateRow(vm: vm, candidate: c)
                    }
                }
                .tag(row.id)
                .listRowBackground(background(row))
            }
            Text(L("로그인 항목 · 키체인 항목은 직접 지우지 않고, 정리 후 확인 방법을 안내합니다."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .selectionDisabled()
        }
        .listStyle(.inset)
        .onKeyPress(.space) {
            vm.toggleFocused()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            vm.setFocusedExpanded(false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            vm.setFocusedExpanded(true)
            return .handled
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, !id.hasPrefix("cat:") {
                Button(L("Finder에서 보기")) { model.system.reveal(path: id) }
                Button(L("경로 복사")) { model.system.copyToPasteboard(id) }
            }
        }
    }

    private func depth(_ row: InspectorRow) -> Int {
        if case .item(_, let d) = row { return d }
        return 0
    }

    private func expandable(_ row: InspectorRow) -> Bool {
        switch row {
        case .category: return true
        case .item(let c, _): return !c.children.isEmpty
        }
    }

    /// 보통 신뢰도인데 선택된 항목은 강조 (ui-ux.md 결정 2)
    private func background(_ row: InspectorRow) -> Color? {
        guard case .item(let c, _) = row, c.children.isEmpty else { return nil }
        return c.confidence == .medium && vm.state(of: c) == .on ? Tone.caution.background.opacity(0.55) : nil
    }
}

/// 들여쓰기 + 펼침 삼각형 (List 안의 DisclosureGroup은 macOS에서 행 재사용이 어긋나 직접 그린다)
struct OutlineRow<Content: View>: View {
    var depth: Int
    var expandable: Bool
    var expanded: Bool
    var toggleExpanded: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) {
            if depth > 0 { Color.clear.frame(width: CGFloat(depth) * 18, height: 1) }
            Group {
                if expandable {
                    Button(action: toggleExpanded) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(expanded ? L("접기") : L("펼치기"))
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
            }
            content()
        }
    }
}

private struct CategoryHeader: View {
    @Bindable var vm: InspectorViewModel
    var section: InspectorSection

    var body: some View {
        let state = vm.state(of: section)
        let leaves = section.allItems.flatMap(SelectionTree.leaves(of:))
        let size = leaves.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let selectable = leaves.contains(where: \.isSelectable)
        HStack(spacing: 10) {
            TriStateCheckbox(state: state, label: section.category.title, isEnabled: selectable) { vm.toggle(section) }
                .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(section.category.title).fontWeight(.semibold)
                Text(subtitle(count: leaves.count, state: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Fmt.bytes(size)).fontWeight(.semibold).monospacedDigit()
        }
        .frame(minHeight: Metrics.minRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.category.title), \(L("%lld개", leaves.count)), \(Fmt.spokenSize(size))")
        .accessibilityValue(state.spokenValue)
    }

    private func subtitle(count: Int, state: CheckState) -> String {
        var parts = [L("%lld개", count)]
        if let s = section.category.subtitle { parts.insert(s, at: 0) }
        if state == .mixed { parts.append(L("일부 선택")) }
        return parts.joined(separator: " · ")
    }
}

private struct CandidateRow: View {
    @Bindable var vm: InspectorViewModel
    var candidate: Candidate

    var body: some View {
        let state = vm.state(of: candidate)
        HStack(alignment: .center, spacing: 10) {
            if candidate.isSelectable {
                TriStateCheckbox(state: state, label: candidate.displayName) { vm.toggle(candidate) }
                    .fixedSize()
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName)
                    .fontWeight(candidate.children.isEmpty ? .regular : .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            CandidateBadges(candidate: candidate)
            Text(Fmt.size(candidate.size))
                .monospacedDigit()
                .foregroundStyle(candidate.size == nil ? .secondary : .primary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .frame(minHeight: Metrics.minRowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.candidate(candidate, state: state))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("선택 전환")) { vm.toggle(candidate) }
    }

    private var secondaryLine: String? {
        if let s = candidate.secondaryText { return s }
        if candidate.category == .containerItem { return nil }
        return Fmt.parent(candidate.path)
    }

    private var secondaryColor: Color {
        if candidate.share.isShared { return Tone.shared.foreground }
        if candidate.nature == .userData { return Tone.userData.foreground }
        if candidate.confidence == .medium { return Tone.caution.foreground }
        return .secondary
    }
}

// MARK: - 정보 패널

private struct InfoPanel: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: InspectorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let c = vm.focusedCandidate {
                    candidateInfo(c)
                } else if let cat = vm.focusedCategory, let section = vm.sections.first(where: { $0.category == cat }) {
                    categoryInfo(section)
                } else {
                    Text(L("항목을 선택하면 자세한 정보가 여기에 표시됩니다."))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private func candidateInfo(_ c: Candidate) -> some View {
        Text(L("선택한 항목")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
            Text(c.displayName).font(.headline).textSelection(.enabled)
            Text(Fmt.path(c.path))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 4) { CandidateBadges(candidate: c) }

        let emphasised = vm.isRiskySelection(c)
        if c.share.isShared {
            RiskBox(tone: .shared, emphasised: emphasised, systemImage: "person.2.fill",
                    title: L("다른 앱이 함께 사용합니다"),
                    lines: [c.share.usedBy.joined(separator: ", "), shareReason(c)].compactMap { $0 },
                    selectedNote: L("선택됨 — 정리 미리보기에서 이 항목을 따로 한 번 더 보여 드립니다."))
        }
        if c.nature == .userData {
            RiskBox(tone: .userData, emphasised: emphasised, systemImage: "doc.richtext",
                    title: L("사용자가 만든 데이터가 들어 있습니다"),
                    lines: [L("문서·데이터베이스처럼 앱을 다시 설치해도 되살아나지 않는 데이터일 수 있습니다.")],
                    selectedNote: L("선택됨 — 정리 미리보기에서 이 항목을 따로 한 번 더 보여 드립니다."))
        }
        if let p = c.protection {
            RiskBox(tone: .neutral, emphasised: false, systemImage: "lock.fill",
                    title: L("선택할 수 없는 항목"), lines: [p.explanation], selectedNote: nil)
        } else if c.nature == .synced {
            RiskBox(tone: .neutral, emphasised: false, systemImage: "lock.fill",
                    title: L("선택할 수 없는 항목"), lines: [ProtectionReason.iCloudData.explanation], selectedNote: nil)
        }

        InfoRow(title: L("크기"), value: sizeLine(c))
        if let m = c.lastModified { InfoRow(title: L("마지막 수정"), value: "\(Fmt.dateTime(m)) (\(Fmt.relative(m)))") }
        if !c.evidence.isEmpty {
            InfoRow(title: L("판정 근거"), value: c.evidence.map(\.detail.localized).joined(separator: "\n"))
            InfoRow(title: L("정보원"), value: orderedSources(c).joined(separator: ", "))
        }
        if let svc = c.launchService {
            InfoRow(title: L("백그라운드 서비스"),
                    value: svc.domain == .system ? L("%@ (시스템 서비스)", svc.label) : svc.label,
                    monospaced: true)
        }
        if let domain = c.preferencesDomain {
            InfoRow(title: L("환경설정 도메인"), value: domain, monospaced: true)
        }
        if c.requiresAdmin {
            Label(L("시스템 폴더 항목 — 정리할 때 관리자 암호를 묻습니다"), systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }
        Button {
            model.system.reveal(path: c.path)
        } label: {
            Label(L("Finder에서 보기"), systemImage: "folder")
        }
        .help("⌘R")
    }

    private func categoryInfo(_ section: InspectorSection) -> some View {
        let leaves = section.allItems.flatMap(SelectionTree.leaves(of:))
        let selected = leaves.filter { $0.isSelectable && vm.tree.selected.contains($0.path) }
        return VStack(alignment: .leading, spacing: 10) {
            Text(section.category.title).font(.headline)
            InfoRow(title: L("항목"), value: L("%lld개 중 %lld개 선택", leaves.count, selected.count))
            InfoRow(title: L("크기"), value: Fmt.bytes(leaves.reduce(0) { $0 + ($1.size ?? 0) }))
            let kept = KeptSummary(leaves.filter { l in !selected.contains { $0.path == l.path } })
            if kept.total > 0 { InfoRow(title: L("남겨두는 항목"), value: kept.breakdown) }
        }
    }

    private func sizeLine(_ c: Candidate) -> String {
        var s = Fmt.size(c.size)
        if let n = c.fileCount { s += " · " + L("파일 %lld개", n) }
        return s
    }

    private func shareReason(_ c: Candidate) -> String? {
        if case .shared(_, let reason) = c.share, !reason.text.isEmpty { return reason.localized }
        return nil
    }

    private func orderedSources(_ c: Candidate) -> [String] {
        var seen = Set<String>()
        return c.evidence.map(\.source.title).filter { seen.insert($0).inserted }
    }
}

/// 공유·사용자 데이터 경고. 체크하면 즉시 강조 (추가 대화상자 없음, ui-ux.md 결정 3)
private struct RiskBox: View {
    var tone: Tone
    var emphasised: Bool
    var systemImage: String
    var title: String
    var lines: [String]
    var selectedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: emphasised ? "exclamationmark.triangle.fill" : systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tone.foreground)
            ForEach(lines, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if emphasised, let selectedNote {
                Text(selectedNote).font(.callout.weight(.semibold)).foregroundStyle(tone.foreground)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background.opacity(emphasised ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(emphasised ? tone.foreground : tone.border, lineWidth: emphasised ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
    }
}
