import Foundation
import Testing
@testable import notch

struct KeysFeatureTests {
    @Test func hyperTapEmitsEscapeOnlyBelowTwoHundredMilliseconds() {
        var quickTap = HyperState()
        #expect(quickTap.process(.f18Down(at: 10), tapAction: .escape) == [.modifiers(true)])
        #expect(quickTap.process(.f18Up(at: 10.199), tapAction: .escape) == [.modifiers(false), .tap(.escape)])
        #expect(!quickTap.isDown)

        var boundaryTap = HyperState()
        _ = boundaryTap.process(.f18Down(at: 0), tapAction: .escape)
        #expect(boundaryTap.process(.f18Up(at: 0.2), tapAction: .escape) == [.modifiers(false)])
    }

    @Test func anotherKeyTurnsCapsLockHoldIntoHyperUse() {
        var state = HyperState()
        _ = state.process(.f18Down(at: 1), tapAction: .escape)
        #expect(state.process(.otherKeyDown, tapAction: .escape).isEmpty)
        #expect(state.isDown)
        #expect(state.process(.f18Up(at: 1.05), tapAction: .escape) == [.modifiers(false)])
    }

    @Test func repeatedOrUnmatchedCapsLockEventsAreIgnored() {
        var state = HyperState()
        #expect(state.process(.f18Up(at: 0), tapAction: .escape).isEmpty)
        #expect(state.process(.f18Down(at: 0), tapAction: .escape) == [.modifiers(true)])
        #expect(state.process(.f18Down(at: 0.01), tapAction: .escape).isEmpty)
        #expect(state.process(.f18Up(at: 0.25), tapAction: .nothing) == [.modifiers(false)])
    }

    @Test(arguments: [HyperTapAction.escape, .capsLock, .nothing])
    func quickTapPreservesTheSelectedTapAction(_ action: HyperTapAction) {
        var state = HyperState()
        _ = state.process(.f18Down(at: 0), tapAction: action)
        #expect(state.process(.f18Up(at: 0.1), tapAction: action) == [.modifiers(false), .tap(action)])
    }

    @Test func mappingMergeReplacesOnlyTheSameSourceAndIsIdempotent() {
        let other = UserKeyMappingEntry(source: 42, destination: 43)
        let previousCaps = UserKeyMappingEntry(source: UserKeyMapping.capsLockToF18.source, destination: 44)
        let merged = UserKeyMapping.merge(existing: [other, previousCaps], adding: UserKeyMapping.capsLockToF18)
        #expect(merged == [other, UserKeyMapping.capsLockToF18])
        #expect(UserKeyMapping.merge(existing: merged, adding: UserKeyMapping.capsLockToF18) == merged)
    }

    @Test func mappingRemoveDeletesOnlyTheOwnedEntry() {
        let other = UserKeyMappingEntry(source: 1, destination: 2)
        let unrelatedCaps = UserKeyMappingEntry(source: UserKeyMapping.capsLockToF18.source, destination: 55)
        #expect(UserKeyMapping.remove(existing: [UserKeyMapping.capsLockToF18, other]) == [other])
        #expect(UserKeyMapping.remove(existing: [UserKeyMapping.capsLockToF18, other]) == [other])
        #expect(UserKeyMapping.remove(existing: [unrelatedCaps, other]) == [unrelatedCaps, other])
        #expect(UserKeyMapping.remove(existing: [UserKeyMapping.capsLockToF18]) == [])
    }

    @Test func mappingParserReadsHexDecimalAndEmptyPropertyLists() {
        let output = """
        UserKeyMapping: (
            { HIDKeyboardModifierMappingDst = 0x70000006D; HIDKeyboardModifierMappingSrc = 0x700000039; },
            { HIDKeyboardModifierMappingSrc = 42; HIDKeyboardModifierMappingDst = 43; }
        )
        """
        #expect(UserKeyMapping.parse(output) == [
            UserKeyMapping.capsLockToF18,
            UserKeyMappingEntry(source: 42, destination: 43)
        ])
        #expect(UserKeyMapping.parse("UserKeyMapping: ( )") == [])
        #expect(UserKeyMapping.parse("not hidutil output") == nil)
    }

    @Test func shortcutCodecSkipsInvalidRowsAndCapsStorageAtTwenty() throws {
        var rows: [[String: Any]] = (0..<21).map { index in
            ["id": UUID().uuidString, "key": "\(index % 10)", "action": "openApp", "target": "com.example.App"]
        }
        rows.append(["key": "x", "action": "missing", "target": "invalid"])
        let data = try JSONSerialization.data(withJSONObject: rows)
        let decoded = HyperShortcutCodec.decode(data)
        #expect(decoded.count == HyperShortcutCodec.maximumEntries)
        #expect(decoded.first?.action == .openApp)
        #expect(HyperShortcutCodec.decode(Data("bad".utf8)).isEmpty)
        #expect(HyperShortcutCodec.decode(nil).isEmpty)
        #expect(HyperShortcutCodec.encode(decoded).flatMap(HyperShortcutCodec.decode)?.count == 20)
    }

    @Test func runtimeShortcutValidationRequiresOneKeyAndTarget() {
        #expect(HyperShortcutCodec.normalizedKey(" a ") == "A")
        #expect(HyperShortcutCodec.normalizedKey("ab") == nil)
        #expect(HyperShortcutCodec.normalizedKey(" ") == nil)

        let shortcuts = [
            HyperShortcut(key: "a", action: .openApp, target: " com.example.App "),
            HyperShortcut(key: "too long", action: .openURL, target: "https://example.com"),
            HyperShortcut(key: "b", action: .runShortcut, target: "  ")
        ]
        #expect(HyperShortcutCodec.runtimeEntries(shortcuts) == [[
            "key": "A", "action": "openApp", "target": "com.example.App"
        ]])
    }
}
