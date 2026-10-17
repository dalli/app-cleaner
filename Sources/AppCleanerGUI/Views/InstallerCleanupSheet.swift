import CleanerCore
import SwiftUI

struct InstallerCleanupSheet: View {
    @Environment(AppModel.self) private var app
    let model: InstallerCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("설치 파일 정리")).font(.title2.weight(.semibold))
            if model.report.runningOutsideApplications {
                Banner(tone: .caution, systemImage: "exclamationmark.triangle",
                       text: L("App Cleaner가 응용 프로그램 폴더 밖에서 실행 중입니다"),
                       detail: L("디스크 이미지나 다운로드 폴더에서 바로 실행하면 macOS가 임시 위치에서 실행합니다. 응용 프로그램 폴더로 옮긴 뒤 다시 실행하세요."))
            }
            switch model.phase {
            case .review: review
            case .running: ProgressView(L("정리하는 중…")).frame(maxWidth: .infinity, minHeight: 80)
            case .finished: finished
            }
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    @ViewBuilder private var review: some View {
        if model.report.isEmpty {
            Text(L("정리할 설치 파일이 없습니다")).foregroundStyle(.secondary)
        } else {
            Text(L("새 버전을 설치한 뒤 남은 설치 파일과 이전 사본입니다. 휴지통으로 옮기므로 삭제 기록에서 되돌릴 수 있습니다."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.report.mounted.isEmpty {
                        Text(L("디스크 이미지 꺼내기")).font(.headline)
                        ForEach(model.report.mounted) { m in
                            Toggle(isOn: Binding(get: { model.isEjecting(m) }, set: { _ in model.toggleEject(m) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text([m.mountPoint.lastPathComponent, m.appVersion].compactMap { $0 }.joined(separator: " — "))
                                    Text(m.imagePath?.path ?? m.mountPoint.path)
                                        .font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    if !model.report.candidates.isEmpty {
                        Text(L("휴지통으로 옮기기")).font(.headline)
                        ForEach(model.report.candidates) { c in
                            Toggle(isOn: Binding(get: { model.isSelected(c) }, set: { _ in model.toggle(c) })) {
                                candidateRow(c)
                            }
                            .disabled(!c.isSelectable)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
        }
    }

    private func candidateRow(_ c: Candidate) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(c.url.lastPathComponent)
                Spacer()
                Text(Fmt.size(c.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(c.url.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            if let reason = c.protection {
                Text(reason.explanation).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(c.notes, id: \.self) { n in
                    Text(n.localized).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var finished: some View {
        Text(model.summary).fixedSize(horizontal: false, vertical: true)
        if !model.failures.isEmpty {
            Banner(tone: .caution, systemImage: "exclamationmark.triangle", text: L("일부 항목을 처리하지 못했습니다"))
            ForEach(model.failures, id: \.self) { f in
                Text("\(f.path): \(f.reason.localized)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .review:
            if model.report.isEmpty {
                Button(L("닫기")) { app.dismissInstallerCleanup() }.keyboardShortcut(.defaultAction)
            } else {
                Button(L("나중에")) { app.dismissInstallerCleanup() }.keyboardShortcut(.cancelAction)
                Button(L("정리")) { Task { await model.run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canRun)
            }
        case .running:
            EmptyView()
        case .finished:
            Button(L("완료")) { app.dismissInstallerCleanup() }.keyboardShortcut(.defaultAction)
        }
    }
}
