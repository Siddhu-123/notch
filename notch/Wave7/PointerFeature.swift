import ApplicationServices
import CoreGraphics
import Foundation
import SwiftUI

enum PointerScrollModifier: String, CaseIterable, Identifiable {
    case shift
    case option

    var id: String { rawValue }
    var title: String { self == .shift ? "Shift" : "Option" }
}

enum MouseButtonShortcutAction: String, CaseIterable, Identifiable {
    case missionControl
    case appExpose
    case launchpad
    case showDesktop
    case copy
    case paste
    case back
    case forward

    var id: String { rawValue }
    var title: String {
        switch self {
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .launchpad: "Launchpad"
        case .showDesktop: "Show Desktop"
        case .copy: "Copy"
        case .paste: "Paste"
        case .back: "Back"
        case .forward: "Forward"
        }
    }
}

struct ScrollDelta: Equatable {
    var vertical: Double
    var horizontal: Double
}

struct PointerModifiers: OptionSet {
    let rawValue: Int
    static let shift = PointerModifiers(rawValue: 1 << 0)
    static let option = PointerModifiers(rawValue: 1 << 1)
}

enum ScrollTransform {
    static func apply(
        verticalDelta: Double,
        horizontalDelta: Double,
        isContinuous: Bool,
        modifiers: PointerModifiers = [],
        reverseMouse: Bool = false,
        horizontalModifier: PointerScrollModifier? = nil
    ) -> ScrollDelta {
        guard !isContinuous else { return ScrollDelta(vertical: verticalDelta, horizontal: horizontalDelta) }

        var vertical = reverseMouse ? -verticalDelta : verticalDelta
        var horizontal = reverseMouse ? -horizontalDelta : horizontalDelta
        let modifierIsDown: Bool
        switch horizontalModifier {
        case .shift: modifierIsDown = modifiers.contains(.shift)
        case .option: modifierIsDown = modifiers.contains(.option)
        case nil: modifierIsDown = false
        }
        if modifierIsDown {
            horizontal += vertical
            vertical = 0
        }
        return ScrollDelta(vertical: vertical, horizontal: horizontal)
    }
}

enum ScrollEasing {
    /// Ease-out cubic increments whose total is exactly `delta` (up to floating-point rounding).
    static func samples(delta: Double, duration: Double, hz: Double) -> [Double] {
        guard delta.isFinite, duration.isFinite, hz.isFinite, duration > 0, hz > 0 else { return [] }
        let requestedCount = ceil(duration * hz)
        guard requestedCount.isFinite else { return [] }
        let count = min(512, max(1, Int(min(requestedCount, 512))))
        guard delta != 0 else { return Array(repeating: 0, count: count) }

        var values: [Double] = []
        values.reserveCapacity(count)
        var previous = 0.0
        for index in 1...count {
            let progress = Double(index) / Double(count)
            let eased = 1 - pow(1 - progress, 3)
            let cumulative = index == count ? delta : delta * eased
            values.append(cumulative - previous)
            previous = cumulative
        }
        return values
    }
}

struct ClickFilter {
    private var lastAccepted: (button: Int, time: TimeInterval)?

    mutating func shouldSwallow(button: Int, at time: TimeInterval, clickState: Int, thresholdMS: Double) -> Bool {
        guard time.isFinite else { return false }
        let threshold = min(150, max(20, thresholdMS.isFinite ? thresholdMS : 60)) / 1_000
        if clickState >= 2 {
            lastAccepted = (button, time)
            return false
        }
        if let lastAccepted, lastAccepted.button == button {
            let elapsed = time - lastAccepted.time
            if elapsed >= 0, elapsed < threshold - 1e-9 { return true }
        }
        lastAccepted = (button, time)
        return false
    }
}

struct KeyDebounce {
    enum Event {
        case keyDown(keyCode: Int, autorepeat: Bool)
        case keyUp(keyCode: Int)
    }

    private var keyUpTimes: [Int: TimeInterval] = [:]
    private var swallowedDowns: Set<Int> = []

