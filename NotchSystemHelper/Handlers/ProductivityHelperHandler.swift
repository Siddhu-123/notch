import ApplicationServices
import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

enum ProductivityHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        case "quickToggleStatus": reply(ProductivityHelperRuntime.shared.quickToggleStatus())
        case "toggleQuickToggle":
            guard let name = args["name"] as? String else { reply(["ok": false, "error": "A toggle name is required."]); return }
            reply(ProductivityHelperRuntime.shared.toggleQuickToggle(name))
        case "lockInput": reply(ProductivityHelperRuntime.shared.setInputLocked(args))
        case "lockStatus": reply(ProductivityHelperRuntime.shared.lockStatus())
        default: reply(HelperRouter.unknown(action))
        }
    }
}

private final class ProductivityHelperRuntime {
    static let shared = ProductivityHelperRuntime()
    private let lock = NSRecursiveLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventContext: CleaningInputContext?
    private var watchdog: DispatchSourceTimer?
    private var lockExpiresAt: Date?
    private var ownerPID: pid_t = 0
    private var ownerBundle = ""
    private var ownerLaunch = 0.0

    private init() {
        atexit { ProductivityHelperRuntime.shared.unlockInput() }
    }

    func quickToggleStatus() -> HelperArgs {
        let automation = canAutomateSystemEvents()
        let dark = automation.allowed ? readDarkMode() : nil
        let hidden = readFinderBool("AppleShowAllFiles")
        let desktop = readFinderBool("CreateDesktop")
        let night = NightShiftBridge.isEnabled()
        return [
            "ok": true,
            "automationAllowed": automation.allowed,
            "automationError": automation.reason,
            "darkMode": dark as Any? ?? NSNull(),
            "hiddenFiles": hidden ?? false,
            "desktopIcons": desktop ?? true,
            "nightShiftAvailable": night.available,
            "nightShift": night.enabled as Any? ?? NSNull(),
            "wifiStatus": wifiStatus(),
            "bluetoothStatus": bluetoothStatus()
        ]
    }

    func toggleQuickToggle(_ name: String) -> HelperArgs {
        switch name {
        case "darkMode":
            let permission = canAutomateSystemEvents()
            guard permission.allowed, let current = readDarkMode() else {
                return ["ok": false, "automationAllowed": false, "error": "Automation permission for System Events is required to change Dark Mode."]
            }
            let success = writeDarkMode(!current)
            return ["ok": success, "automationAllowed": true, "darkMode": success ? !current : current,
                    "error": success ? "" : "System Events could not change Dark Mode."]
        case "hiddenFiles":
            guard let current = readFinderBool("AppleShowAllFiles") else { return ["ok": false, "error": "Finder hidden-file state could not be read."] }
            guard writeFinderBool("AppleShowAllFiles", value: !current), relaunchFinder() else {
                return ["ok": false, "error": "Finder could not apply the hidden-file setting."]
            }
            return ["ok": true, "hiddenFiles": !current]
        case "desktopIcons":
            guard let current = readFinderBool("CreateDesktop") else { return ["ok": false, "error": "Finder desktop-icon state could not be read."] }
            let next = !current
            guard writeFinderBool("CreateDesktop", value: next), relaunchFinder() else {
                return ["ok": false, "error": "Finder could not apply the desktop-icon setting."]
            }
            return ["ok": true, "desktopIcons": next]
        case "nightShift":
            let current = NightShiftBridge.isEnabled()
            guard current.available, let enabled = current.enabled,
                  NightShiftBridge.setEnabled(!enabled) else {
                return ["ok": false, "nightShiftAvailable": false, "error": "Night Shift control is unavailable on this macOS version."]
            }
            return ["ok": true, "nightShiftAvailable": true, "nightShift": !enabled]
        default:
            return ["ok": false, "error": "This toggle is read-only or unknown."]
        }
    }

