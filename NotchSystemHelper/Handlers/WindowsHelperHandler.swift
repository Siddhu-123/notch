import ApplicationServices
import AppKit
import Carbon
import Foundation

enum WindowsHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "status": reply(WindowsHelperRuntime.shared.status())
        case "setFeature": reply(WindowsHelperRuntime.shared.setFeature(args: args))
        case "disable": reply(WindowsHelperRuntime.shared.disable())
        case "listWindows": reply(WindowsHelperRuntime.shared.listWindows())
        case "focusWindow": reply(WindowsHelperRuntime.shared.focusWindow(args: args))
        case "snap": reply(WindowsHelperRuntime.shared.snap(args: args))
        case "beginSwitcher": reply(WindowsHelperRuntime.shared.beginSwitcher())
        case "endSwitcher": reply(WindowsHelperRuntime.shared.endSwitcher())
        case "drainEvents": reply(WindowsHelperRuntime.shared.drainEvents())
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}

private struct HelperWindowFrame {
    let position: CGPoint
    let size: CGSize

    var rect: CGRect { CGRect(origin: position, size: size) }

    func appKitRect(desktopTop: CGFloat) -> CGRect {
        CGRect(x: position.x, y: desktopTop - position.y - size.height, width: size.width, height: size.height)
    }
}

private struct SavedWindowFrame {
    let frame: HelperWindowFrame
    let desktopTop: CGFloat
}

private struct HelperWindowTarget {
    let pid: pid_t
    let index: Int
    let number: Int
    let element: AXUIElement
}

private final class WindowsTapContext {
    weak var runtime: WindowsHelperRuntime?
    init(runtime: WindowsHelperRuntime) { self.runtime = runtime }
}

private final class WindowsObserverContext {
    weak var runtime: WindowsHelperRuntime?
    let pid: pid_t
    init(runtime: WindowsHelperRuntime, pid: pid_t) { self.runtime = runtime; self.pid = pid }
}

private struct WindowsObserverEntry {
    let observer: AXObserver
    let context: WindowsObserverContext
}

private struct HelperQuitGuard {
    private(set) var firstPressAt: TimeInterval?
    private(set) var heldSince: TimeInterval?
    private var passedCurrentPress = false
    private var awaitingPhysicalKeyUp = false
    static let doublePressWindow: TimeInterval = 1
    static let holdThreshold: TimeInterval = 0.6
    var isTrackingPress: Bool { heldSince != nil || awaitingPhysicalKeyUp }

    enum Result { case promptAndSwallow, passThrough, swallow, synthesizeQuit, none }

    mutating func keyDown(at time: TimeInterval, isRepeat: Bool) -> Result {
        if isRepeat {
            guard heldSince != nil else { return awaitingPhysicalKeyUp ? .swallow : .none }
            return passedCurrentPress ? .passThrough : .swallow
        }
        guard heldSince == nil, !awaitingPhysicalKeyUp else {
            return awaitingPhysicalKeyUp || !passedCurrentPress ? .swallow : .passThrough
        }
        if let firstPressAt, time >= firstPressAt, time - firstPressAt < Self.doublePressWindow {
            self.heldSince = time
            passedCurrentPress = true
            self.firstPressAt = nil
            return .passThrough
        }
        firstPressAt = time
        heldSince = time
        passedCurrentPress = false
        return .promptAndSwallow
    }

    mutating func keyUp(at time: TimeInterval) -> Result {
        if awaitingPhysicalKeyUp {
            awaitingPhysicalKeyUp = false
            return .swallow
        }
        guard let heldSince else { return .none }
        self.heldSince = nil
        if passedCurrentPress {
            passedCurrentPress = false
            return .passThrough
        }
        if time - heldSince + 0.000_000_001 >= Self.holdThreshold {
            firstPressAt = nil
            return .synthesizeQuit
        }
        return .swallow
    }

    mutating func holdThresholdReached(at time: TimeInterval) -> Result {
        guard let heldSince, !passedCurrentPress,
              time - heldSince + 0.000_000_001 >= Self.holdThreshold else { return .none }
        self.heldSince = nil
        firstPressAt = nil
        passedCurrentPress = false
        awaitingPhysicalKeyUp = true
        return .synthesizeQuit
    }
}

