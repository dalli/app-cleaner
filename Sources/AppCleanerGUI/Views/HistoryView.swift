import CleanerCore
import SwiftUI

/// S6 삭제 기록
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var vm = model.history
        VStack(spacing: 0) {
            if !vm.expiredSessionIDs.isEmpty {
                ExpiredBanner(count: vm.expiredSessionIDs.count, retention: model.settings.holdingRetentionDays) {
                    vm.confirmPurge = true
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider()
            }
            if let r = vm.lastRestore {
                RestoreResultBanner(result: r) { vm.dismissRestoreResult() }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 0) {
                SessionList(vm: vm)
                    .frame(width: 330)
                Divider()
                if let session = vm.selectedSession {
                    SessionDetail(vm: vm, session: session)
                } else {
                    Text(vm.isLoading ? L("기록을 불러오는 중…") : L("아직 정리한 기록이 없습니다"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(L("삭제 기록"))
        .navigationSubtitle(usageText)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.system.reveal(path: vm.holdingFolderPath)
                } label: {
                    Label(L("보류 폴더를 Finder에서 보기"), systemImage: "folder")
                }
                .help(L("보류 폴더를 Finder에서 보기"))
            }
        }
        // 화면을 열 때마다 이동 위치를 확인해 상태를 갱신 (휴지통 비움 감지)
        .task { await vm.load(retentionDays: model.settings.holdingRetentionDays) }
        .sheet(item: $vm.restoreRequest) { req in
            RestoreSheet(vm: vm, request: req)
        }
        .confirmationDialog(L("보류 폴더 항목을 영구 삭제할까요?"), isPresented: $vm.confirmPurge) {
            Button(L("영구 삭제")) {
                Task { _ = await vm.purgeExpired(retentionDays: model.settings.holdingRetentionDays) }
            }
            Button(L("취소"), role: .cancel) {}
        } message: {
            Text(L("보관 기간이 지난 작업 %lld개의 보류 항목을 영구 삭제합니다. 영구 삭제한 항목은 되돌릴 수 없습니다.", vm.expiredSessionIDs.count))
        }
    }

    private var usageText: String {
        guard let u = model.history.usage else { return "" }
        if let oldest = u.oldestItemDate {
            return L("보류 폴더 %@ · 가장 오래된 항목 %lld일 경과", Fmt.bytes(u.totalSize), Fmt.daysSince(oldest))
        }
        return L("보류 폴더 %@", Fmt.bytes(u.totalSize))
    }
}

private struct ExpiredBanner: View {
    var count: Int
    var retention: Int
    var purge: () -> Void

    var body: some View {
        Banner(tone: .caution, systemImage: "clock.badge.exclamationmark",
               text: L("보관 기간(%lld일)이 지난 보류 항목이 작업 %lld개에 있습니다.", retention, count),
               detail: L("자동으로 지우지 않습니다. 필요 없으면 영구 삭제하세요.")) {
            Button(L("영구 삭제…"), action: purge)
        }
    }
}

private struct RestoreResultBanner: View {
    var result: RestoreResult
    var close: () -> Void

    var body: some View {
        Banner(tone: result.failures.isEmpty && result.missing.isEmpty ? .positive : .caution,
               systemImage: "arrow.uturn.backward.circle",
               text: L("%lld개 항목을 원래 위치로 되돌렸습니다.", result.restored.count),
               detail: detail) {
            Button(L("닫기"), action: close)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if !result.skipped.isEmpty { parts.append(L("건너뜀 %lld", result.skipped.count)) }
        if !result.missing.isEmpty { parts.append(L("복원 불가 %lld", result.missing.count)) }
        if !result.failures.isEmpty { parts.append(L("실패 %lld", result.failures.count)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 작업 목록

private struct SessionList: View {
    @Bindable var vm: HistoryViewModel

    var body: some View {
        List(selection: $vm.selectedSessionID) {
            ForEach(vm.sessions) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(HistoryViewModel.sessionTitle(s)).fontWeight(.semibold).lineLimit(1)
                        Spacer()
                        StatusBadge(status: s.status)
                    }
                    Text(HistoryViewModel.sessionSubtitle(s))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 4)
                .tag(s.id)
                .accessibilityElement(children: .combine)
            }
        }
        .listStyle(.inset)
        .overlay {
            if vm.isLoading && vm.sessions.isEmpty { ProgressView() }
        }
    }
}

// MARK: - 상세

private struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: HistoryViewModel
    var session: JournalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            steps
            itemTable
            HStack(spacing: 10) {
                Button(L("선택한 항목만 되돌리기 (%lld)", vm.checkedItems.count)) { vm.requestRestoreChecked() }
                    .disabled(vm.checkedItems.isEmpty || vm.isRestoring)
                Spacer()
                Button {
                    Task {
                        if let data = await vm.exportJSON() {
                            model.system.save(data, suggestedName: "AppCleaner-\(session.targetName)-\(session.id.uuidString.prefix(8)).json")
                        }
                    }
                } label: {
                    Label(L("기록 내보내기 (JSON)"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .padding(20)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session.kind == .appRemoval ? L("%@ 제거", session.targetName) : L("%@ 정리", session.targetName))
                        .font(.title2.weight(.bold))
                    StatusBadge(status: session.status)
                }
                Text(meta).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button {
                vm.requestRestoreAll()
            } label: {
                if vm.isRestoring { ProgressView().controlSize(.small) } else { Text(L("모두 되돌리기")) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(vm.restorableItems(of: session).isEmpty || vm.isRestoring)
            .help("⌘Z")
        }
    }

    private var meta: String {
        var parts = [Fmt.dateTime(session.startedAt)]
        if let end = session.finishedAt { parts.append(L("%@ 소요", Fmt.duration(end.timeIntervalSince(session.startedAt)))) }
        parts.append(L("규칙 데이터 %@", session.ruleDataVersion))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var steps: some View {
        if !session.steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("수행한 단계")).font(.headline)
                ForEach(session.steps, id: \.self) { raw in
                    Label(stepLine(raw), systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }
        }
    }

    private func stepLine(_ raw: String) -> String {
        switch CleanupStep(rawValue: raw) {
        case .stopServices?:
            return L("백그라운드 서비스 %lld개 중지 — 되돌릴 때 다시 등록할 수 있음", session.stoppedServices.count)
        case .flushPreferences?:
            return L("환경설정 캐시 %lld개 삭제 — 사본 보관됨", max(session.preferencesBackups.count, 1))
        case .moveItems?:
            return L("%lld개 항목 이동", session.items.count)
        default:
            return HistoryViewModel.stepText(raw)
        }
    }

    private var itemTable: some View {
        Table(session.items) {
            TableColumn("") { (item: JournalItem) in
                if vm.isRestorable(item, in: session) {
                    Toggle("", isOn: Binding(get: { vm.checkedItems.contains(item.originalPath) },
                                             set: { _ in vm.toggleChecked(item) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .accessibilityLabel(Fmt.path(item.originalPath))
                } else {
                    Image(systemName: item.restoredAt != nil ? "arrow.uturn.backward" : "xmark")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel(vm.currentLocation(item, in: session))
                }
            }
            .width(28)
            TableColumn(L("원래 위치")) { (item: JournalItem) in
                Text(Fmt.path(item.originalPath))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.originalPath)
            }
            TableColumn(L("현재 위치")) { (item: JournalItem) in
                Text(vm.currentLocation(item, in: session))
                    .foregroundStyle(vm.isRestorable(item, in: session) ? .primary : .secondary)
                    .help(item.movedTo)
            }
            .width(min: 120, ideal: 170)
            TableColumn(L("크기")) { (item: JournalItem) in
                Text(Fmt.size(item.size)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .frame(minHeight: 160)
    }
}

// MARK: - 되돌리기 시트

private struct RestoreSheet: View {
    @Bindable var vm: HistoryViewModel
    var request: HistoryViewModel.RestoreRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("%@ 되돌리기", request.session.targetName)).font(.title2.weight(.bold))
            Text(L("%lld개 항목을 원래 위치로 옮깁니다.", request.items.count)).foregroundStyle(.secondary)

            if !request.conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("원래 위치에 같은 이름이 이미 있는 항목 %lld개", request.conflicts.count), systemImage: "exclamationmark.triangle")
                        .font(.headline)
                        .foregroundStyle(Tone.caution.foreground)
                    ForEach(request.items.filter { request.conflicts.contains($0.originalPath) }) { item in
                        HStack {
                            Text(Fmt.path(item.originalPath))
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Picker("", selection: policyBinding(item)) {
                                Text(L("덮어쓰기 안 함 (이름 바꿔 복원)")).tag(RestoreOptions.ConflictPolicy.renameRestored)
                                Text(L("건너뛰기")).tag(RestoreOptions.ConflictPolicy.skip)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel(L("%@ 충돌 처리", Fmt.lastComponent(item.originalPath)))
                        }
                    }
                }
                .padding(12)
                .background(Tone.caution.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if request.hasStoppedServices {
                Toggle(isOn: reregisterBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("중지했던 백그라운드 서비스 다시 등록"))
                        Text(request.session.stoppedServices.map(\.label).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                Button(L("취소")) { vm.restoreRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L("되돌리기")) { Task { await vm.performRestore() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func policyBinding(_ item: JournalItem) -> Binding<RestoreOptions.ConflictPolicy> {
        Binding(get: { vm.restoreRequest?.policies[item.originalPath] ?? .renameRestored },
                set: { vm.restoreRequest?.policies[item.originalPath] = $0 })
    }

    private var reregisterBinding: Binding<Bool> {
        Binding(get: { vm.restoreRequest?.reregisterServices ?? true },
                set: { vm.restoreRequest?.reregisterServices = $0 })
    }
}
