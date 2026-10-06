import Foundation

/// J6 pointer and mouse (22-31). Owned by that job; runs outside the app sandbox.
enum PointerHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
