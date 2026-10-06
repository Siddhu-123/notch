import Foundation

/// J5 windows (switcher, layouts, green button, quit on last window, Cmd-Q/W). Owned by that job; runs outside the app sandbox.
enum WindowsHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
