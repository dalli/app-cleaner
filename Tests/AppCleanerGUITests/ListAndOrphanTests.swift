import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@MainActor
@Suite("App list (S1)")
struct AppListViewModelTests {
    @Test func filtersSortingAndLazySizes() async {
        let vm = AppListViewModel(engine: fastEngine())
        await vm.load()
        #expect(vm.apps.count == 14)
        #expect(vm.count(for: .appStore) == 5)
        #expect(vm.count(for: nil) == vm.apps.count)
        // 크기는 나중에 채운다
        #expect(await waitUntil { vm.pendingSizes.isEmpty })
        #expect(vm.apps.allSatisfy { $0.size != nil })
        #expect(!vm.sizeIsApproximate)

        vm.sourceFilter = .homebrew
        #expect(vm.filteredApps.allSatisfy { $0.source == .homebrew })
        vm.sourceFilter = nil
        vm.search = "microsoft"
        #expect(vm.filteredApps.count == 3)
        vm.search = "slackmac"   // 번들 ID 검색
        #expect(vm.filteredApps.map(\.name) == ["Slack"])
        vm.search = ""

        vm.sort = .size
        let sizes = vm.filteredApps.map { $0.size ?? 0 }
        #expect(sizes == sizes.sorted(by: >))
        vm.sort = .name
        let names = vm.filteredApps.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        vm.sort = .lastUsed
        #expect(vm.filteredApps.first?.lastUsed != nil)
    }

    @Test func longUnusedAccent() {
        let now = Date()
        let old = InstalledApp(url: URL(filePath: "/A.app"), bundleID: "a", name: "A", lastUsed: now.addingTimeInterval(-200 * 86_400))
        let recent = InstalledApp(url: URL(filePath: "/B.app"), bundleID: "b", name: "B", lastUsed: now.addingTimeInterval(-30 * 86_400))
        #expect(AppListViewModel.isLongUnused(old, now: now))
        #expect(!AppListViewModel.isLongUnused(recent, now: now))
    }
}

@MainActor
@Suite("Orphans (S5)")
struct OrphanViewModelTests {
    func loaded(_ engine: DemoCleanerEngine = fastEngine()) async -> OrphanViewModel {
        let vm = OrphanViewModel(engine: engine)
        vm.toastDuration = .zero
        #expect(vm.badgeCount == nil)
        vm.startScan(includeDotfiles: false)
        #expect(await waitUntil { vm.phase == .finished }, "고아 스캔이 끝나지 않음")
        return vm
    }

    @Test func scanProducesGroupsAndHidesKeepList() async {
        let vm = await loaded()
        #expect(vm.phase == .finished)
        #expect(vm.groups.count == 5)
        #expect(vm.badgeCount == 5)
        #expect(vm.hiddenByKeepList == 3)
        #expect(vm.spotlightIncomplete)
        #expect(vm.count(for: .high) == 2)
        #expect(vm.count(for: .medium) == 1)
        #expect(vm.count(for: .low) == 2)
    }

    @Test func defaultSelectionIsHighAndNotUserData() async {
        let vm = await loaded()
        #expect(vm.selectedLeaves.allSatisfy { $0.confidence == .high && $0.nature != .userData })
        #expect(vm.selectedItemCount == 13)
        #expect(vm.selectedGroupCount == 2)
    }

    @Test func selectHighOnly() async {
        let vm = await loaded()
        let charles = vm.groups.first { $0.displayName == "Charles" }!
        vm.toggle(charles)
        #expect(vm.state(of: charles) == .on)
        vm.selectHighOnly()
        #expect(vm.state(of: charles) == .off)
        #expect(vm.selectedLeaves.allSatisfy { $0.confidence == .high && $0.nature != .userData && !$0.share.isShared })
        #expect(vm.selectedItemCount == 13)
    }

    @Test func groupTriStateFollowsItems() async {
        let vm = await loaded()
        let slack = vm.groups.first { $0.displayName == "Slack" }!
        #expect(vm.state(of: slack) == .mixed)
        vm.toggle(slack)
        #expect(vm.state(of: slack) == .on)
        vm.toggle(slack.items[0])
        #expect(vm.state(of: slack) == .mixed)
    }

    @Test func keepAndUndo() async {
        let engine = fastEngine()
        let vm = await loaded(engine)
        let slack = vm.groups.first { $0.displayName == "Slack" }!
        let selectionBefore = vm.selectedItemCount
        vm.keep(slack)
        #expect(!vm.groups.contains { $0.id == slack.id })
        #expect(vm.badgeCount == 4)
        #expect(vm.hiddenByKeepList == 4)
        #expect(engine.keepList().contains { $0.key == slack.id })
        #expect(vm.keepUndo != nil)
        #expect(vm.selectedItemCount < selectionBefore)

        vm.undoKeep()
        #expect(vm.groups.contains { $0.id == slack.id })
        #expect(vm.groups.firstIndex { $0.id == slack.id } == 0)
        #expect(vm.hiddenByKeepList == 3)
        #expect(!engine.keepList().contains { $0.key == slack.id })
        #expect(vm.selectedItemCount == selectionBefore)
        #expect(vm.keepUndo == nil)
    }

    @Test func filterSortAndRows() async {
        let vm = await loaded()
        vm.confidenceFilter = .low
        #expect(vm.visibleGroups.allSatisfy { $0.confidence == .low })
        vm.confidenceFilter = nil
        vm.sort = .size
        let sizes = vm.visibleGroups.map(\.totalSize)
        #expect(sizes == sizes.sorted(by: >))
        vm.sort = .confidence
        #expect(vm.visibleGroups.first?.confidence == .high)
        // 처음 펼친 그룹은 3개 + "더 보기"
        vm.sort = .size
        let slackRows = vm.rows.prefix { if case .group(let g) = $0 { return g.displayName == "Slack" }; return true }
        #expect(slackRows.contains { if case .more(_, let n) = $0 { return n == 6 }; return false })
    }

    @Test func cancelKeepsPartialResults() async {
        var o = DemoCleanerEngine.Options()
        o.delayScale = 0.05
        let vm = OrphanViewModel(engine: DemoCleanerEngine(options: o))
        vm.startScan(includeDotfiles: false)
        _ = await waitUntil { !vm.groups.isEmpty }
        vm.cancelScan()
        #expect(await waitUntil { vm.phase == .cancelled })
        #expect(!vm.groups.isEmpty)
        #expect(vm.badgeCount != nil)
    }
}
