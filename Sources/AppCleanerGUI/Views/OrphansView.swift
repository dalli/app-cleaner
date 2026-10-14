import CleanerCore
import SwiftUI

/// S5 고아 잔여물
struct OrphansView: View {
    @Environment(AppModel.self) private var model

    private var vm: OrphanViewModel { model.orphans }

    var body: some View {
        VStack(spacing: 0) {
            if vm.phase == .idle && !vm.hasScanned {
                PreScanView { model.startOrphanScan() }
            } else {
                results
            }
        }
        .navigationTitle(L("고아 잔여물"))
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !vm.isScanning && (vm.hasScanned || vm.phase != .idle) {
                    Button { model.startOrphanScan() } label: {
                        Label(L("다시 스캔"), systemImage: "arrow.clockwise")
                    }
                    .help("⌘⇧O")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let undo = vm.keepUndo {
                KeepToast(undo: undo, onUndo: { vm.undoKeep() }, onClose: { vm.dismissToast() })
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: vm.keepUndo)
    }

    private var subtitle: String {
        if let r = vm.report, vm.phase == .finished {
            return L("마지막 스캔 %@ (%@, 설치 앱 %lld개 확인)", Fmt.relative(r.scannedAt), Fmt.duration(r.duration), r.inventoryAppCount)
        }
        return L("이미 삭제된 앱이 남긴 파일")
    }

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.isScanning { ScanPhaseBar(phase: vm.phase) { vm.cancelScan() } }
            banners
            if vm.phase != .idle || vm.hasScanned { filterBar }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)