    /// Returns true when the event is consumed. Matching key-up events for a
    /// swallowed chatter down are consumed as well so applications see no stray up.
    mutating func process(_ event: Event, at time: TimeInterval, thresholdMS: Double) -> Bool {
        guard time.isFinite else { return false }
        switch event {
        case let .keyDown(keyCode, autorepeat):
            guard (0...255).contains(keyCode), !autorepeat else { return false }
            let threshold = min(150, max(20, thresholdMS.isFinite ? thresholdMS : 40)) / 1_000
            if let previousUp = keyUpTimes[keyCode] {
                let elapsed = time - previousUp
                if elapsed >= 0, elapsed < threshold {
                    swallowedDowns.insert(keyCode)
                    return true
                }
                keyUpTimes.removeValue(forKey: keyCode)
            }
            return false

        case let .keyUp(keyCode):
            guard (0...255).contains(keyCode) else { return false }
            if swallowedDowns.remove(keyCode) != nil { return true }
            keyUpTimes[keyCode] = time
            keyUpTimes = keyUpTimes.filter { time - $0.value <= 2 }
            if keyUpTimes.count > 256 {
                let oldest = keyUpTimes.min { $0.value < $1.value }?.key
                if let oldest { keyUpTimes.removeValue(forKey: oldest) }
            }
            return false
        }
    }
}

struct PointerTouchPoint: Equatable {
    let x: Double
    let y: Double
}

struct ThreeFingerTapDetector {
    static let maximumDuration = 0.2
    static let maximumMovement = 0.03

    private var beganAt: TimeInterval?
    private var origins: [PointerTouchPoint] = []
    private var movedTooFar = false

    mutating func update(points: [PointerTouchPoint], at time: TimeInterval) -> Bool {
        guard time.isFinite else { reset(); return false }
        if points.isEmpty {
            guard let beganAt else { reset(); return false }
            let isTap = !movedTooFar && time >= beganAt && time - beganAt < Self.maximumDuration
            reset()
            return isTap
        }
        guard points.count == 3 else { reset(); return false }
        guard let beganAt else {
            self.beganAt = time
            origins = points
            movedTooFar = false
            return false
        }
        guard time >= beganAt, time - beganAt < Self.maximumDuration else {
            movedTooFar = true
            return false
        }
        for (origin, current) in zip(origins, points) {
            let distance = hypot(current.x - origin.x, current.y - origin.y)
            if distance > Self.maximumMovement { movedTooFar = true }
        }
        return false
    }

    private mutating func reset() {
        beganAt = nil
        origins.removeAll(keepingCapacity: true)
        movedTooFar = false
    }
}

enum PointerFeature {
    static let reverseMouseKey = "notch.pointer.reverseMouse"
    static let horizontalModifierKey = "notch.pointer.horizontalModifier"
    static let doubleClickThresholdKey = "notch.pointer.doubleClickThresholdMS"
    static let keyDebounceThresholdKey = "notch.pointer.keyDebounceThresholdMS"
    static let middleButtonActionKey = "notch.pointer.button.2"
    static let backButtonActionKey = "notch.pointer.button.3"
    static let forwardButtonActionKey = "notch.pointer.button.4"

    static func apply(_ feature: NotchFeature, enabled: Bool) {
        guard feature.group == .pointer else { return }
        configure()
    }

    static func configure(defaults: UserDefaults = .standard) {
        var features = Dictionary(uniqueKeysWithValues: pointerFeatures.map { ($0.rawValue, NotchFeatureRegistry.isEnabled($0, defaults: defaults)) })
        let reverseMouse = defaults.object(forKey: reverseMouseKey) as? Bool ?? true
        let modifier = PointerScrollModifier(rawValue: defaults.string(forKey: horizontalModifierKey) ?? "shift") ?? .shift
        let clickThreshold = defaults.object(forKey: doubleClickThresholdKey) as? Double ?? 60
        let keyThreshold = defaults.object(forKey: keyDebounceThresholdKey) as? Double ?? 40
        let actions: [String: String] = [
            "2": action(forKey: middleButtonActionKey, defaults: defaults).rawValue,
            "3": action(forKey: backButtonActionKey, defaults: defaults).rawValue,
            "4": action(forKey: forwardButtonActionKey, defaults: defaults).rawValue
        ]
        let accessibilityTrusted = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        features = features.mapValues { $0 }
        let args: [String: Any] = [
            "features": features,
            "settings": [
                "reverseMouse": reverseMouse,
                "horizontalModifier": modifier.rawValue,
                "doubleClickThresholdMS": min(150, max(20, clickThreshold)),
                "keyDebounceThresholdMS": min(150, max(20, keyThreshold)),
                "buttonActions": actions,
                "accessibilityTrusted": accessibilityTrusted,
                "inputMonitoring": inputMonitoring,
                "hostBundleIdentifier": Bundle.main.bundleIdentifier ?? "sidco.notch"
            ] as [String: Any]
        ]
        NotchSystemHelperClient.shared.perform("pointer", "configure", args: args, timeout: 2) { _ in }
    }