private final class WindowsHelperRuntime {
    static let shared = WindowsHelperRuntime()
    private static let protectedFeatures: Set<String> = [
        "windowSwitcher", "windowSnapping", "greenButtonMaximize", "quitOnLastWindow", "quitProtection"
    ]
    private static let ownBundleID = "sidco.notch"
    private static let eventMarker: Int64 = 0x4E574A35
    private static let maximumQueuedEvents = 32
    private static let maximumSavedFrames = 20

    private struct DragState {
        let target: HelperWindowTarget
        let startingFrame: CGRect
        var moved = false
        var pendingPosition: String?
    }

    private let lock = NSRecursiveLock()
    private var enabledFeatures = Set<String>()
    private var excludedBundleIDs: Set<String> = ["com.apple.finder", WindowsHelperRuntime.ownBundleID]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapContext: WindowsTapContext?
    private var tapMask: CGEventMask = 0
    private var tapCanSwallow = false
    private var switcherOpen = false
    private var optionWasDown = false
    private var queuedEvents: [[String: Any]] = []
    private var quitGuard = HelperQuitGuard()
    private var quitHoldWork: DispatchWorkItem?
    private var quitHoldGeneration = 0
    private var dragState: DragState?
    private var savedFrames: [String: SavedWindowFrame] = [:]
    private var savedFrameOrder: [String] = []
    private var observers: [pid_t: WindowsObserverEntry] = [:]
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    private init() {
        atexit { WindowsHelperRuntime.shared.shutdown() }
    }

