import Foundation

/// J3 sound (per-app volume, routing, headphone guard). Owned by that job; runs outside the app sandbox.
enum AudioHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