    static func action(forKey key: String, defaults: UserDefaults = .standard) -> MouseButtonShortcutAction {
        let fallback: MouseButtonShortcutAction = switch key {
        case backButtonActionKey: .back
        case forwardButtonActionKey: .forward
        default: .copy
        }
        return MouseButtonShortcutAction(rawValue: defaults.string(forKey: key) ?? fallback.rawValue) ?? fallback
    }

    static let pointerFeatures: [NotchFeature] = [
        .smoothScrolling, .linearPointer, .focusFollowsMouse, .separateScrollDirection,
        .horizontalScrollKey, .mouseBackForward, .mouseButtonShortcuts,
        .threeFingerMiddleClick, .doubleClickFilter, .keyDebounce
    ]
}

struct PointerSettingsSection: View {
    @AppStorage(PointerFeature.reverseMouseKey) private var reverseMouse = true
    @AppStorage(PointerFeature.horizontalModifierKey) private var horizontalModifier = PointerScrollModifier.shift.rawValue
    @AppStorage(PointerFeature.doubleClickThresholdKey) private var doubleClickThreshold = 60.0
    @AppStorage(PointerFeature.keyDebounceThresholdKey) private var keyDebounceThreshold = 40.0
    @AppStorage(PointerFeature.middleButtonActionKey) private var middleAction = MouseButtonShortcutAction.copy.rawValue
    @AppStorage(PointerFeature.backButtonActionKey) private var backAction = MouseButtonShortcutAction.back.rawValue
    @AppStorage(PointerFeature.forwardButtonActionKey) private var forwardAction = MouseButtonShortcutAction.forward.rawValue
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var inputMonitoring = CGPreflightListenEventAccess()

    private var anyEnabled: Bool { PointerFeature.pointerFeatures.contains { NotchFeatureRegistry.isEnabled($0) } }
    private var needsInputMonitoring: Bool {
        NotchFeatureRegistry.isEnabled(.doubleClickFilter) || NotchFeatureRegistry.isEnabled(.keyDebounce)
    }

