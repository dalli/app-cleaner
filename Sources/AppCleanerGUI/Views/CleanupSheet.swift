import CleanerCore
import SwiftUI

/// S3 정리 미리보기 시트 + 진행 중
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var flow: CleanupFlowModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if flow.phase == .preview {
                        PreviewContent(flow: flow)
                    } else {
                        ProgressContent(flow: flow)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)
            }
            Divider()
            footer
        }
        .frame(width: 620)
        .frame(minHeight: 420, idealHeight: 640, maxHeight: 760)
        .interactiveDismissDisabled(flow.phase != .preview)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(flow.origin == .orphans ? L("고아 잔여물 정리") : L("%@ 정리", flow.plan.targetName))
                .font(.title2.weight(.bold))
            Text(flow.phase == .preview
                 ? L("아직 아무것도 옮기지 않았습니다. 아래 내용을 확인한 뒤 진행하세요.")
                 : L("정리하는 중입니다. 실패한 항목이 있어도 나머지는 계속 진행합니다."))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if flow.phase == .preview {
                Spacer()
                Button(L("돌아가서 수정")) { model.dismissPreview() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    flow.start()
                } label: {
                    Label(L("휴지통으로 이동"), systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canExecute)
            } else {
                ProgressView().controlSize(.small)
                Text(L("창을 닫지 마세요. 끝나면 결과를 보여 드립니다."))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }
}

// MARK: - 미리보기

private struct PreviewContent: View {
    @Bindable var flow: CleanupFlowModel

    var body: some View {
        HStack(spacing: 10) {
            SummaryTile(title: L("옮길 항목"), value: L("%lld개", flow.moveCount))
            SummaryTile(title: L("확보 용량"), value: Fmt.total(flow.reclaimSize, approximate: flow.sizeIsApproximate))
            SummaryTile(title: L("남겨둘 항목"), value: L("%lld개", flow.keptCount))
        }

        VStack(alignment: .leading, spacing: 10) {
            Text(L("진행 순서")).font(.headline)
            ForEach(Array(flow.steps.enumerated()), id: \.element) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Tone.accent.foreground)
                        .frame(width: 24, height: 24)
                        .background(Tone.accent.background, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flow.stepTitle(step)).fontWeight(.semibold)
                        Text(flow.stepDetail(step)).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }

        if flow.requiresAdmin {
            Banner(tone: .caution, systemImage: "lock.shield",
                   text: L("관리자 암호가 한 번 필요합니다."),
                   detail: adminDetail)
        }

        if !flow.riskyItems.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("직접 선택한 공유·사용자 데이터 항목 %lld개", flow.riskyItems.count), systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(Tone.userData.foreground)
                Text(L("기본으로는 남겨 두는 항목입니다. 옮기면 아래 내용이 사라질 수 있습니다."))
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(flow.riskyItems) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName).fontWeight(.medium)
                            Text(item.share.usageText ?? item.notes.first ?? Fmt.path(item.path))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CandidateBadges(candidate: item)
                        Text(Fmt.size(item.size)).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AccessibilityText.candidate(item, state: .on))
                }
            }
            .padding(12)
            .background(Tone.userData.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.userData.border))
        }

        if flow.keptCount > 0 {
            DisclosureGroup(isExpanded: $flow.showKeptItems) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(flow.plan.keptItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.displayName).lineLimit(1).truncationMode(.middle)
                            Text(keptReason(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text(Fmt.size(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text(L("남겨두는 항목 %lld개 보기", flow.keptCount)).fontWeight(.semibold)
                    + Text("  " + flow.keptSummary.breakdown).foregroundStyle(.secondary)
            }
        }

        if flow.canResetPrivacy {
            Toggle(isOn: $flow.resetPrivacy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("개인정보 보호 권한 기록(카메라, 마이크 등)도 초기화"))
                    Text(L("기본값은 설정에서 바꿀 수 있습니다.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    private var adminDetail: String {
        let items = flow.adminItems
        if items.isEmpty { return L("시스템 서비스를 멈추고 설치 기록을 정리하는 데 필요합니다.") }
        let names = items.prefix(3).map { Fmt.path($0.path) }.joined(separator: ", ")
        let more = items.count > 3 ? " " + L("외 %lld개", items.count - 3) : ""
        return L("%@ 시스템 소유입니다. 암호는 한 번만 묻습니다.", Josa.eunNeun(names + more))
    }

    private func keptReason(_ item: Candidate) -> String {
        if !item.isSelectable { return L("보호됨") }
        if let u = item.share.usageText { return u }
        if item.nature == .userData { return L("사용자 데이터") }
        if item.confidence == .low { return L("낮은 신뢰도") }
        return L("직접 해제")
    }
}

// MARK: - 진행 중

private struct ProgressContent: View {
    @Bindable var flow: CleanupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(flow.steps, id: \.self) { step in
                stepRow(step)
            }
        }
        .accessibilityElement(children: .contain)

        if case .unresponsive(let app) = flow.phase {
            VStack(alignment: .leading, spacing: 10) {
                Label(L("%@ 종료 요청에 응답하지 않습니다.", Josa.iGa(app.name)), systemImage: "hourglass")
                    .font(.headline)
                    .foregroundStyle(Tone.caution.foreground)
                Text(L("강제 종료하면 저장하지 않은 내용이 사라질 수 있습니다. 건너뛰면 앱 본체를 제외한 나머지 항목만 정리합니다."))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("취소")) { flow.respond(.cancel) }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("건너뛰기")) { flow.respond(.skip) }
                    Button(L("강제 종료")) { flow.respond(.forceQuit) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .background(Tone.caution.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.caution.border))
        }

        if !flow.failures.isEmpty {
            Banner(tone: .caution, systemImage: "exclamationmark.triangle",
                   text: L("%lld개 항목을 옮기지 못했습니다. 나머지는 계속 진행합니다.", flow.failures.count),
                   detail: flow.failures.map { "\(Fmt.lastComponent($0.path)) — \($0.reason)" }.joined(separator: "\n"))
        }
    }

    private func stepRow(_ step: CleanupStep) -> some View {
        let done = flow.completedSteps.contains(step)
        let current = flow.currentStep == step
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tone.positive.foreground)
                } else if current {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.stepTitle(step))
                    .fontWeight(current ? .semibold : .regular)
                    .foregroundStyle(done || current ? .primary : .secondary)
                if step == .moveItems && (current || done) {
                    ProgressView(value: Double(flow.movedCount), total: Double(max(flow.moveCount, 1)))
                    Text(L("%lld / %lld개 항목", flow.movedCount, flow.moveCount))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(current ? Tone.accent.background.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? L("완료") : (current ? L("진행 중") : L("대기 중")))
    }
}
