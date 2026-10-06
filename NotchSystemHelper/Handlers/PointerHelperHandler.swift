import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hidsystem

private enum PointerButtonAction: String {
    case missionControl, appExpose, launchpad, showDesktop, copy, paste, back, forward
}

private struct PointerSettings: Equatable {
    var reverseMouse = true
    var horizontalModifier = "shift"
    var doubleClickThresholdMS = 60.0
    var keyDebounceThresholdMS = 40.0
    var buttonActions: [Int: PointerButtonAction] = [:]
    var accessibilityTrusted = false
    var inputMonitoring = false
    var hostBundleIdentifier = "sidco.notch"

    init(_ values: [String: Any] = [:]) {
        reverseMouse = values["reverseMouse"] as? Bool ?? true
        horizontalModifier = (values["horizontalModifier"] as? String) == "option" ? "option" : "shift"
        doubleClickThresholdMS = Self.threshold(values["doubleClickThresholdMS"], default: 60)
        keyDebounceThresholdMS = Self.threshold(values["keyDebounceThresholdMS"], default: 40)
        accessibilityTrusted = values["accessibilityTrusted"] as? Bool ?? false
        inputMonitoring = values["inputMonitoring"] as? Bool ?? false
        hostBundleIdentifier = String((values["hostBundleIdentifier"] as? String ?? "sidco.notch").prefix(256))
        if let actions = values["buttonActions"] as? [String: String] {
            for (rawButton, rawAction) in actions.prefix(8) {
                guard let button = Int(rawButton), (0...16).contains(button),
                      let action = PointerButtonAction(rawValue: rawAction) else { continue }
                buttonActions[button] = action
            }
        }
    }

    private static func threshold(_ value: Any?, default fallback: Double) -> Double {
        let number = value as? Double ?? fallback
        return number.isFinite ? min(150, max(20, number)) : fallback
    }
}

private struct PointerConfiguration: Equatable {
    var features: [String: Bool]
    var settings: PointerSettings

    init(args: HelperArgs) {
        let incoming = args["features"] as? [String: Bool] ?? [:]
        let known = [
            "smoothScrolling", "linearPointer", "focusFollowsMouse", "separateScrollDirection",
            "horizontalScrollKey", "mouseBackForward", "mouseButtonShortcuts", "threeFingerMiddleClick",
            "doubleClickFilter", "keyDebounce"
        ]
        features = Dictionary(uniqueKeysWithValues: known.map { ($0, incoming[$0] ?? false) })
        settings = PointerSettings(args["settings"] as? [String: Any] ?? [:])
    }

    subscript(_ feature: String) -> Bool { features[feature] == true }

    var hasTapFeature: Bool {
        ["smoothScrolling", "focusFollowsMouse", "separateScrollDirection", "horizontalScrollKey",
         "mouseBackForward", "mouseButtonShortcuts", "doubleClickFilter", "keyDebounce"].contains { self[$0] }
    }

    var hasAnyFeature: Bool { features.values.contains(true) }

    func permitted() -> PointerConfiguration {
        var result = self
        let hasAccessibility = settings.accessibilityTrusted && AXIsProcessTrusted()
        let hasInputMonitoring = settings.inputMonitoring && CGPreflightListenEventAccess()
        for name in ["smoothScrolling", "focusFollowsMouse", "separateScrollDirection", "horizontalScrollKey",
                     "mouseBackForward", "mouseButtonShortcuts", "threeFingerMiddleClick"] where !hasAccessibility {
            result.features[name] = false
        }
        if !hasAccessibility || !hasInputMonitoring {
            result.features["doubleClickFilter"] = false
            result.features["keyDebounce"] = false
        }
        return result
    }
}

private struct HelperPointerModifiers: OptionSet {
    let rawValue: Int
    static let shift = HelperPointerModifiers(rawValue: 1 << 0)
    static let option = HelperPointerModifiers(rawValue: 1 << 1)
}

private struct HelperScrollDelta {
    var vertical: Double
    var horizontal: Double
}

