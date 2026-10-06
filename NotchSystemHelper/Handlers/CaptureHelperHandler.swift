import ApplicationServices
import CoreGraphics
import Foundation

/// Small helper boundary for scroll capture. Screen pixels stay in the app;
/// the helper only watches scroll events while an explicit scroll capture runs.
enum CaptureHelperHandler: HelperHandler {
    private static let notificationName = Notification.Name("sidco.notch.capture.scroll")
    private static var eventTap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?

    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping":
            reply(["ok": true])
        case "startScrollWatch", "enableScrollWatch":
            guard args["enabled"] as? Bool != false else { stopScrollWatch(); reply(["ok": true]); return }
            guard AXIsProcessTrusted() else {
                reply(["ok": false, "reason": "accessibility"])
                return
            }
            reply(startScrollWatch())
        case "stopScrollWatch", "disableScrollWatch":
            stopScrollWatch()
            reply(["ok": true])
        case "scroll":
            let delta = (args["dy"] as? NSNumber)?.intValue ?? args["dy"] as? Int ?? 0
            guard delta != 0 else { reply(["ok": false, "reason": "invalid-delta"]); return }
            postScroll(delta)
            reply(["ok": true])
        default:
            reply(HelperRouter.unknown(action))
        }
    }

    private static func startScrollWatch() -> HelperArgs {
        if eventTap != nil { return ["ok": true, "alreadyRunning": true] }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: .listenOnly, eventsOfInterest: mask,
                                         callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = CaptureHelperHandler.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
            let pointDelta = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let lineDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let delta = pointDelta == 0 ? lineDelta : pointDelta
            if delta != 0 { CaptureHelperHandler.postScroll(Int(delta)) }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            return ["ok": false, "reason": "event-tap-unavailable"]
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return ["ok": false, "reason": "run-loop-source-unavailable"]
        }
        eventTap = tap
        runLoopSource = source
        HelperRunLoop.shared.add(source)
        CGEvent.tapEnable(tap: tap, enable: true)
        return ["ok": true]
    }

    private static func stopScrollWatch() {
        if let runLoopSource { HelperRunLoop.shared.remove(runLoopSource) }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private static func postScroll(_ dy: Int) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: nil,
            userInfo: ["dy": dy],
            deliverImmediately: true
        )
    }
}