    func status() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        return [
            "ok": true,
            "accessibilityTrusted": AXIsProcessTrusted(),
            "enabledFeatures": Array(enabledFeatures).sorted()
        ]
    }

    func setFeature(args: HelperArgs) -> HelperArgs {
        guard let feature = args["feature"] as? String, Self.protectedFeatures.contains(feature),
              let enabled = args["enabled"] as? Bool else {
            return ["ok": false, "error": "A supported feature and enabled flag are required."]
        }
        lock.lock(); defer { lock.unlock() }
        if enabled, !AXIsProcessTrusted() {
            removeFeatureLocked(feature)
            updateRuntimeLocked()
            return ["ok": false, "accessibilityTrusted": false, "error": "Accessibility permission is required."]
        }
        if enabled {
            enabledFeatures.insert(feature)
            if let values = args["excludedBundleIDs"] as? [String] {
                excludedBundleIDs = Set(values.prefix(52).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                    .union(["com.apple.finder", Self.ownBundleID])
            }
        } else {
            removeFeatureLocked(feature)
        }
        updateRuntimeLocked()
        return ["ok": true, "enabled": enabledFeatures.contains(feature), "accessibilityTrusted": true]
    }

    private func removeFeatureLocked(_ feature: String) {
        enabledFeatures.remove(feature)
        switch feature {
        case "windowSwitcher":
            switcherOpen = false
            optionWasDown = false
            queuedEvents.removeAll { $0["kind"] as? String == "switcherOptionReleased" }
        case "windowSnapping":
            dragState = nil
        case "greenButtonMaximize":
            savedFrames.removeAll(keepingCapacity: true)
            savedFrameOrder.removeAll(keepingCapacity: true)
        case "quitProtection":
            quitGuard = HelperQuitGuard()
            cancelQuitHoldLocked()
            queuedEvents.removeAll { $0["kind"] as? String == "quitPrompt" }
        default:
            break
        }
    }

    func disable() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        enabledFeatures.removeAll()
        switcherOpen = false
        optionWasDown = false
        queuedEvents.removeAll(keepingCapacity: true)
        quitGuard = HelperQuitGuard()
        cancelQuitHoldLocked()
        savedFrames.removeAll(keepingCapacity: true)
        savedFrameOrder.removeAll(keepingCapacity: true)
        removeObserversLocked()
        configureTapLocked()
        return ["ok": true, "enabled": false]
    }

    func listWindows() -> HelperArgs {
        guard AXIsProcessTrusted() else {
            return ["ok": false, "accessibilityTrusted": false, "windows": [], "error": "Accessibility permission is required."]
        }
        lock.lock()
        let enabled = enabledFeatures.contains("windowSwitcher")
        lock.unlock()
        guard enabled else { return ["ok": false, "windows": [], "error": "Window switcher is disabled."] }
        var rows: [[String: Any]] = []
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular && !application.isTerminated && application.processIdentifier > 0 {
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            guard let windows = Self.windows(of: appElement) else { continue }
            let appName = application.localizedName ?? application.bundleIdentifier ?? "Application"
            for (index, window) in windows.enumerated() {
                guard rows.count < 500 else { break }
                let title = Self.stringAttribute("AXTitle", from: window) ?? ""
                let number = Self.numberAttribute("AXWindowNumber", from: window) ?? index
                rows.append([
                    "pid": Int(application.processIdentifier),
                    "index": index,
                    "windowNumber": number,
                    "app": String(appName.prefix(128)),
                    "title": String(title.prefix(512))
                ])
            }
        }
        rows.sort {
            let appOrder = ($0["app"] as? String ?? "").localizedCaseInsensitiveCompare($1["app"] as? String ?? "")
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            return ($0["title"] as? String ?? "").localizedCaseInsensitiveCompare($1["title"] as? String ?? "") == .orderedAscending
        }
        return ["ok": true, "windows": rows]
    }

    func focusWindow(args: HelperArgs) -> HelperArgs {
        guard AXIsProcessTrusted() else { return permissionError() }
        lock.lock()
        let enabled = enabledFeatures.contains("windowSwitcher")
        lock.unlock()
        guard enabled else { return ["ok": false, "error": "Window switcher is disabled."] }
        guard let pidValue = args["pid"] as? NSNumber, let indexValue = args["index"] as? NSNumber,
              pidValue.intValue > 0, indexValue.intValue >= 0 else {
            return ["ok": false, "error": "A valid pid and window index are required."]
        }
        let app = AXUIElementCreateApplication(pid_t(pidValue.intValue))
        guard let windows = Self.windows(of: app), windows.indices.contains(indexValue.intValue) else {
            return ["ok": false, "error": "The window is no longer available."]
        }
        let window = windows[indexValue.intValue]
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid_t(pidValue.intValue))?.activate(options: [.activateIgnoringOtherApps])
        return ["ok": result == .success, "error": result == .success ? "" : "The window could not be focused."]
    }

    func snap(args: HelperArgs) -> HelperArgs {
        guard AXIsProcessTrusted() else { return permissionError() }
        guard enabledFeatures.contains("windowSnapping"),
              let position = args["position"] as? String,
              ["left", "right", "top", "bottom", "maximize", "center"].contains(position) else {
            return ["ok": false, "error": "Window snapping is disabled or the position is invalid."]
        }
        guard let target = frontmostWindow(), snap(target, position: position) else {
            return ["ok": false, "error": "The frontmost window could not be moved."]
        }
        return ["ok": true]
    }

    func beginSwitcher() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        guard enabledFeatures.contains("windowSwitcher") else { return ["ok": false, "error": "Window switcher is disabled."] }
        queuedEvents.removeAll { $0["kind"] as? String == "switcherOptionReleased" }
        switcherOpen = true
        optionWasDown = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        if !optionWasDown { enqueueLocked(["kind": "switcherOptionReleased"]) }
        return ["ok": true]
    }

    func endSwitcher() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        switcherOpen = false
        optionWasDown = false
        queuedEvents.removeAll { $0["kind"] as? String == "switcherOptionReleased" }
        return ["ok": true]
    }

    func drainEvents() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        let result = queuedEvents
        queuedEvents.removeAll(keepingCapacity: true)
        return ["ok": true, "events": result]
    }

    func observerEvent(pid: pid_t, notification: String) {
        if notification == (kAXWindowCreatedNotification as String) {
            lock.lock()
            if enabledFeatures.contains("quitOnLastWindow") {
                observeApplicationLocked(pid: pid, replace: false)
                if let entry = observers[pid] {
                    let app = AXUIElementCreateApplication(pid)
                    let opaque = Unmanaged.passUnretained(entry.context).toOpaque()
                    for window in Self.windows(of: app) ?? [] {
                        _ = AXObserverAddNotification(entry.observer, window, kAXUIElementDestroyedNotification as CFString, opaque)
                    }
                }
            }
            lock.unlock()
            return
        }
        guard notification == (kAXUIElementDestroyedNotification as String) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.quitIfWindowless(pid: pid)
        }
    }

    private func quitIfWindowless(pid: pid_t) {
        lock.lock()
        let active = enabledFeatures.contains("quitOnLastWindow")
        let excluded = excludedBundleIDs
        lock.unlock()
        guard active,
              let application = NSRunningApplication(processIdentifier: pid),
              let bundleID = application.bundleIdentifier?.lowercased(),
              let windows = Self.windows(of: AXUIElementCreateApplication(pid)),
              windows.isEmpty else { return }
        guard Self.shouldQuit(bundleID: bundleID, windowCount: 0, excluded: excluded) else { return }
        application.terminate()
    }

    private func updateRuntimeLocked() {
        if enabledFeatures.contains("quitOnLastWindow") {
            if launchObserver == nil { startWorkspaceObserversLocked() }
            observeRunningApplicationsLocked()
        } else {
            removeObserversLocked()
        }
        configureTapLocked()
    }

    private func configureTapLocked() {
        var types: [CGEventType] = []
        if enabledFeatures.contains("windowSnapping") { types += [.leftMouseDown, .leftMouseDragged, .leftMouseUp] }
        if enabledFeatures.contains("greenButtonMaximize") { types.append(.leftMouseDown) }
        if enabledFeatures.contains("quitProtection") { types += [.keyDown, .keyUp] }
        if enabledFeatures.contains("windowSwitcher") { types.append(.flagsChanged) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let canSwallow = enabledFeatures.contains("greenButtonMaximize") || enabledFeatures.contains("quitProtection")
        guard mask != tapMask || canSwallow != tapCanSwallow else { return }
        removeTapLocked()
        tapMask = mask
        tapCanSwallow = canSwallow
        guard mask != 0 else { return }
        let context = WindowsTapContext(runtime: self)
        let options: CGEventTapOptions = canSwallow ? .defaultTap : .listenOnly
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: windowsEventTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            tapMask = 0
            tapCanSwallow = false
            return
        }
        tapContext = context
        eventTap = tap
        runLoopSource = source
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTapLocked() {
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        tapContext = nil
        tapMask = 0
        tapCanSwallow = false
        dragState = nil
    }

    fileprivate func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.eventMarker {
            return Unmanaged.passUnretained(event)
        }
        lock.lock()
        let features = enabledFeatures
        lock.unlock()

        if type == .flagsChanged, features.contains("windowSwitcher") {
            handleSwitcherFlags(event)
        }
        if features.contains("quitProtection"), (type == .keyDown || type == .keyUp),
           let swallowed = handleQuitProtection(type: type, event: event) {
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown {
            if features.contains("greenButtonMaximize"),
               !event.flags.contains(.maskAlternate), isGreenButtonClick(at: event), handleGreenButton(at: event) {
                return nil
            }
            if features.contains("windowSnapping") { beginDrag(at: event) }
        } else if type == .leftMouseDragged, features.contains("windowSnapping") {
            updateDrag(at: event)
        } else if type == .leftMouseUp, features.contains("windowSnapping") {
            finishDrag(at: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleSwitcherFlags(_ event: CGEvent) {
        lock.lock(); defer { lock.unlock() }
        let optionDown = event.flags.contains(.maskAlternate)
        if switcherOpen && optionWasDown && !optionDown { enqueueLocked(["kind": "switcherOptionReleased"]) }
        optionWasDown = optionDown
    }

    private func handleQuitProtection(type: CGEventType, event: CGEvent) -> Bool? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_ANSI_Q) else { return nil }
        let time = TimeInterval(event.timestamp) / 1_000_000_000
        lock.lock()
        let isRepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard event.flags.contains(.maskCommand) || quitGuard.isTrackingPress else {
            lock.unlock()
            return nil
        }
        let result: HelperQuitGuard.Result
        if type == .keyDown {
            result = quitGuard.keyDown(at: time, isRepeat: isRepeat)
            if case .promptAndSwallow = result { scheduleQuitHoldLocked(startedAt: time) }
        } else {
            result = quitGuard.keyUp(at: time)
            cancelQuitHoldLocked()
        }
        if case .promptAndSwallow = result { enqueueLocked(["kind": "quitPrompt"]) }
        lock.unlock()
        switch result {
        case .promptAndSwallow, .swallow: return true
        case .passThrough, .none: return false
        case .synthesizeQuit:
            postCommandQ()
            return true
        }
    }

    private func scheduleQuitHoldLocked(startedAt: TimeInterval) {
        quitHoldGeneration &+= 1
        let generation = quitHoldGeneration
        quitHoldWork?.cancel()
        let dueAt = startedAt + HelperQuitGuard.holdThreshold
        let work = DispatchWorkItem { [weak self] in self?.finishQuitHold(at: dueAt, generation: generation) }
        quitHoldWork = work
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + HelperQuitGuard.holdThreshold, execute: work)
    }

    private func cancelQuitHoldLocked() {
        quitHoldGeneration &+= 1
        quitHoldWork?.cancel()
        quitHoldWork = nil
    }

    private func finishQuitHold(at time: TimeInterval, generation: Int) {
        lock.lock()
        guard generation == quitHoldGeneration else { lock.unlock(); return }
        quitHoldWork = nil
        let active = enabledFeatures.contains("quitProtection")
        let result = active ? quitGuard.holdThresholdReached(at: time) : .none
        lock.unlock()
        if case .synthesizeQuit = result { postCommandQ() }
    }

    private func postCommandQ() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func beginDrag(at event: CGEvent) {
        guard let target = windowTarget(at: event.location), let frame = readFrame(target.element) else {
            dragState = nil
            return
        }
        dragState = DragState(target: target, startingFrame: frame.rect)
    }

    private func updateDrag(at event: CGEvent) {
        guard var current = dragState, let frame = readFrame(current.target.element) else { return }
        if abs(frame.position.x - current.startingFrame.minX) > 3 || abs(frame.position.y - current.startingFrame.minY) > 3 {
            current.moved = true
            current.pendingPosition = edgePosition(at: event.location)
        }
        dragState = current
    }

    private func finishDrag(at event: CGEvent) {
        defer { dragState = nil }
        guard let current = dragState, current.moved,
              let position = edgePosition(at: event.location) ?? current.pendingPosition else { return }
        _ = snap(current.target, position: position)
    }

    private func edgePosition(at axPoint: CGPoint) -> String? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let desktopTop = (NSScreen.main ?? screens[0]).frame.maxY
        let point = CGPoint(x: axPoint.x, y: desktopTop - axPoint.y)
        for screen in screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            guard frame.insetBy(dx: -24, dy: -24).contains(point) else { continue }
            if point.x <= visible.minX + 22 { return "left" }
            if point.x >= visible.maxX - 22 { return "right" }
            if point.y >= frame.maxY - 22 { return "maximize" }
            return nil
        }
        return nil
    }

    private func isGreenButtonClick(at event: CGEvent) -> Bool {
        guard let element = element(at: event.location) else { return false }
        let role = Self.stringAttribute(kAXRoleAttribute as String, from: element) ?? ""
        let subrole = Self.stringAttribute(kAXSubroleAttribute as String, from: element) ?? ""
        return role == "AXButton" && ["AXZoomButton", "AXFullScreenButton"].contains(subrole)
    }

    private func handleGreenButton(at event: CGEvent) -> Bool {
        guard let button = element(at: event.location), let window = windowAncestor(of: button),
              let pid = Self.pid(of: window), let frame = readFrame(window) else { return false }
        let number = Self.numberAttribute("AXWindowNumber", from: window) ?? 0
        let key = "\(pid):\(number)"
        if let restore = savedFrames.removeValue(forKey: key) {
            savedFrameOrder.removeAll { $0 == key }
            let restored = setWindowFrame(
                window,
                appKitFrame: restore.frame.appKitRect(desktopTop: restore.desktopTop),
                desktopTop: restore.desktopTop
            )
            if !restored {
                savedFrames[key] = restore
                savedFrameOrder.append(key)
            }
            return restored
        }
        guard let screen = screenForWindow(window),
              let desktopTop = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY,
              setWindowFrame(window, appKitFrame: screen.visibleFrame, desktopTop: desktopTop) else { return false }
        savedFrames[key] = SavedWindowFrame(frame: frame, desktopTop: desktopTop)
        savedFrameOrder.append(key)
        while savedFrameOrder.count > Self.maximumSavedFrames {
            let oldest = savedFrameOrder.removeFirst()
            savedFrames.removeValue(forKey: oldest)
        }
        return true
    }

    private func snap(_ target: HelperWindowTarget, position: String) -> Bool {
        guard let screen = screenForWindow(target.element) else { return false }
        let frame = Self.snapFrame(position: position, in: screen.visibleFrame)
        guard let desktopTop = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY else { return false }
        return setWindowFrame(target.element, appKitFrame: frame, desktopTop: desktopTop)
    }

    private static func snapFrame(position: String, in visible: CGRect) -> CGRect {
        let halfWidth = floor(visible.width / 2)
        let halfHeight = floor(visible.height / 2)
        switch position {
        case "left": return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
        case "right": return CGRect(x: visible.minX + halfWidth, y: visible.minY, width: visible.width - halfWidth, height: visible.height)
        case "top": return CGRect(x: visible.minX, y: visible.minY + halfHeight, width: visible.width, height: visible.height - halfHeight)
        case "bottom": return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfHeight)
        case "center":
            let size = CGSize(width: halfWidth, height: halfHeight)
            return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        default: return visible
        }
    }

    private func setWindowFrame(_ window: AXUIElement, appKitFrame: CGRect, desktopTop: CGFloat) -> Bool {
        var position = CGPoint(x: appKitFrame.minX, y: desktopTop - appKitFrame.maxY)
        var size = appKitFrame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else { return false }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
    }

    private func screenForWindow(_ window: AXUIElement) -> NSScreen? {
        guard let frame = readFrame(window)?.rect else { return NSScreen.main ?? NSScreen.screens.first }
        let desktopTop = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxY ?? 0
        let center = CGPoint(x: frame.midX, y: desktopTop - frame.minY - frame.height / 2)
        return NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func frontmostWindow() -> HelperWindowTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() {
            let windows = Self.windows(of: app) ?? []
            let index = windows.firstIndex(where: { CFEqual($0, element) }) ?? 0
            return HelperWindowTarget(
                pid: application.processIdentifier,
                index: index,
                number: Self.numberAttribute("AXWindowNumber", from: element as! AXUIElement) ?? index,
                element: element as! AXUIElement
            )
        }
        guard let windows = Self.windows(of: app), let first = windows.first else { return nil }
        return HelperWindowTarget(pid: application.processIdentifier, index: 0, number: Self.numberAttribute("AXWindowNumber", from: first) ?? 0, element: first)
    }

    private func windowTarget(at point: CGPoint) -> HelperWindowTarget? {
        guard let element = element(at: point), let window = windowAncestor(of: element),
              let pid = Self.pid(of: window), let windows = Self.windows(of: AXUIElementCreateApplication(pid)) else { return nil }
        let index = windows.firstIndex(where: { CFEqual($0, window) }) ?? 0
        return HelperWindowTarget(pid: pid, index: index, number: Self.numberAttribute("AXWindowNumber", from: window) ?? index, element: window)
    }

    private func element(at point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        return error == .success ? element : nil
    }

    private func windowAncestor(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<12 {
            if Self.stringAttribute(kAXRoleAttribute as String, from: current) == (kAXWindowRole as String) { return current }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let value = parent, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            current = value as! AXUIElement
        }
        return nil
    }

    private func readFrame(_ element: AXUIElement) -> HelperWindowFrame? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionAX = positionValue, let sizeAX = sizeValue,
              CFGetTypeID(positionAX) == AXValueGetTypeID(), CFGetTypeID(sizeAX) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeAX as! AXValue, .cgSize, &size) else { return nil }
        return HelperWindowFrame(position: position, size: size)
    }

    private func observeRunningApplicationsLocked() {
        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular && !application.isTerminated && application.processIdentifier > 0 {
            observeApplicationLocked(pid: application.processIdentifier, replace: false)
        }
    }

    private func startWorkspaceObserversLocked() {
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard application.activationPolicy == .regular, !application.isTerminated else { return }
            guard let self else { return }
            self.lock.lock()
            if self.enabledFeatures.contains("quitOnLastWindow") {
                self.observeApplicationLocked(pid: application.processIdentifier, replace: false)
            }
            self.lock.unlock()
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeObserver(pid: application.processIdentifier)
        }
    }

    private func observeApplicationLocked(pid: pid_t, replace: Bool) {
        guard enabledFeatures.contains("quitOnLastWindow") else { return }
        if observers[pid] != nil, !replace { return }
        if replace { removeObserverLocked(pid: pid) }
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowsAXObserverCallback, &observer) == .success, let observer else { return }
        let context = WindowsObserverContext(runtime: self, pid: pid)
        let app = AXUIElementCreateApplication(pid)
        let opaque = Unmanaged.passUnretained(context).toOpaque()
        _ = AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, opaque)
        for window in Self.windows(of: app) ?? [] {
            _ = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, opaque)
        }
        observers[pid] = WindowsObserverEntry(observer: observer, context: context)
        HelperRunLoop.shared.add(AXObserverGetRunLoopSource(observer))
    }

    private func removeObserver(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        removeObserverLocked(pid: pid)
    }

    private func removeObserverLocked(pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        HelperRunLoop.shared.remove(AXObserverGetRunLoopSource(entry.observer))
    }

    private func removeObserversLocked() {
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        if let terminateObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver) }
        launchObserver = nil
        terminateObserver = nil
        for pid in Array(observers.keys) { removeObserverLocked(pid: pid) }
    }

    private func enqueueLocked(_ event: [String: Any]) {
        queuedEvents.append(event)
        if queuedEvents.count > Self.maximumQueuedEvents { queuedEvents.removeFirst(queuedEvents.count - Self.maximumQueuedEvents) }
    }

    private func permissionError() -> HelperArgs {
        ["ok": false, "accessibilityTrusted": false, "error": "Accessibility permission is required."]
    }

    private func shutdown() {
        lock.lock(); defer { lock.unlock() }
        enabledFeatures.removeAll()
        switcherOpen = false
        optionWasDown = false
        queuedEvents.removeAll(keepingCapacity: true)
        quitGuard = HelperQuitGuard()
        cancelQuitHoldLocked()
        savedFrames.removeAll(keepingCapacity: true)
        savedFrameOrder.removeAll(keepingCapacity: true)
        dragState = nil
        removeObserversLocked()
        configureTapLocked()
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        Self.stringAttribute(name, from: element)
    }

    private func numberAttribute(_ name: String, from element: AXUIElement) -> Int? {
        Self.numberAttribute(name, from: element)
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let value else { return nil }
        return value as? [AXUIElement]
    }

    private static func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func numberAttribute(_ name: String, from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func shouldQuit(bundleID: String, windowCount: Int, excluded: Set<String>) -> Bool {
        guard windowCount == 0, !bundleID.isEmpty, bundleID.lowercased() != "com.apple.finder" else { return false }
        return !excluded.contains(bundleID.lowercased())
    }
}

private func windowsEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<WindowsTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.runtime?.handleTap(type: type, event: event) ?? Unmanaged.passUnretained(event)
}

private func windowsAXObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<WindowsObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.runtime?.observerEvent(pid: context.pid, notification: notification as String)
}