        if vm.groups.isEmpty && !vm.isScanning {
            EmptyResults(hidden: vm.hiddenByKeepList, failed: failureMessage)
        } else if vm.visibleGroups.isEmpty && !vm.isScanning {
            Text(L("이 신뢰도에 해당하는 그룹이 없습니다"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            OrphanList(vm: model.orphans)
        }
        bottomBar
    }

    private var failureMessage: String? {
        if case .failed(let m) = vm.phase { return m }
        return nil
    }

    @ViewBuilder
    private var banners: some View {
        if vm.spotlightIncomplete {
            Banner(tone: .caution, systemImage: "exclamationmark.triangle",
                   text: L("Spotlight 색인이 불완전해 일부 설치 앱을 확인하지 못했습니다."),
                   detail: spotlightDetail)
        }
        if model.lacksFullDiskAccess || (vm.report?.warnings.contains(.noFullDiskAccess) ?? false) {
            Banner(tone: .caution, systemImage: "lock.shield",
                   text: L("일부 항목을 찾지 못했을 수 있음"),
                   detail: L("전체 디스크 접근 권한이 없어 보호된 폴더는 확인하지 못했습니다.")) {
                Button(L("시스템 설정 열기")) { model.system.openFullDiskAccessSettings() }
            }
        }
        if vm.phase == .cancelled {
            Banner(tone: .accent, systemImage: "info.circle",
                   text: L("스캔을 취소했습니다. 취소 전까지 찾은 결과만 보여 줍니다."))
        }
    }

    private var spotlightDetail: String {
        let missing = vm.report?.spotlight.missingApps ?? []
        let base = L("이름이나 번들 ID로만 찾은 항목은 “낮음”으로 낮췄습니다. 정리 전에 해당 앱이 정말 없는지 확인하세요.")
        guard !missing.isEmpty else { return base }
        return L("확인하지 못한 앱: %@", missing.map { Fmt.path($0) }.joined(separator: ", ")) + "\n" + base
    }

    private var filterBar: some View {
        @Bindable var vm = model.orphans
        return HStack(spacing: 8) {
            FilterChip(title: L("전체"), count: vm.count(for: nil), isOn: vm.confidenceFilter == nil) { vm.confidenceFilter = nil }
            ForEach([Confidence.high, .medium, .low], id: \.self) { c in
                FilterChip(title: c.title, count: vm.count(for: c), isOn: vm.confidenceFilter == c) { vm.confidenceFilter = c }
            }
            Spacer()
            Picker(L("정렬"), selection: $vm.sort) {
                ForEach(OrphanSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Button(L("높음만 선택")) { vm.selectHighOnly() }
                .disabled(vm.groups.isEmpty)
                .help(L("신뢰도가 높고 사용자 데이터·공유가 아닌 항목만 선택합니다"))
        }
    }

    private var bottomBar: some View {
        BottomBar {
            Group {
                Text(Fmt.bytes(vm.selectedSize)).fontWeight(.semibold).foregroundStyle(.primary)
                    + Text(" " + L("선택 · 그룹 %lld개, 항목 %lld개", vm.selectedGroupCount, vm.selectedItemCount))
                    + Text(vm.hiddenByKeepList > 0 ? " · " + L("유지 목록 %lld개 숨김", vm.hiddenByKeepList) : "")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Button(L("정리 미리보기")) { model.openPreview() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canPreview)
                .help(L("아직 아무것도 옮기지 않습니다. 옮길 항목을 한 번 더 보여 줍니다. (⌘⌫)"))
        }
    }
}

// MARK: - 스캔 전

private struct PreScanView: View {
    var start: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(Tone.accent.foreground)
                .accessibilityHidden(true)
            Text(L("이미 삭제된 앱이 남긴 파일을 찾습니다")).font(.title2.weight(.bold))
            Text(L("설치된 앱 목록과 비교해 주인이 없는 설정·캐시·백그라운드 서비스를 앱별로 묶어 보여 줍니다. 결과는 신뢰도와 함께 표시되며, 기본으로는 확실한 항목만 선택합니다."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button(L("스캔 시작"), action: start)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Label(L("아무것도 지우지 않습니다"), systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 설치 앱 확인 → 후보 수집 → 판정
private struct ScanPhaseBar: View {
    var phase: OrphanViewModel.Phase
    var cancel: () -> Void

    private let phases: [OrphanScanPhase] = [.buildingInventory, .collectingCandidates, .judging]

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            ForEach(Array(phases.enumerated()), id: \.element) { i, p in
                if i > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                Text(title(p))
                    .fontWeight(p == current ? .semibold : .regular)
                    .foregroundStyle(state(p) == .pending ? .secondary : .primary)
                    .overlay(alignment: .leading) {
                        if state(p) == .done {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                                .foregroundStyle(Tone.positive.foreground).offset(x: -14)
                        }
                    }
                    .padding(.leading, state(p) == .done ? 14 : 0)
            }
            Spacer()
            Text(L("결과는 찾는 대로 추가됩니다")).font(.caption).foregroundStyle(.secondary)
            Button(L("취소"), action: cancel)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("스캔 중: %@", current.map(title) ?? ""))
    }

    private enum StepState { case done, current, pending }

    private var current: OrphanScanPhase? {
        if case .scanning(let p) = phase { return p }
        return nil
    }

    private func state(_ p: OrphanScanPhase) -> StepState {
        guard let current, let ci = phases.firstIndex(of: current), let pi = phases.firstIndex(of: p) else { return .pending }
        return pi < ci ? .done : (pi == ci ? .current : .pending)
    }

    private func title(_ p: OrphanScanPhase) -> String {
        switch p {
        case .buildingInventory: return L("설치 앱 확인")
        case .collectingCandidates: return L("후보 수집")
        case .judging: return L("판정")
        case .finished: return L("완료")
        }
    }
}

private struct EmptyResults: View {
    var hidden: Int
    var failed: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: failed == nil ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(failed == nil ? Tone.positive.foreground : Tone.caution.foreground)
                .accessibilityHidden(true)
            Text(failed == nil ? L("정리할 잔여물이 없습니다") : L("스캔하지 못했습니다")).font(.title3.weight(.semibold))
            if let failed { Text(failed).foregroundStyle(.secondary) }
            if hidden > 0 {
                Text(L("유지 목록에 숨긴 항목 %lld개는 표시하지 않았습니다. 설정 › 유지 목록에서 해제할 수 있습니다.", hidden))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 목록

private struct OrphanList: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: OrphanViewModel

    var body: some View {
        List(selection: $vm.focusedID) {
            ForEach(vm.rows) { row in
                switch row {
                case .group(let g):
                    OutlineRow(depth: 0, expandable: true, expanded: vm.expanded.contains(g.id),
                               toggleExpanded: { vm.setExpanded(groupID: g.id, !vm.expanded.contains(g.id)) }) {
                        OrphanGroupRow(vm: vm, group: g)
                    }
                    .tag(row.id)
                case .item(let c):
                    OutlineRow(depth: 1, expandable: false, expanded: false, toggleExpanded: {}) {
                        OrphanItemRow(vm: vm, item: c)
                    }
                    .tag(row.id)
                case .more(let gid, let count):
                    OutlineRow(depth: 1, expandable: false, expanded: false, toggleExpanded: {}) {
                        Button(L("항목 %lld개 더 보기", count)) { vm.showAllItems.insert(gid) }
                            .buttonStyle(.link)
                            .padding(.vertical, 4)
                    }
                    .selectionDisabled()
                }
            }
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
            if let id = ids.first {
                if id.hasPrefix("group:"), let g = vm.groups.first(where: { "group:" + $0.id == id }) {
                    Button(L("유지 (목록에서 숨기기)")) { vm.keep(g) }
                } else if !id.hasPrefix("more:") {
                    Button(L("Finder에서 보기")) { model.system.reveal(path: id) }
                    Button(L("경로 복사")) { model.system.copyToPasteboard(id) }
                }
            }
        }
    }
}

private struct OrphanGroupRow: View {
    @Bindable var vm: OrphanViewModel
    var group: OrphanGroup

    var body: some View {
        let state = vm.state(of: group)
        HStack(spacing: 12) {
            TriStateCheckbox(state: state, label: group.displayName) { vm.toggle(group) }
                .fixedSize()
            MissingAppIcon(name: group.displayName)
            VStack(alignment: .leading, spacing: 2) {
                (Text(group.displayName).fontWeight(.semibold) + Text(suffix).foregroundStyle(.secondary))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(group.notes.isEmpty ? Color.secondary : noteColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if group.share.isShared {
                Badge(group.share.usageText ?? L("공유"), tone: .shared, systemImage: "person.2.fill")
            }
            ConfidenceBadge(confidence: group.confidence)
            Text(Fmt.bytes(group.totalSize))
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Button(L("유지")) { vm.keep(group) }
                .controlSize(.small)
                .help(L("이 그룹을 유지 목록에 넣고 다음 스캔부터 숨깁니다"))
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibility(state))
    }

    private var suffix: String {
        if group.nameIsGuess { return " " + L("(추정)") }
        if group.bundleID != nil { return " " + L("(삭제됨)") }
        return ""
    }

    private var subtitle: String {
        var parts: [String] = []
        if let note = group.notes.first { parts.append(note.localized) }
        parts.append(L("%lld개", group.items.count))
        if let m = group.lastModified { parts.append(L("마지막 수정 %@", Fmt.date(m))) }
        if group.notes.isEmpty, let bid = group.bundleID { parts.append(bid) }
        return parts.joined(separator: " · ")
    }

    private var noteColor: Color { group.share.isShared ? Tone.shared.foreground : Tone.caution.foreground }

    private func accessibility(_ state: CheckState) -> String {
        var parts = [group.displayName + suffix, L("%lld개 항목", group.items.count), Fmt.spokenSize(group.totalSize), group.confidence.fullTitle]
        if let s = group.share.spokenText { parts.append(s) }
        parts.append(state.spokenValue)
        return parts.joined(separator: ", ")
    }
}

private struct OrphanItemRow: View {
    @Bindable var vm: OrphanViewModel
    var item: Candidate

    var body: some View {
        let state = vm.state(of: item)
        HStack(alignment: .center, spacing: 12) {
            if item.isSelectable {
                TriStateCheckbox(state: state, label: Fmt.path(item.path)) { vm.toggle(item) }
                    .fixedSize()
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.path(item.path))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let why = item.evidence.first?.detail.localized {
                    Text(L("근거: %@", why)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            CandidateBadges(candidate: item)
            Text(Fmt.size(item.size))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .frame(minHeight: Metrics.minRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.candidate(item, name: Fmt.path(item.path), state: state)
                            + (item.evidence.first.map { ", " + L("근거: %@", $0.detail.localized) } ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: L("선택 전환")) { vm.toggle(item) }
    }
}

/// "유지" 직후 하단 토스트
private struct KeepToast: View {
    var undo: OrphanViewModel.KeepUndo
    var onUndo: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("%@ 유지 목록에 넣었습니다.", Josa.eulReul(undo.group.displayName))).fontWeight(.medium)
                Text(L("설정 › 유지 목록에서 해제할 수 있습니다.")).font(.caption).foregroundStyle(.secondary)
            }
            Button(L("되돌리기"), action: onUndo).buttonStyle(.borderedProminent).controlSize(.small)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("닫기"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
