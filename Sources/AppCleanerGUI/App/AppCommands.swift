import SwiftUI

/// 메뉴 막대와 단축키 (ui-ux.md 4.1)
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L("설정…")) { model.select(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {}

        // ⌘Z는 텍스트 편집 취소 대신 "직전 정리 되돌리기"로 쓴다 (완료 화면·삭제 기록에서만 활성)
        CommandGroup(replacing: .undoRedo) {
            Button(L("직전 정리 되돌리기")) { model.undoLastCleanup() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
        }

        CommandGroup(after: .textEditing) {
            Button(L("검색")) { model.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(before: .sidebar) {
            Button(L("앱 제거")) { model.select(.apps) }
                .keyboardShortcut("1", modifiers: .command)
            Button(L("고아 잔여물")) { model.select(.orphans) }
                .keyboardShortcut("2", modifiers: .command)
            Button(L("삭제 기록")) { model.select(.history) }
                .keyboardShortcut("3", modifiers: .command)
            Button(HomebrewViewModel.title) { model.select(.homebrew) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
        }

        CommandMenu(L("정리")) {
            Button(L("고아 잔여물 스캔")) { model.startOrphanScan() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.orphans.isScanning)
            Button(L("설치 파일 정리…")) { model.checkInstallerLeftovers(manual: true) }
                .disabled(model.installerCleanup != nil || model.cleanupFlow != nil)
            Divider()
            Button(L("정리 미리보기…")) { model.openPreview() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canOpenPreview)
            Button(L("Finder에서 보기")) { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.revealPath == nil)
            Divider()
            Button(L("직전 정리 되돌리기")) { model.undoLastCleanup() }
                .disabled(!model.canUndo)
        }
    }
}