    func setInputLocked(_ args: HelperArgs) -> HelperArgs {
        guard args["on"] as? Bool == true else {
            unlockInput()
            return ["ok": true, "locked": false]
        }
        guard AXIsProcessTrusted() else {
            return ["ok": false, "locked": false, "accessibilityTrusted": false, "error": "Accessibility permission is required to block input."]
        }
        lock.lock()
        defer { lock.unlock() }
        let duration = min(max(args["duration"] as? Double ?? 60, 1), 60)
        let escapeHold = min(max(args["escapeHold"] as? Double ?? 2, 2), 5)
        let pid = (args["ownerPID"] as? NSNumber)?.int32Value ?? 0
        let bundle = args["ownerBundle"] as? String ?? ""
        let launch = args["ownerLaunch"] as? Double ?? 0
        guard pid > 0, !bundle.isEmpty else {
            return ["ok": false, "locked": false, "error": "The Notch app identity is missing."]
        }
        if eventTap != nil {
            ownerPID = pid; ownerBundle = bundle; ownerLaunch = launch
            lockExpiresAt = Date().addingTimeInterval(duration)
            scheduleWatchdogLocked()
            eventContext?.setEscapeHold(escapeHold)
            return ["ok": true, "locked": true, "expiresIn": duration]
        }
        guard installInputTap(escapeHold: escapeHold) else {
            return ["ok": false, "locked": false, "error": "The input event tap could not be started. Check Accessibility permission for Notch System Helper."]
        }
        ownerPID = pid; ownerBundle = bundle; ownerLaunch = launch
        lockExpiresAt = Date().addingTimeInterval(duration)
        scheduleWatchdogLocked()
        return ["ok": true, "locked": true, "expiresIn": duration]
    }

    func lockStatus() -> HelperArgs {
        lock.lock(); defer { lock.unlock() }
        guard eventTap != nil else { return ["ok": true, "locked": false] }
        if !ownerIsAlive() || (lockExpiresAt.map { Date() >= $0 } ?? true) {
            lock.unlock(); unlockInput(); lock.lock()
            return ["ok": true, "locked": false]
        }
        return ["ok": true, "locked": true, "expiresAt": lockExpiresAt?.timeIntervalSince1970 ?? 0]
    }

    func unlockInput() {
        lock.lock(); defer { lock.unlock() }
        watchdog?.setEventHandler {}
        watchdog?.cancel(); watchdog = nil
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        eventContext?.cancelEscapeHold()
        eventContext = nil
        lockExpiresAt = nil
        ownerPID = 0
        ownerBundle = ""
        ownerLaunch = 0
    }

    private func installInputTap(escapeHold: TimeInterval) -> Bool {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
            .tabletPointer, .tabletProximity
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = CleaningInputContext(escapeHold: escapeHold) { [weak self] in
            DispatchQueue.main.async { self?.unlockInput() }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: productivityCleaningTap, userInfo: Unmanaged.passUnretained(context).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        eventTap = tap
        runLoopSource = source
        eventContext = context
        context.setTap(tap)
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func scheduleWatchdogLocked() {
        watchdog?.setEventHandler {}
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = self.lockExpiresAt.map { Date() >= $0 } ?? true
            let alive = self.ownerIsAlive()
            self.lock.unlock()
            if expired || !alive { self.unlockInput() }
        }
        watchdog = timer
        timer.resume()
    }

    private func ownerIsAlive() -> Bool {
        guard ownerPID > 0,
              let app = NSRunningApplication(processIdentifier: ownerPID),
              !app.isTerminated, app.bundleIdentifier == ownerBundle else { return false }
        guard ownerLaunch > 0 else { return true }
        guard let launchDate = app.launchDate else { return false }
        return abs(launchDate.timeIntervalSince1970 - ownerLaunch) < 1.5
    }

    private func readFinderBool(_ key: String) -> Bool? {
        guard ["AppleShowAllFiles", "CreateDesktop"].contains(key),
              let result = runProgram("/usr/bin/defaults", ["read", "com.apple.finder", key]) else { return nil }
        if result.status != 0 {
            if result.output.localizedCaseInsensitiveContains("does not exist") {
                return key == "CreateDesktop"
            }
            return nil
        }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes"].contains(value) { return true }
        if ["0", "false", "no"].contains(value) { return false }
        return nil
    }

    private func writeFinderBool(_ key: String, value: Bool) -> Bool {
        guard ["AppleShowAllFiles", "CreateDesktop"].contains(key) else { return false }
        return runProgram("/usr/bin/defaults", ["write", "com.apple.finder", key, "-bool", value ? "true" : "false"])?.status == 0
    }

    private func relaunchFinder() -> Bool {
        runProgram("/usr/bin/killall", ["Finder"])?.status == 0
    }

    private func wifiStatus() -> String {
        guard let ports = runProgram("/usr/sbin/networksetup", ["-listallhardwareports"])?.output else { return "Unavailable" }
        let lines = ports.components(separatedBy: .newlines)
        for index in lines.indices where lines[index].localizedCaseInsensitiveContains("Hardware Port: Wi-Fi") || lines[index].localizedCaseInsensitiveContains("Hardware Port: AirPort") {
            guard index + 1 < lines.count,
                  let range = lines[index + 1].range(of: #"Device:\s*(en[0-9]+)"#, options: .regularExpression) else { continue }
            let device = String(lines[index + 1][range]).replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
            guard let result = runProgram("/usr/sbin/networksetup", ["-getairportpower", device])?.output else { return "Unavailable" }
            return result.localizedCaseInsensitiveContains("On") ? "On" : "Off"
        }
        return "Unavailable"
    }

    private func bluetoothStatus() -> String {
        if let result = runProgram("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState"]), result.status == 0 {
            return Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 == 0 ? "Off" : "On" } ?? "Unavailable"
        }
        return "Unavailable"
    }

