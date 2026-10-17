import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@MainActor
@Suite("Homebrew")
struct HomebrewViewModelTests {
    @Test func listsFormulaeAndCasksWithSizes() async {
        let vm = HomebrewViewModel(engine: fastEngine())
        await vm.load()
        #expect(vm.count(for: nil) == 10)
        #expect(vm.count(for: .formula) == 7)
        #expect(vm.count(for: .cask) == 3)
        #expect(vm.dependencyCount == 3)

        #expect(await waitUntil { vm.pendingSizes.isEmpty })
        #expect(vm.items.allSatisfy { vm.size(of: $0) != nil })
        #expect(!vm.sizeIsApproximate)

        vm.kindFilter = .cask
        #expect(vm.filteredItems.allSatisfy { $0.kind == .cask })
        vm.kindFilter = nil
        vm.search = "OPENSSL"
        #expect(vm.filteredItems.map(\.name) == ["openssl@3"])
        vm.search = ""

        vm.sort = .size
        let sizes = vm.filteredItems.map { vm.size(of: $0) ?? 0 }
        #expect(sizes == sizes.sorted(by: >))
        vm.sort = .name
        let names = vm.filteredItems.map(\.name)
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func routeAndRevealPath() async {
        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        model.select(.homebrew)
        #expect(model.route == .homebrew)
        #expect(model.settings.lastRoute == .homebrew)
        await model.homebrew.load()
        let docker = model.homebrew.items.first { $0.name == "docker" }
        model.homebrew.focusedID = docker?.id
        #expect(model.revealPath == docker?.location.path)
    }
}
