import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@MainActor
@Suite("Inspector (S2)")
struct InspectorViewModelTests {
    func wordVM() -> InspectorViewModel {
        InspectorViewModel(report: DemoData.word(wordURL), engine: fastEngine())
    }

    @Test func loadsThroughEngine() async {
        let vm = InspectorViewModel(appURL: wordURL, engine: fastEngine())
        #expect(vm.phase == .scanning)
        await vm.load()
        #expect(vm.phase == .loaded)
        #expect(vm.identity?.bundleID == "com.microsoft.Word")
    }

    @Test func defaultSelectionAndCounts() {
        let vm = wordVM()
        #expect(vm.count(for: .all) == 17)
        #expect(vm.count(for: .selected) == 10)
        #expect(vm.count(for: .kept) == 7)
        #expect(vm.canPreview)
        // 공유 그룹 컨테이너·사용자 데이터·낮음은 기본 미선택, 보통(이름 일치 로그)은 선택
        let office = vm.allLeaves.first { $0.path.hasSuffix("UBF8T346G9.Office") }!
        #expect(vm.state(of: office) == .off)
        let logs = vm.allLeaves.first { $0.path.hasSuffix("Logs/Microsoft Word") }!
        #expect(vm.state(of: logs) == .on)
    }

    @Test func keptSummaryMatchesSpec() {
        let k = wordVM().keptSummary
        #expect(k.shared == 2)
        #expect(k.userData == 1)
        #expect(k.low == 4)
        #expect(k.total == 7)
    }

    @Test func categoryToggleAndContainerChildren() throws {
        let vm = wordVM()
        let container = try #require(vm.sections.first { $0.category == .container })
        #expect(vm.state(of: container) == .mixed)
        vm.toggle(container)
        #expect(vm.state(of: container) == .on)
        #expect(vm.selectedPaths.contains(container.allItems[0].path))   // 컨테이너 전체를 옮긴다
        // 하위 항목 하나를 해제하면 카테고리·컨테이너가 일부 선택으로
        let docs = container.allItems[0].children.first { $0.nature == .userData }!
        vm.toggle(docs)
        #expect(vm.state(of: container) == .mixed)
        #expect(vm.state(of: container.allItems[0]) == .mixed)
        #expect(!vm.selectedPaths.contains(container.allItems[0].path))
    }

    @Test func riskySelectionIsEmphasised() {
        let vm = wordVM()
        let office = vm.allLeaves.first { $0.path.hasSuffix("UBF8T346G9.Office") }!
        #expect(!vm.isRiskySelection(office))
        vm.toggle(office)
        #expect(vm.isRiskySelection(office))
    }

    @Test func protectedItemsCannotBeSelected() {
        let vm = InspectorViewModel(report: DemoData.slack(slackURL), engine: fastEngine())
        let icloud = vm.allLeaves.first { $0.category == .iCloudContainer }!
        #expect(!icloud.isSelectable)
        let before = vm.selectedCount
        vm.toggle(icloud)
        #expect(vm.selectedCount == before)
        #expect(vm.keptSummary.protected == 1)
    }

    @Test func viewFiltersAndLowConfidenceToggle() {
        let vm = wordVM()
        #expect(!vm.sections.contains { $0.category == .lowConfidence })
        vm.showLowConfidence = true
        #expect(vm.sections.contains { $0.category == .lowConfidence })
        vm.viewFilter = .selected
        let selectedLeaves = vm.sections.flatMap(\.items).flatMap(SelectionTree.leaves(of:))
        #expect(selectedLeaves.count == 10)
        #expect(selectedLeaves.allSatisfy { vm.state(of: $0) == .on })
        vm.viewFilter = .kept
        let keptLeaves = vm.sections.flatMap(\.items).flatMap(SelectionTree.leaves(of:))
        #expect(keptLeaves.count == 7)
        #expect(!vm.sections.contains { $0.category == .appBundle })
    }

    @Test func outlineRowsFollowCollapseState() throws {
        let vm = wordVM()
        let total = vm.rows.count
        let container = try #require(vm.rows.first { if case .item(let c, _) = $0 { return !c.children.isEmpty }; return false })
        vm.setExpanded(container, false)
        #expect(vm.rows.count == total - 3)
        let cat = vm.rows[0]
        vm.focusedID = cat.id
        vm.setFocusedExpanded(false)
        #expect(vm.rows.count == total - 3 - 1)
    }

    @Test func spaceTogglesFocusedRow() {
        let vm = wordVM()
        let plist = vm.allLeaves.first { $0.path.hasSuffix("com.microsoft.Word.plist") }!
        vm.focusedID = plist.id
        vm.toggleFocused()
        #expect(vm.state(of: plist) == .off)
    }

    @Test func fullDiskAccessBanner() {
        let vm = wordVM()
        #expect(vm.banners(permissions: PermissionStatus(fullDiskAccess: .granted)) == [.appRunning])
        #expect(vm.banners(permissions: PermissionStatus(fullDiskAccess: .denied)).contains(.noFullDiskAccess))
    }

    @Test func accessibilityLabelFollowsSpecExample() {
        let vm = wordVM()
        let office = vm.allLeaves.first { $0.path.hasSuffix("UBF8T346G9.Office") }!
        let label = AccessibilityText.candidate(office, state: vm.state(of: office))
        #expect(label.hasPrefix("UBF8T346G9.Office, "))
        #expect(label.contains(Confidence.high.fullTitle))
        #expect(label.contains(L("공유: %@ 외 %lld개 앱 사용 중", "Microsoft Excel", 2)))
        #expect(label.hasSuffix(CheckState.off.spokenValue))
    }
}
