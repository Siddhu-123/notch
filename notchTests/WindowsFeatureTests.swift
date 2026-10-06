import Foundation
import Testing
@testable import notch

@Test func snapGeometrySplitsVisibleFrameAndPreservesOddRemainders() {
    let visible = CGRect(x: -100, y: 20, width: 101, height: 81)

    #expect(SnapGeometry.frame(for: .left, in: visible) == CGRect(x: -100, y: 20, width: 50, height: 81))
    #expect(SnapGeometry.frame(for: .right, in: visible) == CGRect(x: -50, y: 20, width: 51, height: 81))
    #expect(SnapGeometry.frame(for: .top, in: visible) == CGRect(x: -100, y: 60, width: 101, height: 41))
    #expect(SnapGeometry.frame(for: .bottom, in: visible) == CGRect(x: -100, y: 20, width: 101, height: 40))
    #expect(SnapGeometry.frame(for: .maximize, in: visible) == visible)
    #expect(SnapGeometry.frame(for: .center, in: visible) == CGRect(x: -74.5, y: 40.5, width: 50, height: 40))
}

@Test func snapGeometryFlipsAppKitYIntoAccessibilityCoordinates() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 860)

    #expect(SnapGeometry.frame(for: .maximize, in: visible, desktopTop: screen.maxY) == CGRect(x: 0, y: 40, width: 1440, height: 860))
    #expect(SnapGeometry.frame(for: .left, in: visible, desktopTop: screen.maxY) == CGRect(x: 0, y: 40, width: 720, height: 860))

    let screenAboveMain = CGRect(x: 1440, y: 900, width: 1200, height: 800)
    let externalVisible = CGRect(x: 1440, y: 900, width: 1200, height: 760)
    #expect(SnapGeometry.frame(for: .maximize, in: externalVisible, desktopTop: screen.maxY) == CGRect(x: 1440, y: -760, width: 1200, height: 760))
    #expect(screenAboveMain.maxY == 1700)
}

@Test func quitPolicyOnlyQuitsUnexcludedAppsWithNoWindows() {
    #expect(QuitPolicy.shouldQuit(bundleID: "com.example.Editor", windowCount: 0, excluded: []))
    #expect(!QuitPolicy.shouldQuit(bundleID: "com.example.Editor", windowCount: 1, excluded: []))
    #expect(!QuitPolicy.shouldQuit(bundleID: "com.example.Editor", windowCount: -1, excluded: []))
    #expect(!QuitPolicy.shouldQuit(bundleID: "com.example.Editor", windowCount: 0, excluded: ["com.example.editor"]))
    #expect(!QuitPolicy.shouldQuit(bundleID: "com.apple.finder", windowCount: 0, excluded: []))
    #expect(!QuitPolicy.shouldQuit(bundleID: "   ", windowCount: 0, excluded: []))
}

@Test func quitGuardPromptsFirstAndPassesSecondPressBeforeOneSecond() {
    var guardState = QuitGuard()
    #expect(guardState.process(.commandQDown(at: 10)) == .swallowAndPrompt)
    #expect(guardState.process(.commandQUp(at: 10.2)) == .swallow)
    #expect(guardState.process(.commandQDown(at: 10.999)) == .passThrough)
    #expect(guardState.process(.commandQUp(at: 11.05)) == .passThrough)
}

@Test func quitGuardStartsANewPromptAtTheOneSecondBoundary() {
    var guardState = QuitGuard()
    #expect(guardState.process(.commandQDown(at: 0)) == .swallowAndPrompt)
    #expect(guardState.process(.commandQUp(at: 0.2)) == .swallow)
    #expect(guardState.process(.commandQDown(at: 1)) == .swallowAndPrompt)
}

@Test func quitGuardSwallowsTheWholeFirstPressAndKeepsPassedSecondPressWhole() {
    var guardState = QuitGuard()
    #expect(guardState.process(.commandQDown(at: 5)) == .swallowAndPrompt)
    #expect(guardState.process(.commandQDown(at: 5.1)) == .swallow)
    #expect(guardState.process(.commandQUp(at: 5.2)) == .swallow)
    #expect(guardState.process(.commandQDown(at: 5.5)) == .passThrough)
    #expect(guardState.process(.commandQDown(at: 5.6)) == .passThrough)
    #expect(guardState.process(.commandQUp(at: 5.7)) == .passThrough)
}

@Test func quitGuardAcceptsHoldAtPointSixSecondsAndRejectsShorterHold() {
    var held = QuitGuard()
    #expect(held.process(.commandQDown(at: 2)) == .swallowAndPrompt)
    #expect(held.process(.commandQUp(at: 2.599)) == .swallow)
    #expect(held.process(.commandQDown(at: 2.7)) == .passThrough)

    var longHeld = QuitGuard()
    #expect(longHeld.process(.commandQDown(at: 4)) == .swallowAndPrompt)
    #expect(longHeld.process(.commandQUp(at: 4.6)) == .synthesizeQuit)
}

@Test func quitGuardPassesAStillHeldFirstPressAtTheThresholdAndSwallowsItsKeyUp() {
    var guardState = QuitGuard()
    #expect(guardState.process(.commandQDown(at: 0)) == .swallowAndPrompt)
    #expect(guardState.process(.holdThresholdReached(at: 0.599)) == .none)
    #expect(guardState.process(.holdThresholdReached(at: 0.6)) == .synthesizeQuit)
    #expect(guardState.process(.commandQDown(at: 0.7)) == .swallow)
    #expect(guardState.process(.commandQUp(at: 0.8)) == .swallow)
}

@Test func quitExclusionListNormalizesAndBoundsEntries() {
    #expect(QuitExclusionList.normalize("  COM.Example.Editor  ") == "com.example.editor")
    #expect(QuitExclusionList.normalize("not-a-bundle") == nil)
    #expect(QuitExclusionList.normalize("com..example") == nil)
    #expect(QuitExclusionList.normalize("com.example;open") == nil)
    #expect(QuitExclusionList.normalize("a." + String(repeating: "b", count: 253)) != nil)
    #expect(QuitExclusionList.normalize("a." + String(repeating: "b", count: 254)) == nil)
    let filled = (0..<QuitExclusionList.maximumEntries).map { "com.example.app\($0)" }
    #expect(QuitExclusionList.adding("com.example.new", to: filled) == filled)
    #expect(QuitExclusionList.adding("COM.EXAMPLE.APP0", to: filled) == filled)
    #expect(QuitExclusionList.adding("com.example.new", to: Array(filled.prefix(1))) == [filled[0], "com.example.new"])
}
