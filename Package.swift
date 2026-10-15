// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCleaner",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
        .executable(name: "appcleaner", targets: ["appcleaner"]),
        .executable(name: "AppCleanerHelper", targets: ["AppCleanerHelper"]),
        .executable(name: "AppCleanerGUI", targets: ["AppCleanerGUI"]),
        .executable(name: "AppCleanerSentinel", targets: ["AppCleanerSentinel"]),
    ],
    targets: [
        .target(
            name: "CleanerCore",
            resources: [.copy("Resources/RuleData"), .copy("Resources/Scripts"), .copy("Resources/Localization")]
        ),
        .target(
            name: "CleanerTestSupport",
            dependencies: ["CleanerCore"]
        ),
        .executableTarget(
            name: "appcleaner",
            dependencies: ["CleanerCore"]
        ),
        // 권한 헬퍼 (LaunchDaemon, #17) — scripts/build-app.sh가 Contents/MacOS에 넣는다
        .executableTarget(
            name: "AppCleanerHelper",
            dependencies: ["CleanerCore"]
        ),
        .executableTarget(
            name: "AppCleanerGUI",
            dependencies: ["CleanerCore"],
            resources: [.process("Resources")]
        ),
        // 메뉴 막대 상주 Sentinel (휴지통 감시·정기 고아 스캔 알림). build-app.sh가 본 앱의 Contents/Library/LoginItems에 넣는다
        .executableTarget(
            name: "AppCleanerSentinel",
            dependencies: ["CleanerCore"]
        ),
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore", "CleanerTestSupport"]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["appcleaner", "CleanerCore"]
        ),
        .testTarget(
            name: "AppCleanerGUITests",
            dependencies: ["AppCleanerGUI", "CleanerCore"]
        ),
    ]
)
