import CleanerCore
import SwiftUI

/// S8 첫 실행 — 권한 온보딩
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityHidden(true)
                    Text(L("App Cleaner 시작하기")).font(.title.weight(.bold)).padding(.top, 8)
                    Text(L("앱을 지울 때 남는 설정·캐시·백그라운드 서비스까지 찾아 안전하게 정리합니다."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 32)

                VStack(alignment: .leading, spacing: 8) {
                    promise(L("영구 삭제하지 않고 휴지통으로 옮기며, 삭제 기록에서 되돌릴 수 있습니다."))
                    promise(L("옮기기 전에 항상 무엇이 옮겨지는지 보여줍니다."))
                    promise(L("다른 앱이 함께 쓰는 파일과 사용자 문서는 기본으로 남겨 둡니다."))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tone.accent.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 32)
                .padding(.top, 18)

                Text(L("필요한 권한")).font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 10)

                VStack(spacing: 0) {
                    fullDiskAccess
                    Divider()
                    onDemand(L("앱 관리"), L("다른 개발자의 앱을 지울 때 필요합니다. 처음 지울 때 macOS가 요청합니다."))
                    Divider()
                    onDemand(L("관리자 암호"), L("시스템 폴더(/Library)의 서비스나 헬퍼를 정리할 때만 묻습니다."))
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 32)

                HStack(spacing: 10) {
                    if model.lacksFullDiskAccess {
                        Text(L("권한 없이도 쓸 수 있지만 일부 항목을 찾지 못할 수 있습니다."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("나중에 하기")) { model.finishOnboarding() }
                        .keyboardShortcut(.cancelAction)
                    Button(L("계속")) { model.finishOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 18)
                .background(.bar)
                .padding(.top, 28)
            }
            .frame(maxWidth: 640)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 20, y: 8)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { model.refreshPermissions() }
    }

    private func promise(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "checkmark").fontWeight(.bold).foregroundStyle(Tone.accent.foreground)
        }
        .font(.callout)
    }

    private var fullDiskAccess: some View {
        let granted = model.permissions.fullDiskAccess == .granted
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(L("전체 디스크 접근")).fontWeight(.semibold)
                        Badge(L("권장"), tone: .accent)
                    }
                    Text(L("없으면 일부 앱 데이터를 찾지 못하고, 폴더를 열 때마다 macOS 확인창이 뜹니다."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if granted {
                    Badge(L("허용됨"), tone: .positive, systemImage: "checkmark")
                } else {
                    Badge(L("아직 허용 안 됨"), tone: .userData, systemImage: "exclamationmark")
                }
            }
            if !granted {
                HStack(spacing: 10) {
                    Text(L("시스템 설정 › 개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 App Cleaner를 켜세요. 돌아오면 자동으로 확인합니다."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("시스템 설정 열기")) { model.system.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
    }

    private func onDemand(_ title: String, _ detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L("필요할 때 요청")).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
