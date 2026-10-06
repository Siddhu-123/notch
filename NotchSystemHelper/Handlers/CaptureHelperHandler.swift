import Foundation

/// J9 capture. Owned by that job; runs outside the app sandbox.
enum CaptureHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
