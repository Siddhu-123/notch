import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import notch

struct Phase6InteractionTests {
    @Test
    func shortDragClearsDragLatchAndSuppressesOnlyItsButtonAction() {
        var state = PinLeverDragState()
        state.dragChanged()

        let crossedThreshold = state.dragEnded(translation: 7.9)
        #expect(!crossedThreshold)
        #expect(!state.dragStarted)
        #expect(!state.acceptsButtonAction)

        state.resetTapSuppression()
        #expect(state.acceptsButtonAction)
    }

    @Test(arguments: [CGFloat(8), CGFloat(-8), CGFloat(12), CGFloat(-12)])
    func thresholdDragClearsLatchAndBlocksClickUntilDeferredReset(translation: CGFloat) {
        var state = PinLeverDragState()
        state.dragChanged()

        let crossedThreshold = state.dragEnded(translation: translation)
        #expect(crossedThreshold)
        #expect(!state.dragStarted)
        #expect(!state.acceptsButtonAction)

        state.resetTapSuppression()
        #expect(state.acceptsButtonAction)
    }

    @Test
    func pinTargetUsesDirectionOnlyAfterEightPointThreshold() {
        #expect(PinLeverView.dragTarget(for: 7.9) == nil)
        #expect(PinLeverView.dragTarget(for: -7.9) == nil)
        #expect(PinLeverView.dragTarget(for: 8) == true)
        #expect(PinLeverView.dragTarget(for: -8) == false)
    }

    @MainActor
    @Test
    func shortcutTextGuardOnlyBlocksEditableControls() {
        let field = NSTextField(string: "")
        field.isEditable = true
        #expect(CompactShortcutController.isEditingTextResponder(field))

        let editor = NSTextView()
        editor.isEditable = true
        #expect(CompactShortcutController.isEditingTextResponder(editor))

        let display = NSTextView()
        display.isEditable = false
        #expect(!CompactShortcutController.isEditingTextResponder(display))

        let host = NSHostingView(rootView: Text("panel content"))
        #expect(!CompactShortcutController.isEditingTextResponder(host))
    }

    @MainActor
    @Test
    func shortcutKeepsShiftEqualKeyMapping() {
        #expect(CompactShortcutController.isCompactShortcut(keyCode: 24, modifiers: .shift))
        let noModifiers = NSEvent.ModifierFlags(rawValue: 0)
        #expect(!CompactShortcutController.isCompactShortcut(keyCode: 24, modifiers: noModifiers))
        var shiftCommand = NSEvent.ModifierFlags.shift
        shiftCommand.insert(.command)
        #expect(!CompactShortcutController.isCompactShortcut(keyCode: 24, modifiers: shiftCommand))
    }
}