private enum HelperScrollTransform {
    static func apply(vertical: Double, horizontal: Double, modifiers: HelperPointerModifiers,
                      reverseMouse: Bool, horizontalModifier: String?) -> HelperScrollDelta {
        var v = reverseMouse ? -vertical : vertical
        var h = reverseMouse ? -horizontal : horizontal
        let matches = horizontalModifier == "shift" ? modifiers.contains(.shift)
            : horizontalModifier == "option" && modifiers.contains(.option)
        if matches { h += v; v = 0 }
        return HelperScrollDelta(vertical: v, horizontal: h)
    }
}

private enum HelperScrollEasing {
    static func samples(delta: Double) -> [Double] {
        guard delta.isFinite else { return [] }
        let count = 22
        var result: [Double] = []
        result.reserveCapacity(count)
        var previous = 0.0
        for index in 1...count {
            let progress = Double(index) / Double(count)
            let cumulative = index == count ? delta : delta * (1 - pow(1 - progress, 3))
            result.append(cumulative - previous)
            previous = cumulative
        }
        return result
    }
}

private struct HelperClickFilter {
    private var lastAccepted: (button: Int, time: TimeInterval)?

    mutating func shouldSwallow(button: Int, at time: TimeInterval, clickState: Int, thresholdMS: Double) -> Bool {
        if clickState >= 2 { lastAccepted = (button, time); return false }
        if let lastAccepted, lastAccepted.button == button {
            let elapsed = time - lastAccepted.time
            if elapsed >= 0, elapsed < thresholdMS / 1_000 { return true }
        }
        lastAccepted = (button, time)
        return false
    }
}

private struct HelperKeyDebounce {
    enum Event { case keyDown(Int, Bool), keyUp(Int) }
    private var keyUpTimes: [Int: TimeInterval] = [:]
    private var swallowedDowns: Set<Int> = []

    mutating func process(_ event: Event, at time: TimeInterval, thresholdMS: Double) -> Bool {
        switch event {
        case let .keyDown(key, autorepeat):
            guard (0...255).contains(key), !autorepeat else { return false }
            if let previous = keyUpTimes[key] {
                let elapsed = time - previous
                if elapsed >= 0, elapsed < thresholdMS / 1_000 {
                    swallowedDowns.insert(key)
                    return true
                }
                keyUpTimes.removeValue(forKey: key)
            }
            return false
        case let .keyUp(key):
            guard (0...255).contains(key) else { return false }
            if swallowedDowns.remove(key) != nil { return true }
            keyUpTimes[key] = time
            keyUpTimes = keyUpTimes.filter { time - $0.value <= 2 }
            if keyUpTimes.count > 256, let oldest = keyUpTimes.min(by: { $0.value < $1.value })?.key {
                keyUpTimes.removeValue(forKey: oldest)
            }
            return false
        }
    }
}

private struct HelperTouchPoint {
    var x: Double
    var y: Double
}

private struct HelperThreeFingerTapDetector {
    private var beganAt: TimeInterval?
    private var origins: [HelperTouchPoint] = []
    private var movedTooFar = false

    mutating func update(points: [HelperTouchPoint], at time: TimeInterval) -> Bool {
        if points.isEmpty {
            guard let beganAt else { reset(); return false }
            let isTap = !movedTooFar && time >= beganAt && time - beganAt < 0.2
            reset()
            return isTap
        }
        guard points.count == 3 else { reset(); return false }
        guard let beganAt else { self.beganAt = time; origins = points; movedTooFar = false; return false }
        guard time >= beganAt, time - beganAt < 0.2 else { movedTooFar = true; return false }
        for (origin, current) in zip(origins, points) {
            if hypot(current.x - origin.x, current.y - origin.y) > 0.03 { movedTooFar = true }
        }
        return false
    }

    private mutating func reset() { beganAt = nil; origins.removeAll(keepingCapacity: true); movedTooFar = false }
}

private struct ScrollFrame {
    var vertical: Double
    var horizontal: Double
    var location: CGPoint
    var flags: CGEventFlags
}

private final class PointerScrollAnimator {
    static let shared = PointerScrollAnimator()
    private let lock = NSLock()
    private var frames: [ScrollFrame] = []
    private var index = 0
    private var timer: DispatchSourceTimer?

    private init() {}

