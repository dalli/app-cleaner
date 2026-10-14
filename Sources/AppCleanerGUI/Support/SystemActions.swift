import AppKit
import Foundation
import UniformTypeIdentifiers

/// Finder·시스템 설정 열기 등 macOS 동작 (읽기·열기만 하고 파일을 바꾸지 않는다)
@MainActor
struct SystemActions {
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let extensionsURL = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!

    init() {}

    func reveal(path: String) {
        let url = URL(filePath: path, directoryHint: .inferFromPath)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // 이동했거나 없는 항목은 상위 폴더를 연다
            let parent = url.deletingLastPathComponent()
            NSWorkspace.shared.open(parent)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openFullDiskAccessSettings() { open(Self.fullDiskAccessURL) }
    func openLoginItemsSettings() { open(Self.loginItemsURL) }
    func openExtensionsSettings() { open(Self.extensionsURL) }

    func openTrash() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash", directoryHint: .isDirectory)
        NSWorkspace.shared.open(trash)
    }

    func openKeychainAccess() {
        let candidates = [
            "/System/Applications/Utilities/Keychain Access.app",
            "/Applications/Utilities/Keychain Access.app",
            "/System/Library/CoreServices/Applications/Keychain Access.app",
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 기록 내보내기 (사용자가 고른 위치에만 쓴다)
    func save(_ data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }

    func icon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}
