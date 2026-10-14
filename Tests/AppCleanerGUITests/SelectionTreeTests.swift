import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@Suite("SelectionTree")
struct SelectionTreeTests {
    let container = candidate("/c", children: [
        candidate("/c/Caches", nature: .regenerable),
        candidate("/c/Prefs"),
        candidate("/c/Documents", nature: .userData, selected: false),
    ])
    let plain = candidate("/p")
    let locked = candidate("/icloud", nature: .synced, protection: .iCloudData, selected: true)

    @Test func defaultSelectionComesFromEngine() {
        let tree = SelectionTree(roots: [container, plain, locked])
        #expect(tree.selected == ["/c/Caches", "/c/Prefs", "/p"])
        #expect(tree.state(of: container) == .mixed)
        #expect(tree.state(of: plain) == .on)
    }

    @Test func protectedItemsAreNeverSelected() {
        var tree = SelectionTree(roots: [locked])
        #expect(tree.selected.isEmpty)
        tree.toggle(locked)
        #expect(tree.selected.isEmpty)
        tree.set([locked], on: true)
        #expect(tree.state(of: locked) == .off)
    }

    @Test func togglingContainerSelectsAllChildren() {
        var tree = SelectionTree(roots: [container])
        tree.toggle(container)   // mixed → all
        #expect(tree.state(of: container) == .on)
        #expect(tree.selectedPaths == ["/c", "/c/Caches", "/c/Prefs", "/c/Documents"])
        tree.toggle(container)   // all → none
        #expect(tree.state(of: container) == .off)
        #expect(tree.selectedPaths.isEmpty)
    }

    @Test func childChangesPropagateToContainerAndCategory() {
        var tree = SelectionTree(roots: [container, plain])
        tree.toggle(container.children[2])   // Documents 선택 → 컨테이너 전체
        #expect(tree.state(of: container) == .on)
        #expect(tree.state(of: [container, plain]) == .on)
        tree.toggle(plain)
        #expect(tree.state(of: [container, plain]) == .mixed)
        tree.set([container, plain], on: false)
        #expect(tree.state(of: [container, plain]) == .off)
    }

    @Test func containerPathOnlyWhenEveryChildSelected() {
        let tree = SelectionTree(roots: [container])
        #expect(!tree.selectedPaths.contains("/c"))
        let withLock = candidate("/c2", children: [candidate("/c2/a"), candidate("/c2/b", protection: .iCloudData)])
        var t2 = SelectionTree(roots: [withLock])
        t2.set(withLock, on: true)
        #expect(t2.state(of: withLock) == .on)          // 선택 가능한 잎은 모두 선택
        #expect(t2.selectedPaths == ["/c2/a"])           // 보호된 하위 항목이 있으면 컨테이너 자체는 옮기지 않는다
    }

    @Test func mergeKeepsUserChoicesAndAddsDefaultsForNewLeaves() {
        var tree = SelectionTree(roots: [plain])
        tree.toggle(plain)
        #expect(tree.selected.isEmpty)
        tree.merge(roots: [plain, candidate("/new")])
        #expect(tree.selected == ["/new"])
        tree.merge(roots: [candidate("/new")])
        #expect(tree.selected == ["/new"])
    }

    @Test func keptSummaryBuckets() {
        let items = [
            locked,
            candidate("/s", share: .shared(usedBy: ["Excel"], reason: "")),
            candidate("/u", nature: .userData),
            candidate("/l", .low, share: .shared(usedBy: ["Excel"], reason: "")),
            candidate("/o"),
        ]
        let s = KeptSummary(items)
        #expect(s == { var k = KeptSummary(); k.protected = 1; k.shared = 1; k.userData = 1; k.low = 1; k.other = 1; return k }())
        #expect(s.total == 5)
    }

    @Test func checkStateSpokenValues() {
        #expect(CheckState.mixed.spokenValue == L("일부 선택됨"))
        #expect(CheckState.on.spokenValue != CheckState.off.spokenValue)
    }
}
