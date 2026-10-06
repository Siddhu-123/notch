import Foundation

/// J12 maintenance (updates, cleaner, uninstaller, brew, ports). Owned by that job; runs outside the app sandbox.
enum MaintenanceHelperHandler: HelperHandler {
    static func handle(action: String, args: HelperArgs, reply: @escaping (HelperArgs?) -> Void) {
        switch action {
        case "ping": reply(["ok": true])
        default: reply(HelperRouter.unknown(action))
        }
    }
}