    var body: some View {
        Section("Pointer") {
            NotchFeatureToggle(.smoothScrolling, "Smooth mouse scrolling", detail: "Eases mouse-wheel steps over 180 ms.")
                .help("Ease non-continuous mouse-wheel scrolling.")
            NotchFeatureToggle(.linearPointer, "Linear pointer", detail: "Disable pointer acceleration for mice.")
                .help("Turn off mouse pointer acceleration and restore its previous value when disabled.")
            NotchFeatureToggle(.focusFollowsMouse, "Focus follows mouse", detail: "Focus another app after the pointer rests for 250 ms.")
                .help("Raise the window under the pointer after a short dwell.")
            NotchFeatureToggle(.separateScrollDirection, "Separate mouse scroll direction", detail: "Reverse mouse-wheel direction without changing trackpads.")
                .help("Choose the wheel direction independently from trackpad scrolling.")
            if NotchFeatureRegistry.isEnabled(.separateScrollDirection) {
                Toggle("Reverse mouse direction", isOn: $reverseMouse)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .help("Reverse non-continuous mouse-wheel deltas.")
                    .accessibilityIdentifier("pointer-reverse-mouse")
                    .onChange(of: reverseMouse) { _, _ in PointerFeature.configure() }
            }
            NotchFeatureToggle(.horizontalScrollKey, "Horizontal scroll modifier", detail: "Hold a modifier and use the mouse wheel to scroll sideways.")
                .help("Convert vertical mouse-wheel scroll into horizontal scrolling while held.")
            if NotchFeatureRegistry.isEnabled(.horizontalScrollKey) {
                Picker("Hold", selection: $horizontalModifier) {
                    ForEach(PointerScrollModifier.allCases) { item in Text(item.title).tag(item.rawValue) }
                }
                .frame(minHeight: 28)
                .help("Choose Shift or Option as the horizontal-scroll modifier.")
                .accessibilityIdentifier("pointer-horizontal-modifier")
                .onChange(of: horizontalModifier) { _, _ in PointerFeature.configure() }
            }
            NotchFeatureToggle(.mouseBackForward, "Back and forward buttons", detail: "Map mouse buttons 3 and 4 to browser navigation.")
                .help("Send Command-[ and Command-] for mouse buttons 3 and 4.")
            NotchFeatureToggle(.mouseButtonShortcuts, "Mouse button shortcuts", detail: "Assign actions to the middle, back and forward buttons.")
                .help("Choose an action for mouse buttons 3, 4 and 5.")
            if NotchFeatureRegistry.isEnabled(.mouseButtonShortcuts) {
                buttonPicker("Middle button", key: 2, selection: $middleAction, id: "pointer-middle-action")
                buttonPicker("Button 4", key: 3, selection: $backAction, id: "pointer-button-4-action")
                buttonPicker("Button 5", key: 4, selection: $forwardAction, id: "pointer-button-5-action")
            }
            NotchFeatureToggle(.threeFingerMiddleClick, "Three-finger tap", detail: "Turn a short three-finger trackpad tap into a middle click.")
                .help("Use the optional MultitouchSupport framework to detect a three-finger tap.")
        }

        Section("Input filters") {
            NotchFeatureToggle(.doubleClickFilter, "Double-click filter", detail: "Suppress accidental second clicks within the selected interval.")
                .help("Filter a second left click unless macOS identifies it as a real double-click.")
            if NotchFeatureRegistry.isEnabled(.doubleClickFilter) {
                thresholdSlider("Second click window", value: $doubleClickThreshold, range: 20...150, step: 5, id: "pointer-double-click-threshold") {
                    PointerFeature.configure()
                }
            }
            NotchFeatureToggle(.keyDebounce, "Keyboard chatter debounce", detail: "Suppress a repeated key press shortly after its key-up.")
                .help("Filter fast repeated key-down events while preserving autorepeat.")
            if NotchFeatureRegistry.isEnabled(.keyDebounce) {
                thresholdSlider("Key debounce window", value: $keyDebounceThreshold, range: 20...150, step: 5, id: "pointer-key-debounce-threshold") {
                    PointerFeature.configure()
                }
            }

            if anyEnabled && !accessibilityTrusted {
                permissionRow("Accessibility is needed to control pointer events and raise windows.", permission: .accessibility, id: "pointer-accessibility") {
                    accessibilityTrusted = AXIsProcessTrusted()
                    inputMonitoring = CGPreflightListenEventAccess()
                    PointerFeature.configure()
                }
            }
            if needsInputMonitoring && !inputMonitoring {
                permissionRow("Input Monitoring is needed to filter clicks and key presses.", permission: .inputMonitoring, id: "pointer-input-monitoring") {
                    accessibilityTrusted = AXIsProcessTrusted()
                    inputMonitoring = CGPreflightListenEventAccess()
                    PointerFeature.configure()
                }
            }
        }
    }

    private func buttonPicker(
        _ title: String,
        key: Int,
        selection: Binding<String>,
        id: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(MouseButtonShortcutAction.allCases) { action in Text(action.title).tag(action.rawValue) }
        }
        .frame(minHeight: 28)
        .help("Choose the action for mouse button \(key).")
        .accessibilityIdentifier(id)
        .onChange(of: selection.wrappedValue) { _, _ in PointerFeature.configure() }
    }

    private func thresholdSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        id: String,
        changed: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .frame(width: 180)
                .help("Set the event filter interval in milliseconds.")
                .accessibilityIdentifier(id)
                .onChange(of: value.wrappedValue) { _, _ in changed() }
            Text("\(Int(value.wrappedValue)) ms")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .frame(minHeight: 28)
    }

    private func permissionRow(_ message: String, permission: NotchPermission, id: String, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .help("Open \(permission.title) privacy settings.")
            .accessibilityIdentifier("\(id)-open-settings")
            Button("Check Again", action: refresh)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .help("Check the current \(permission.title) permission.")
                .accessibilityIdentifier("\(id)-check-again")
        }
    }
}
