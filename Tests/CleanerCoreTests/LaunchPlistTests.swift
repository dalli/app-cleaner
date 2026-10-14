import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct LaunchPlistTests {
    @Test func directProgram() throws {
        let fx = try Fixture()
        let url = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.foo.agent.plist"), label: "com.foo.agent",
                                         arguments: ["/Applications/Foo.app/Contents/MacOS/agent", "--daemon"], keepAlive: true)
        let p = try #require(LaunchPlist.read(at: url))
        #expect(p.label == "com.foo.agent")
        #expect(p.effectiveExecutable == "/Applications/Foo.app/Contents/MacOS/agent")
        #expect(p.keepAlive && p.runAtLoad)
        #expect(p.points(into: URL(fileURLWithPath: "/Applications/Foo.app")))
        #expect(!p.points(into: URL(fileURLWithPath: "/Applications/Fo.app")))
    }

    @Test func shellWrappedProgramIsUnwrapped() throws {
        let fx = try Fixture()
        let url = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/x.plist"), label: "x",
                                         arguments: ["/bin/sh", "-c", "exec '/Applications/My App.app/Contents/MacOS/helper' --x"])
        let p = try #require(LaunchPlist.read(at: url))
        #expect(p.targetExecutable == "/Applications/My App.app/Contents/MacOS/helper")
        #expect(!p.targetExtractionFailed)
    }

    @Test func interpreterAndOpen() throws {
        let fx = try Fixture()
        let py = try fx.makeLaunchPlist(at: fx.home("a.plist"), label: "a",
                                        arguments: ["/usr/bin/python3", "/Users/me/Library/Foo/run.py"])
        #expect(LaunchPlist.read(at: py)?.targetExecutable == "/Users/me/Library/Foo/run.py")
        let open = try fx.makeLaunchPlist(at: fx.home("b.plist"), label: "b",
                                          arguments: ["/usr/bin/open", "-a", "/Applications/Foo.app"])
        #expect(LaunchPlist.read(at: open)?.targetExecutable == "/Applications/Foo.app")
    }

    @Test func extractionFailureIsFlagged() throws {
        let fx = try Fixture()
        let url = try fx.makeLaunchPlist(at: fx.home("c.plist"), label: "c", arguments: ["/bin/bash", "-c", "foo-cli --sync"])
        let p = try #require(LaunchPlist.read(at: url))
        #expect(p.targetExecutable == nil)
        #expect(p.targetExtractionFailed)
    }
}
