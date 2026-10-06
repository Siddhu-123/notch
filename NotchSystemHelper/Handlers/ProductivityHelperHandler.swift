import Foundation

/// J11 productivity (toggles, radial menu, cleaning mode). Owned by that job; runs outside the app sandbox.
enum ProductivityHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
