import AppKit
import SwiftUI

struct PinLeverDragState {
    private(set) var dragStarted = false
    private(set) var suppressTapUntilDeferredReset = false

    mutating func dragChanged() {
        dragStarted = true
    }

    /// Clears the active drag immediately and reports whether it crossed the pin threshold.
    mutating func dragEnded(translation: CGFloat, threshold: CGFloat = 8) -> Bool {
        let wasDrag = dragStarted
        dragStarted = false
        suppressTapUntilDeferredReset = wasDrag
        return wasDrag && abs(translation) >= threshold
    }

    var acceptsButtonAction: Bool {
        !dragStarted && !suppressTapUntilDeferredReset
    }

    mutating func resetTapSuppression() {
        suppressTapUntilDeferredReset = false
    }
}

/// A compact, drag-first pin control. Pull down to hold the panel open and lift to release it.
/// The binding remains the sole state owner; the view never reaches into the model.
struct PinLeverView: View {
    @Binding var isPinned: Bool
    var label = "Keep open"
    @State private var dragState = PinLeverDragState()
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            guard dragState.acceptsButtonAction else { return }
            setPinned(!isPinned)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.14)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.18), lineWidth: 0.7))
                Capsule().fill(.black.opacity(0.42)).frame(width: 2, height: 23)
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.35)],
                            startPoint: .top, endPoint: .bottom))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.45), lineWidth: 0.6))
                        .frame(width: 21, height: 8)
                        .overlay(Image(systemName: "line.3.horizontal")
                            .font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.42)))
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.68)).frame(width: 2, height: 7)
                }
                .offset(y: (isPinned ? 5 : -4) + dragOffset)
                .shadow(color: isPinned ? Color.accentColor.opacity(0.4) : .black.opacity(0.35), radius: 3, y: 1)
            }
            .frame(width: 34, height: 38)
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                dragState.dragChanged()
                dragOffset = min(9, max(-9, value.translation.height))
            }
            .onEnded { value in
                let shouldSetPin = dragState.dragEnded(translation: value.translation.height)
                dragOffset = 0
                DispatchQueue.main.async { dragState.resetTapSuppression() }
                guard shouldSetPin, let target = Self.dragTarget(for: value.translation.height) else { return }
                setPinned(target)
            })
        .help(isPinned ? "Pull up to unpin" : "Pull down to keep open")
        .accessibilityLabel(label)
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityHint("Click or press Space to toggle. Drag down to pin and up to unpin.")
        .accessibilityIdentifier("pin-lever")
        .accessibilityAddTraits(isPinned ? .isSelected : [])
    }

    static func dragTarget(for verticalDistance: CGFloat) -> Bool? {
        guard abs(verticalDistance) >= 8 else { return nil }
        return verticalDistance > 0
    }

    private func setPinned(_ value: Bool) {
        guard value != isPinned else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.62)) {
            isPinned = value
        }
        if NotchModel.shared.hapticsEnabled,
           !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }
}

/// Shift+= is the physical-key equivalent of Shift+plus on standard Mac layouts.
/// Use `install` from the root view and retain this controller for the view's lifetime.
@MainActor
final class CompactShortcutController {
    private var monitor: Any?

    func install(toggle: @escaping () -> Void) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isCompactShortcut(event), !Self.isEditingText(in: event.window) else { return event }
            MainActor.assumeIsolated { toggle() }
            return nil
        }
    }

    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    static func isCompactShortcut(_ event: NSEvent) -> Bool {
        !event.isARepeat && isCompactShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    static func isCompactShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 24, modifiers.contains(.shift) else { return false }
        var disallowed: NSEvent.ModifierFlags = []
        disallowed.insert(.command)
        disallowed.insert(.option)
        disallowed.insert(.control)
        return modifiers.intersection(disallowed).isEmpty
    }

    static func isEditingText(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isEditingTextResponder(window.firstResponder)
    }

    static func isEditingTextResponder(_ responder: NSResponder?) -> Bool {
        if let field = responder as? NSTextField { return field.isEditable }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return false
    }
}
