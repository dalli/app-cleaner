import AppKit
import CleanerCore
import SwiftUI

@main
struct AppCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // macOS 27 SDK의 `@State`는 매크로라 Command Line Tools(SwiftUIMacros 플러그인 없음)에서 쓸 수 없다.
    // App 값은 한 번만 만들어지므로 모델을 그대로 보관한다.
    private let model: AppModel

    init() {
        let args = CommandLine.arguments
        let demo = isDemoMode(arguments: args)
        let engine = makeEngine(arguments: args)
        // 데모 모드는 실제 설정과 섞이지 않게 메모리 설정을 쓴다
        let settings = demo ? AppSettings.inMemory() : AppSettings(defaults: UserDefaults.standard)
        let launch = LaunchOptions(arguments: args)
        if demo {
            settings.onboardingCompleted = !launch.showOnboarding
            if let route = launch.route { settings.lastRoute = route }
        }
        let model = AppModel(engine: engine, settings: settings, isDemo: demo, helper: makeHelperInstaller(arguments: args))
        self.model = model
        AppDelegate.pendingModel = model
        AppDelegate.launchOptions = launch
    }

    var body: some Scene {
        Window("App Cleaner", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1220, height: 800)
        .commands { AppCommands(model: model) }
    }
}

/// 데모 확인용 실행 인자 (`--demo-route orphans`, `--demo-open "Microsoft Word"`, `--demo-onboarding` …)
struct LaunchOptions {
    var route: SidebarRoute?
    var openAppName: String?
    var showOnboarding = false
    var startOrphanScan = false
    var openPreview = false
    var autoExecute = false

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        route = value(after: "--demo-route").flatMap(SidebarRoute.init(rawValue:))
        openAppName = value(after: "--demo-open")
        showOnboarding = arguments.contains("--demo-onboarding")
        startOrphanScan = arguments.contains("--demo-scan")
        openPreview = arguments.contains("--demo-preview")
        autoExecute = arguments.contains("--demo-execute")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pendingModel: AppModel?
    static var launchOptions = LaunchOptions(arguments: [])
    private var pendingURLs: [URL] = []

    private var model: AppModel? { Self.pendingModel }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftPM 실행 파일로 직접 띄워도 Dock·메뉴가 보이게
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let model, !pendingURLs.isEmpty {
            model.handleDrop(pendingURLs)
            pendingURLs = []
        }
        runDemoScript()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘 드롭, Finder "다음으로 열기 › App Cleaner" → S2
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.handleDrop(urls)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 시스템 설정에서 전체 디스크 접근을 켜고 돌아오면 자동으로 다시 확인 (S8)
        model?.refreshPermissions()
    }

    /// 데모 모드 화면 확인용 자동 동작
    private func runDemoScript() {
        guard let model, model.isDemo else { return }
        let opts = Self.launchOptions
        if CommandLine.arguments.contains("--demo-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task { @MainActor in
            if opts.startOrphanScan { model.startOrphanScan() }
            guard let name = opts.openAppName else { return }
            await model.appList.load()
            guard let app = model.appList.apps.first(where: { $0.name == name }) else { return }
            model.openApp(at: app.url)
            guard opts.openPreview else { return }
            while model.inspector?.phase == .scanning { try? await Task.sleep(for: .milliseconds(100)) }
            model.openPreview()
            if opts.autoExecute { model.cleanupFlow?.start() }
        }
    }
}