    func enqueue(vertical: Double, horizontal: Double, location: CGPoint, flags: CGEventFlags) {
        let verticalSamples = HelperScrollEasing.samples(delta: vertical)
        let horizontalSamples = HelperScrollEasing.samples(delta: horizontal)
        let count = max(verticalSamples.count, horizontalSamples.count)
        guard count > 0 else { return }
        lock.lock()
        if frames.count - index + count > 512 {
            frames.removeAll(keepingCapacity: true)
            index = 0
        }
        for offset in 0..<count {
            frames.append(ScrollFrame(
                vertical: offset < verticalSamples.count ? verticalSamples[offset] : 0,
                horizontal: offset < horizontalSamples.count ? horizontalSamples[offset] : 0,
                location: location,
                flags: flags
            ))
        }
        if timer == nil {
            let newTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            newTimer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
            newTimer.setEventHandler { [weak self] in self?.postNextFrame() }
            timer = newTimer
            newTimer.resume()
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        frames.removeAll(keepingCapacity: true)
        index = 0
        let oldTimer = timer
        timer = nil
        lock.unlock()
        oldTimer?.setEventHandler {}
        oldTimer?.cancel()
    }

    private func postNextFrame() {
        lock.lock()
        guard index < frames.count else {
            frames.removeAll(keepingCapacity: true)
            index = 0
            let oldTimer = timer
            timer = nil
            lock.unlock()
            oldTimer?.setEventHandler {}
            oldTimer?.cancel()
            return
        }
        let frame = frames[index]
        index += 1
        lock.unlock()

        let vertical = Int32(min(Double(Int32.max), max(Double(Int32.min), frame.vertical.rounded())))
        let horizontal = Int32(min(Double(Int32.max), max(Double(Int32.min), frame.horizontal.rounded())))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.location = frame.location
        event.flags = frame.flags
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(vertical))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(horizontal))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64((frame.vertical * 65_536).rounded()))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64((frame.horizontal * 65_536).rounded()))
        event.setIntegerValueField(.eventSourceUserData, value: PointerEventContext.syntheticEventMarker)
        event.post(tap: .cgSessionEventTap)
    }
}

private final class PointerEventContext {
    static let syntheticEventMarker: Int64 = 0x4E4F544348

    private let lock = NSRecursiveLock()
    private var configuration: PointerConfiguration
    private weak var eventTap: CFMachPort?
    private var clickFilter = HelperClickFilter()
    private var keyDebounce = HelperKeyDebounce()
    private var pressedButtons: Set<Int> = []
    private var swallowedMouseUps: Set<Int> = []
    private var focusWork: DispatchWorkItem?
    private var focusGeneration: UInt64 = 0

    init(configuration: PointerConfiguration) { self.configuration = configuration }

    func setTap(_ tap: CFMachPort) { eventTap = tap }