    private func runProgram(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }

    private func canAutomateSystemEvents() -> (allowed: Bool, reason: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").first != nil else {
            return (false, "System Events is not running yet.")
        }
        let bundleID = "com.apple.systemevents"
        let bytes = Array(bundleID.utf8)
        var target = AEAddressDesc()
        let createStatus = bytes.withUnsafeBytes { bytes in
            AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
        }
        guard createStatus == noErr else { return (false, "System Events Automation could not be checked.") }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return status == noErr ? (true, "") : (false, "Allow Notch System Helper to control System Events in Privacy & Security → Automation.")
    }

    private func readDarkMode() -> Bool? {
        let script = NSAppleScript(source: "tell application \"System Events\" to get dark mode of appearance preferences")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error), error == nil else { return nil }
        return result.booleanValue
    }

    private func writeDarkMode(_ enabled: Bool) -> Bool {
        let value = enabled ? "true" : "false"
        let script = NSAppleScript(source: "tell application \"System Events\" to set dark mode of appearance preferences to \(value)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}

private final class CleaningInputContext {
    private static let escapeKeyCode: Int64 = 53
    private let lock = NSLock()
    private var escapeHold: TimeInterval
    private var escapeDownAt: TimeInterval?
    private var escapeTimeoutWorkItem: DispatchWorkItem?
    private let onEscapeHold: () -> Void
    private weak var tap: CFMachPort?

    init(escapeHold: TimeInterval, onEscapeHold: @escaping () -> Void) {
        self.escapeHold = escapeHold
        self.onEscapeHold = onEscapeHold
    }

    func setTap(_ tap: CFMachPort) { self.tap = tap }
    func setEscapeHold(_ value: TimeInterval) { lock.lock(); escapeHold = value; lock.unlock() }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
            lock.lock()
            if escapeDownAt == nil {
                let startedAt = ProcessInfo.processInfo.systemUptime
                escapeDownAt = startedAt
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let shouldExit = self.escapeDownAt == startedAt
                    if shouldExit { self.escapeDownAt = nil; self.escapeTimeoutWorkItem = nil }
                    self.lock.unlock()
                    if shouldExit { self.onEscapeHold() }
                }
                escapeTimeoutWorkItem = work
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + escapeHold, execute: work)
            }
            lock.unlock()
        } else if type == .keyUp, event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
            lock.lock()
            let elapsed = ProcessInfo.processInfo.systemUptime - (escapeDownAt ?? ProcessInfo.processInfo.systemUptime)
            let shouldExit = elapsed >= escapeHold
            escapeDownAt = nil
            escapeTimeoutWorkItem?.cancel(); escapeTimeoutWorkItem = nil
            lock.unlock()
            if shouldExit { onEscapeHold() }
        }
        return nil
    }

    func cancelEscapeHold() {
        lock.lock(); defer { lock.unlock() }
        escapeDownAt = nil
        escapeTimeoutWorkItem?.cancel(); escapeTimeoutWorkItem = nil
    }
}

private let productivityCleaningTap: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return nil }
    let context = Unmanaged<CleaningInputContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.handle(type: type, event: event)
}

private enum NightShiftBridge {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL)
    }()

    private static var client: NSObject? {
        guard handle != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return type.init()
    }

    static func isEnabled() -> (available: Bool, enabled: Bool?) {
        guard let client,
              let selector = ["isEnabled", "enabled"].map(NSSelectorFromString).first(where: client.responds(to:)),
              let method = class_getInstanceMethod(type(of: client), selector) else { return (false, nil) }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return (true, getter(client, selector))
    }

    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let client else { return false }
        if let selector = ["setEnabled:error:", "setBlueLightEnabled:error:"].map(NSSelectorFromString).first(where: client.responds(to:)),
           let method = class_getInstanceMethod(type(of: client), selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool, UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Void
            let setter = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            var error: Unmanaged<NSError>?
            setter(client, selector, enabled, &error)
            return isEnabled().enabled == enabled
        }
        return false
    }
}
