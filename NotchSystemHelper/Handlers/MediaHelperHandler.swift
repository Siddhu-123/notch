import AppKit
import ApplicationServices
import Foundation

/// Wave 7 media actions that must run outside the app sandbox.
enum MediaHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping":
            reply(["ok": true])
        case "keyGuardStatus":
            reply([
                "ok": true,
                "accessibilityTrusted": AXIsProcessTrusted(),
                "enabled": MusicKeyGuardRuntime.shared.isEnabled
            ])
        case "setKeyGuard":
            reply(MusicKeyGuardRuntime.shared.configure(
                enabled: args["enabled"] as? Bool ?? false,
                hasPlayer: args["hasPlayer"] as? Bool ?? false
            ))
        default:
            reply(HelperRouter.unknown(action))
        }
    }
}

private final class MusicKeyGuardContext {
    private let lock = NSLock()
    private var enabled = true
    private var hasPlayer: Bool

    init(hasPlayer: Bool) { self.hasPlayer = hasPlayer }

    func update(hasPlayer: Bool) {
        lock.lock()
        self.hasPlayer = hasPlayer
        enabled = true
        lock.unlock()
    }

    func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        guard type.rawValue == 14,
              let systemEvent = NSEvent(cgEvent: event),
              systemEvent.subtype.rawValue == 8 else { return false }

        let data = systemEvent.data1
        let keyCode = (data >> 16) & 0xffff
        let keyState = (data & 0x0000ff00) >> 8
        let isKeyDown = keyState == 0x0a

        lock.lock()
        let shouldFilter = enabled && !hasPlayer
        lock.unlock()
        guard shouldFilter, keyCode == 16, isKeyDown else { return false }

        let musicRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        return !musicRunning
    }
}

private let musicKeyGuardTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MusicKeyGuardRuntime.shared.reenableTap()
        return Unmanaged.passUnretained(event)
    }
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<MusicKeyGuardContext>.fromOpaque(userInfo).takeUnretainedValue()
    return context.shouldSwallow(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

private final class MusicKeyGuardRuntime {
    static let shared = MusicKeyGuardRuntime()

    private let lock = NSRecursiveLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var context: MusicKeyGuardContext?

    private init() {
        atexit { MusicKeyGuardRuntime.shared.shutdown() }
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }

    func configure(enabled: Bool, hasPlayer: Bool) -> HelperArgs {
        lock.lock()
        defer { lock.unlock() }

        guard enabled else {
            disableLocked()
            return ["ok": true, "enabled": false, "accessibilityTrusted": AXIsProcessTrusted()]
        }
        guard AXIsProcessTrusted() else {
            disableLocked()
            return [
                "ok": false,
                "enabled": false,
                "accessibilityTrusted": false,
                "error": "Accessibility permission is required."
            ]
        }

        if let context {
            context.update(hasPlayer: hasPlayer)
            return ["ok": true, "enabled": eventTap != nil, "accessibilityTrusted": true]
        }
        guard installTap(hasPlayer: hasPlayer) else {
            disableLocked()
            return [
                "ok": false,
                "enabled": false,
                "accessibilityTrusted": true,
                "error": "The Play-key event tap could not be started."
            ]
        }
        return ["ok": true, "enabled": true, "accessibilityTrusted": true]
    }

    func reenableTap() {
        lock.lock()
        defer { lock.unlock() }
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func shutdown() {
        lock.lock()
        disableLocked()
        lock.unlock()
    }

    private func installTap(hasPlayer: Bool) -> Bool {
        let context = MusicKeyGuardContext(hasPlayer: hasPlayer)
        let mask = CGEventMask(1) << 14
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: musicKeyGuardTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        self.context = context
        eventTap = tap
        runLoopSource = source
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func disableLocked() {
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        context = nil
    }
}
