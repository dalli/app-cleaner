import CleanerCore
import SwiftUI

/// S7 설정
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ScrollViewReader { proxy in
            Form {
                Section {
                    PermissionRow(title: L("전체 디스크 접근"),
                                  detail: L("다른 앱의 컨테이너와 보호된 폴더를 읽는 데 필요합니다."),
                                  state: model.permissions.fullDiskAccess) {
                        Button(L("시스템 설정 열기")) { model.system.openFullDiskAccessSettings() }
                    }
                    PermissionRow(title: L("앱 관리"),
                                  detail: L("다른 개발자의 앱을 지울 때 필요합니다. 처음 지울 때 macOS가 요청합니다."),
                                  state: model.permissions.appManagement) { EmptyView() }
                    LabeledContent {
                        Button(L("헬퍼 설치…")) {}
                            .disabled(true)
                            .help(L("다음 버전에서 제공합니다"))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(L("관리자 헬퍼"))
                                Badge(L("다음 버전"), tone: .neutral)
                            }
                            Text(L("설치하지 않으면 시스템 폴더를 정리할 때마다 관리자 암호를 묻습니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(L("권한")).id("permissions")
                }

                Section(L("정리 방식")) {
                    Picker(selection: $settings.holdingRetentionDays) {
                        ForEach(AppSettings.retentionChoices, id: \.self) { Text(L("%lld일", $0)).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("보류 폴더 보관 기간"))
                            Text(L("휴지통으로 보낼 수 없는 시스템 파일을 보관합니다. 기간이 지나면 영구 삭제 전에 물어봅니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: .constant(true)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("정리 전에 항상 미리보기"))
                            Text(L("무엇을 옮기는지 확인하는 단계입니다. 안전을 위해 끌 수 없습니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(true)
                    Toggle(isOn: $settings.resetPrivacyByDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("개인정보 보호 권한 기록도 초기화"))
                            Text(L("앱을 지울 때 카메라·마이크 등 권한 기록을 함께 지우도록 기본 선택합니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L("고아 잔여물 스캔")) {
                    Toggle(isOn: $settings.includeDotfiles) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("고급: 홈 폴더의 숨김 설정 폴더 포함"))
                            Text(L("~/.config 같은 폴더도 “낮음”으로 표시합니다. ~/.ssh, ~/.gnupg는 항상 제외합니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent {
                        Picker("", selection: Binding(get: { settings.periodicScan }, set: { model.setPeriodicScan($0) })) {
                            Text(L("끔")).tag(PeriodicScanInterval.off)
                            Text(L("매주")).tag(PeriodicScanInterval.weekly)
                            Text(L("매달")).tag(PeriodicScanInterval.monthly)
                        }
                        .labelsHidden()
                        .fixedSize()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("정기 스캔 알림"))
                            Text(L("주기적으로 스캔해 “높음” 항목이 있으면 알려줍니다."))
                                .font(.caption).foregroundStyle(.secondary)
                            if settings.periodicScan != .off {
                                Text(model.sentinelStatus.lastScan.map { L("마지막 스캔: %@", Fmt.date($0)) } ?? L("아직 스캔하지 않음"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                SentinelSection()

                Section {
                    if model.keepList.isEmpty {
                        Text(L("유지 목록이 비어 있습니다. 고아 잔여물 화면에서 “유지”를 누르면 여기에 추가됩니다."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.keepList) { entry in
                        LabeledContent {
                            Button(L("해제")) { model.removeKeepEntry(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.kind == .item ? Fmt.path(entry.displayName) : entry.displayName)
                                    .font(entry.kind == .item ? .system(.body, design: .monospaced) : .body)
                                Text(L("%@ · %@에 유지함", entry.kind == .group ? L("그룹") : L("항목"), Fmt.date(entry.addedAt)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(L("유지 목록 — 고아 스캔에서 숨긴 항목"))
                }

                Section(L("규칙 데이터")) {
                    LabeledContent {
                        HStack {
                            switch model.ruleCheck {
                            case .checking: ProgressView().controlSize(.small)
                            case .upToDate: Text(L("최신 버전입니다")).foregroundStyle(.secondary)
                            case .idle: EmptyView()
                            }
                            Button(L("지금 확인")) { model.checkRuleData() }
                                .disabled(model.ruleCheck == .checking)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("버전 %@", model.ruleInfo.version))
                            Text(ruleDetail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle(L("규칙 데이터 자동 갱신"), isOn: $settings.autoUpdateRules)
                }
            }
            .formStyle(.grouped)
            .onAppear { scroll(proxy) }
            .onChange(of: model.settingsAnchor) { _, _ in scroll(proxy) }
        }
        .navigationTitle(L("설정"))
        .onAppear { model.refreshKeepList(); model.refreshPermissions(); model.refreshSentinel() }
    }

    private var ruleDetail: String {
        let info = model.ruleInfo
        var parts = [L("경로 규칙 · Homebrew 정리 규칙 %lld개 · 제외 목록", info.caskCount)]
        if let d = info.updatedAt { parts.append(L("%@ 갱신", Fmt.relative(d))) }
        parts.append(info.signatureVerified ? L("서명 확인됨") : L("서명 확인 실패 — 번들 기본값 사용"))
        return parts.joined(separator: " · ")
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchor = model.settingsAnchor else { return }
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
        model.settingsAnchor = nil
    }
}

/// 휴지통 감시 (Sentinel) — ui-ux.md S10 "S7 설정"
private struct SentinelSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        let status = model.sentinelStatus
        Section {
            Toggle(isOn: Binding(get: { settings.trashWatchEnabled }, set: { model.setTrashWatch($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("휴지통 감시"))
                    Text(L("앱을 휴지통으로 옮기면 남은 잔여물도 정리할지 알려 줍니다. 검사만 하고 아무것도 지우지 않습니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if settings.trashWatchEnabled || settings.periodicScan != .off {
                LabeledContent {
                    HStack(spacing: 10) {
                        registrationBadge
                        if model.sentinelRegistration == .requiresApproval {
                            Button(L("로그인 항목 열기")) { model.system.openLoginItemsSettings() }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "Sentinel")
                        Text(L("메뉴 막대에 상주하며 휴지통 감시와 정기 스캔을 맡습니다. 로그인할 때 함께 실행됩니다."))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = model.sentinelError {
                            Text(L("Sentinel을 등록하지 못했습니다: %@", error))
                                .font(.caption).foregroundStyle(Tone.caution.foreground)
                        }
                    }
                }
                if settings.trashWatchEnabled && status.trashReadable == false {
                    LabeledContent {
                        Button(L("시스템 설정 열기")) { model.system.openFullDiskAccessSettings() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("휴지통을 읽을 수 없음"))
                            Text(L("Sentinel에도 전체 디스크 접근 권한이 필요합니다. 목록에서 “App Cleaner Sentinel”을 켜세요."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if status.notifications == .denied {
                    LabeledContent {
                        Button(L("알림 설정 열기")) { model.system.openNotificationSettings() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("알림이 꺼져 있음"))
                            Text(L("시스템 설정 › 알림에서 “App Cleaner Sentinel”의 알림을 허용하세요."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if status.notifications != .allowed {
                    Text(L("알림 허용은 Sentinel이 처음 실행될 때 macOS가 묻습니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("휴지통 감시 (Sentinel)"))
        }
    }

    @ViewBuilder
    private var registrationBadge: some View {
        switch model.sentinelRegistration {
        case .enabled: Badge(L("켜짐"), tone: .positive, systemImage: "checkmark")
        case .requiresApproval: Badge(L("승인 필요"), tone: .caution, systemImage: "exclamationmark")
        case .disabled: Badge(L("꺼짐"), tone: .neutral)
        case .unavailable:
            Badge(L("사용할 수 없음"), tone: .caution)
                .help(L("App Cleaner.app으로 설치해 실행했을 때만 사용할 수 있습니다."))
        }
    }
}

private struct PermissionRow<Action: View>: View {
    var title: String
    var detail: String
    var state: PermissionStatus.State
    @ViewBuilder var action: () -> Action

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                status
                if state != .granted { action() }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .granted: Badge(L("허용됨"), tone: .positive, systemImage: "checkmark")
        case .denied: Badge(L("허용 안 됨"), tone: .caution, systemImage: "exclamationmark")
        case .unknown: Badge(L("필요할 때 요청"), tone: .neutral)
        }
    }
}
