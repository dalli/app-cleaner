import CleanerCore
import SwiftUI

/// S4 정리 완료
struct CompletionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var completion: CompletionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary
                if !completion.result.failures.isEmpty { failures }
                actions
                advisories
                if completion.origin == .appRemoval { orphanLink }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("정리 완료"))
        .onExitCommand { model.finishCompletion() }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: completion.result.cancelled ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(completion.result.cancelled ? Tone.neutral.foreground : Tone.positive.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(completion.title).font(.title.weight(.bold))
                Text(completion.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                undoStatus
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var undoStatus: some View {
        switch completion.undoState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("되돌리는 중…")) }
        case let .done(restored, skipped, missing, failed):
            Label(L("%lld개 항목을 원래 위치로 되돌렸습니다.", restored), systemImage: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Tone.accent.foreground)
            if skipped + missing + failed > 0 {
                Text(L("건너뜀 %lld · 복원 불가 %lld · 실패 %lld", skipped, missing, failed))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var failures: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("%lld개 항목을 옮기지 못했습니다", completion.result.failures.count), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Tone.caution.foreground)
            Text(L("나머지 항목은 정리했습니다. 실패한 항목은 그대로 남아 있습니다."))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(completion.result.failures, id: \.path) { f in
                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.path(f.path)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(f.reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tone.caution.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.caution.border))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.undoCompletion()
            } label: {
                Label(L("되돌리기"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!completion.canUndo)
            .help("⌘Z")
            Button(L("휴지통 열기")) { model.system.openTrash() }
            Spacer()
            Button(L("완료")) { model.finishCompletion() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 직접 확인할 것

    @ViewBuilder
    private var advisories: some View {
        let items = completion.advisories
        let kept = completion.keptSummary
        if !items.isEmpty || kept.total > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("직접 확인할 것")).font(.headline)
                ForEach(items, id: \.stableID) { advisory in
                    advisoryCard(advisory)
                }
                if kept.total > 0 {
                    AdvisoryCard(systemImage: "tray.full", title: L("남겨둔 항목 %lld개", kept.total), detail: kept.breakdown) {
                        Button(completion.showKeptItems ? L("접기") : L("항목 보기")) { completion.showKeptItems.toggle() }
                    }
                    if completion.showKeptItems {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(completion.plan.keptItems) { item in
                                HStack {
                                    Text(Fmt.path(item.path)).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.size(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func advisoryCard(_ advisory: Advisory) -> some View {
        let name = completion.plan.targetName
        switch advisory {
        case .loginItems:
            AdvisoryCard(systemImage: "person.crop.circle.badge.checkmark", title: L("로그인 항목"),
                         detail: L("%@ 항목이 남아 있으면 시스템 설정에서 끄세요.", name)) {
                Button(L("시스템 설정 열기")) { model.system.openLoginItemsSettings() }
            }
        case .keychain(let term):
            AdvisoryCard(systemImage: "key", title: L("키체인 항목"),
                         detail: L("키체인 접근 앱에서 %@ 검색해 필요 없는 암호를 지우세요.", Josa.euRo("“\(term)”"))) {
                Button(L("검색어 복사")) { model.system.copyToPasteboard(term) }
                Button(L("키체인 접근 열기")) { model.system.openKeychainAccess() }
            }
        case .systemExtension(let id):
            AdvisoryCard(systemImage: "puzzlepiece.extension", title: L("시스템 확장"),
                         detail: L("%@ 확장은 macOS가 관리합니다. 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램에서 끄세요.", id)) {
                Button(L("시스템 설정 열기")) { model.system.openExtensionsSettings() }
            }
        case .kernelExtension(let path):
            AdvisoryCard(systemImage: "cpu", title: L("커널 확장"),
                         detail: L("%@ — 커널 확장은 macOS 보안 정책 때문에 자동으로 지우지 않습니다. 개발사의 제거 안내를 따르세요.", Fmt.path(path))) {
                Button(L("Finder에서 보기")) { model.system.reveal(path: path) }
            }
        case .homebrewZap(let token):
            let command = "brew uninstall --zap \(token)"
            AdvisoryCard(systemImage: "terminal", title: L("Homebrew 기록"),
                         detail: L("Homebrew로 설치한 앱입니다. 터미널에서 %@ 명령으로 Homebrew 기록도 정리할 수 있습니다.", command)) {
                Button(L("명령 복사")) { model.system.copyToPasteboard(command) }
            }
        }
    }

    // MARK: 고아 연결

    private var orphanLink: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(Tone.accent.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("이미 지운 앱의 잔여물도 확인해 보세요")).fontWeight(.semibold)
                if let s = model.orphanSummary {
                    Text(L("지난 스캔에서 앱 %lld개의 잔여물 %@를 찾았습니다.", s.groups, Fmt.bytes(s.size)))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(L("고아 잔여물 스캔은 아무것도 지우지 않고 목록만 보여 줍니다."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(L("고아 잔여물 확인")) {
                if model.orphanSummary == nil { model.startOrphanScan() } else { model.select(.orphans) }
            }
        }
        .padding(16)
        .background(Tone.accent.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Tone.accent.border))
    }
}

private struct AdvisoryCard<Actions: View>: View {
    var systemImage: String
    var title: String
    var detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