    func update(_ configuration: PointerConfiguration) {
        lock.lock()
        self.configuration = configuration
        clickFilter = HelperClickFilter()
        keyDebounce = HelperKeyDebounce()
        swallowedMouseUps.removeAll(keepingCapacity: true)
        cancelFocusLocked()
        pressedButtons.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        cancelFocusLocked()
        configuration = PointerConfiguration(args: [:])
        pressedButtons.removeAll(keepingCapacity: true)
        swallowedMouseUps.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func stopFocus() {
        lock.lock()
        cancelFocusLocked()
        lock.unlock()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        var scrollToAnimate: HelperScrollDelta?
        var shortcut: PointerButtonAction?
        var focusPoint: CGPoint?
        var swallow = false
        lock.lock()
        let config = configuration
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000

        switch type {
        case .scrollWheel:
            guard !eventIsContinuous(event) else { lock.unlock(); return Unmanaged.passUnretained(event) }
            let rawVertical = mouseScrollDelta(event, axis: 1)
            let rawHorizontal = mouseScrollDelta(event, axis: 2)
            let modifiers = pointerModifiers(event.flags)
            let delta = HelperScrollTransform.apply(
                vertical: rawVertical,
                horizontal: rawHorizontal,
                modifiers: modifiers,
                reverseMouse: config["separateScrollDirection"] && config.settings.reverseMouse,
                horizontalModifier: config["horizontalScrollKey"] ? config.settings.horizontalModifier : nil
            )
            if config["smoothScrolling"] {
                scrollToAnimate = delta
                swallow = true
            } else if delta.vertical != rawVertical || delta.horizontal != rawHorizontal {
                setMouseScrollDelta(delta.vertical, on: event, axis: 1)
                setMouseScrollDelta(delta.horizontal, on: event, axis: 2)
            }

        case .leftMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            pressedButtons.insert(button)
            cancelFocusLocked()
            if config["doubleClickFilter"], button == 0,
               clickFilter.shouldSwallow(button: button, at: timestamp,
                                         clickState: Int(event.getIntegerValueField(.mouseEventClickState)),
                                         thresholdMS: config.settings.doubleClickThresholdMS) {
                swallowedMouseUps.insert(button)
                swallow = true
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            pressedButtons.remove(button)
            if swallowedMouseUps.remove(button) != nil { swallow = true }

        case .rightMouseDown, .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            pressedButtons.insert(button)
            cancelFocusLocked()
            if type == .otherMouseDown {
                if config["mouseButtonShortcuts"], let mapped = config.settings.buttonActions[button] {
                    shortcut = mapped
                    swallowedMouseUps.insert(button)
                    swallow = true
                } else if config["mouseBackForward"], button == 3 || button == 4 {
                    shortcut = button == 3 ? .back : .forward
                    swallowedMouseUps.insert(button)
                    swallow = true
                }
            }

        case .mouseMoved:
            if config["focusFollowsMouse"], pressedButtons.isEmpty {
                focusPoint = event.location
            }

        case .keyDown:
            if config["keyDebounce"] {
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                swallow = keyDebounce.process(.keyDown(keyCode, isRepeat), at: timestamp,
                                              thresholdMS: config.settings.keyDebounceThresholdMS)
            }

        case .keyUp:
            if config["keyDebounce"] {
                let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                swallow = keyDebounce.process(.keyUp(keyCode), at: timestamp,
                                              thresholdMS: config.settings.keyDebounceThresholdMS)
            }

        default: break
        }
        lock.unlock()

        if let focusPoint { scheduleFocus(at: focusPoint) }
        if let scrollToAnimate {
            PointerScrollAnimator.shared.enqueue(vertical: scrollToAnimate.vertical, horizontal: scrollToAnimate.horizontal,
                                                location: event.location, flags: event.flags)
        }
        if let shortcut { perform(shortcut) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func scheduleFocus(at point: CGPoint) {
        lock.lock()
        cancelFocusLocked()
        focusGeneration &+= 1
        let generation = focusGeneration
        let work = DispatchWorkItem { [weak self] in self?.focusIfStill(at: point, generation: generation) }
        focusWork = work
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelFocusLocked() {
        focusGeneration &+= 1
        focusWork?.cancel()
        focusWork = nil
    }

    private func focusIfStill(at point: CGPoint, generation: UInt64) {
        lock.lock()
        let allowed = configuration["focusFollowsMouse"] && pressedButtons.isEmpty && focusGeneration == generation
        let hostBundleID = configuration.settings.hostBundleIdentifier
        lock.unlock()
        guard allowed, point.y > 30 else { return }

        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success,
              let element else { return }
        var targetPID: pid_t = 0
        guard AXUIElementGetPid(element, &targetPID) == .success,
              let app = NSRunningApplication(processIdentifier: targetPID),
              let bundleID = app.bundleIdentifier,
              bundleID != hostBundleID,
              bundleID != "com.apple.dock",
              !app.isActive else { return }

        var windowValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue)
        let window: AXUIElement = (windowValue.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }) ?? element
        lock.lock()
        let stillAllowed = configuration["focusFollowsMouse"] && pressedButtons.isEmpty && focusGeneration == generation
        lock.unlock()
        guard stillAllowed else { return }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    private func perform(_ action: PointerButtonAction) {
        switch action {
        case .missionControl: postKey(0xA0, flags: [])
        case .appExpose: postKey(125, flags: .maskControl)
        case .launchpad: postKey(0xA1, flags: [])
        case .showDesktop: postKey(103, flags: [])
        case .copy: postKey(8, flags: .maskCommand)
        case .paste: postKey(9, flags: .maskCommand)
        case .back: postKey(33, flags: .maskCommand)
        case .forward: postKey(30, flags: .maskCommand)
        }
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

private let pointerEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<PointerEventContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.handle(type: type, event: event)
}

private func pointerModifiers(_ flags: CGEventFlags) -> HelperPointerModifiers {
    var result: HelperPointerModifiers = []
    if flags.contains(.maskShift) { result.insert(.shift) }
    if flags.contains(.maskAlternate) { result.insert(.option) }
    return result
}

private func eventIsContinuous(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
}

private func mouseScrollDelta(_ event: CGEvent, axis: Int) -> Double {
    let pointField: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
    let fixedField: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
    let lineField: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
    let pixels = event.getIntegerValueField(pointField)
    if pixels != 0 { return Double(pixels) }
    let fixed = event.getDoubleValueField(fixedField)
    if fixed.isFinite, fixed != 0 { return fixed }
    return Double(event.getIntegerValueField(lineField)) * 10
}

private func setMouseScrollDelta(_ delta: Double, on event: CGEvent, axis: Int) {
    let safe = delta.isFinite ? delta : 0
    let pointField: CGEventField = axis == 1 ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventPointDeltaAxis2
    let fixedField: CGEventField = axis == 1 ? .scrollWheelEventFixedPtDeltaAxis1 : .scrollWheelEventFixedPtDeltaAxis2
    let lineField: CGEventField = axis == 1 ? .scrollWheelEventDeltaAxis1 : .scrollWheelEventDeltaAxis2
    event.setIntegerValueField(pointField, value: Int64(safe.rounded()))
    event.setDoubleValueField(fixedField, value: safe)
    event.setIntegerValueField(lineField, value: Int64((safe / 10).rounded()))
}

private final class PointerHelperRuntime {
    static let shared = PointerHelperRuntime()

    private let lock = NSRecursiveLock()
    private var requested = PointerConfiguration(args: [:])
    private var active = PointerConfiguration(args: [:])
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventContext: PointerEventContext?
    private var hidClient: IOHIDEventSystemClient?
    private var savedPointerAcceleration: CFTypeRef?
    private var linearPointerApplied = false
    private var multitouchAvailable = false

    private init() { atexit { PointerHelperRuntime.shared.shutdown() } }

    func configure(_ value: PointerConfiguration) -> HelperArgs {
        lock.lock()
        defer { lock.unlock() }
        let permitted = value.permitted()
        guard requested != value || active != permitted else { return statusLocked() }
        let old = active
        requested = value

        if old["linearPointer"] != permitted["linearPointer"] {
            if permitted["linearPointer"] { linearPointerApplied = setLinearPointer() }
            else { restoreLinearPointer() }
        }

        if old["threeFingerMiddleClick"] != permitted["threeFingerMiddleClick"] {
            multitouchAvailable = PointerMultitouchRuntime.shared.setEnabled(permitted["threeFingerMiddleClick"])
        }

        eventContext?.update(permitted)
        if permitted.hasTapFeature {
            if eventTap == nil { _ = installTap(configuration: permitted) }
        } else {
            removeTap()
            PointerScrollAnimator.shared.stop()
        }
        if !permitted["focusFollowsMouse"] { eventContext?.stopFocus() }
        active = permitted
        return statusLocked()
    }

    func status() -> HelperArgs {
        lock.lock()
        defer { lock.unlock() }
        return statusLocked()
    }

    func shutdown() {
        lock.lock()
        removeTap()
        PointerScrollAnimator.shared.stop()
        restoreLinearPointer()
        _ = PointerMultitouchRuntime.shared.setEnabled(false)
        active = PointerConfiguration(args: [:])
        requested = active
        lock.unlock()
    }

    private func statusLocked() -> HelperArgs {
        [
            "ok": true,
            "enabled": requested.hasAnyFeature,
            "tapEnabled": eventTap != nil,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "inputMonitoring": CGPreflightListenEventAccess(),
            "linearPointerApplied": linearPointerApplied,
            "multitouchAvailable": multitouchAvailable
        ]
    }

    private func installTap(configuration: PointerConfiguration) -> Bool {
        let mask = [CGEventType.scrollWheel, .mouseMoved, .leftMouseDown, .leftMouseUp,
                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                    .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = eventContext ?? PointerEventContext(configuration: configuration)
        eventContext = context
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: pointerEventCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            eventContext = nil
            return false
        }
        context.setTap(tap)
        eventTap = tap
        runLoopSource = source
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        eventContext?.stop()
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        eventContext = nil
    }

    private func setLinearPointer() -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let key = "HIDPointerAcceleration" as CFString
        guard let original = IOHIDEventSystemClientCopyProperty(client, key) else {
            return false
        }
        guard IOHIDEventSystemClientSetProperty(client, key, NSNumber(value: -1)) else {
            return false
        }
        hidClient = client
        savedPointerAcceleration = original
        return true
    }

    private func restoreLinearPointer() {
        guard let client = hidClient else { return }
        if let savedPointerAcceleration {
            _ = IOHIDEventSystemClientSetProperty(client, "HIDPointerAcceleration" as CFString, savedPointerAcceleration)
        }
        hidClient = nil
        savedPointerAcceleration = nil
        linearPointerApplied = false
    }
}

private final class PointerMultitouchRuntime {
    static let shared = PointerMultitouchRuntime()

    private struct Point { var x: Float; var y: Float }
    private struct Touch {
        var frame: Int32
        var timestamp: Double
        var identifier: Int32
        var state: Int32
        var fingerID: Int32
        var handID: Int32
        var normalized: Point
        var size: Float
        var angle: Float
        var majorAxis: Float
        var minorAxis: Float
        var absolute: Point
        var type: Int32
        var generation: Int32
        var unknown1: Int32
        var unknown2: Int32
    }

    fileprivate typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterCallback = @convention(c) (UnsafeMutableRawPointer?, ContactCallback?) -> Void

    private let lock = NSLock()
    private var framework: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var register: RegisterCallback?
    private var unregister: RegisterCallback?
    private var enabled = false
    private var detector = HelperThreeFingerTapDetector()

    private init() {}

    func setEnabled(_ enabled: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if self.enabled == enabled { return enabled ? !devices.isEmpty : false }
        if !enabled {
            for device in devices {
                if let unregister { unregister(device, nil) }
                else { register?(device, nil) }
            }
            devices.removeAll(keepingCapacity: false)
            detector = HelperThreeFingerTapDetector()
            self.enabled = false
            return false
        }

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
              let createSymbol = dlsym(handle, "MTDeviceCreateList"),
              let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback") else {
            self.enabled = false
            return false
        }
        framework = handle
        let createList = unsafeBitCast(createSymbol, to: CreateList.self)
        register = unsafeBitCast(registerSymbol, to: RegisterCallback.self)
        if let unregisterSymbol = dlsym(handle, "MTUnregisterContactFrameCallback") {
            unregister = unsafeBitCast(unregisterSymbol, to: RegisterCallback.self)
        }
        guard let list = createList()?.takeRetainedValue() else { return false }
        for index in 0..<CFArrayGetCount(list) {
            guard let rawDevice = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            register?(device, pointerMultitouchCallback)
            devices.append(device)
        }
        self.enabled = !devices.isEmpty
        detector = HelperThreeFingerTapDetector()
        return self.enabled
    }

    fileprivate func receive(_ rawTouches: UnsafeRawPointer?, count: Int32, timestamp: Double) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        var points: [HelperTouchPoint] = []
        if let rawTouches, count > 0 {
            let touches = rawTouches.assumingMemoryBound(to: Touch.self)
            for index in 0..<min(Int(count), 20) {
                let touch = touches[index]
                guard touch.state == 3 || touch.state == 4 else { continue }
                let x = Double(touch.normalized.x)
                let y = Double(touch.normalized.y)
                if x.isFinite, y.isFinite { points.append(HelperTouchPoint(x: x, y: y)) }
            }
        }
        let fired = detector.update(points: points, at: timestamp)
        lock.unlock()
        if fired { postMiddleClick() }
    }

    private func postMiddleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: location, mouseButton: .center),
              let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: location, mouseButton: .center) else { return }
        down.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        up.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        down.setIntegerValueField(.eventSourceUserData, value: PointerEventContext.syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: PointerEventContext.syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

private let pointerMultitouchCallback: PointerMultitouchRuntime.ContactCallback = { _, touches, count, timestamp, _ in
    PointerMultitouchRuntime.shared.receive(touches, count: count, timestamp: timestamp)
}

enum PointerHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "configure": reply(PointerHelperRuntime.shared.configure(PointerConfiguration(args: args)))
        case "status": reply(PointerHelperRuntime.shared.status())
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
